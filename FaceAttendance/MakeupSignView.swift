import SwiftUI
import UIKit           // UIImage（名册证件照头像）/ UIColor（占位底色）
import ZIPFoundation   // 读取历史场次 xlsx（App 自己写的表：内联字符串 + 可选共享字符串）

// MARK: - v6.9.0 手动补签
//
// 入口：课程详情 → 历史考勤记录 → 点进某一场签到 → 右上角「手动补签」
// （或在文件列表里直接点某个 xlsx 行的补签图标）。
// 打开后两种补签方式，结果都写回【同一份】Excel（整表重写，文件名不变）：
//   ① 前置摄像头扫脸：识别出是谁 → 点确认 → 记「扫脸补签」（带相似度）；
//   ② 头像库点击确认：复用 v6.8.1 手动签到头像网格（已出勤的自动遮罩），
//      找到自己头像点确认 → 记「头像补签」；也可在缺勤名单里直接点行补签。
// 补签行可随时撤销（已出勤区点「撤销」），撤销同样写回同一份 Excel。

// MARK: - 考勤表 xlsx 读取

/// 历史考勤表读取器。兼容两种来源：
/// ① App 自写表（inlineStr，无共享字符串表）；
/// ② 用户在 Excel/WPS 里打开改过的表（共享字符串 + 数字单元格 + 稀疏引用）
enum AttendanceSheet {

    struct Row: Identifiable, Hashable {
        let id = UUID()
        var seq: Int
        var studentId: String
        var name: String
        var className: String
        var present: Bool
        var method: String      // 确认方式：自动确认/多角度确认/待确认/扫脸补签/头像补签
        var hits: Int
        var score: Float
        var makeup: Bool        // 确认方式含「补签」→ 允许撤销
    }

    struct Parsed {
        var title: String
        var timeText: String    // 原表"时间：…"行，原样保留
        var note: String        // 原表"注：…"行，原样保留（没有则为空）
        var rows: [Row]
    }

    static func parse(url: URL) throws -> Parsed {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw NSError(domain: "Makeup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法打开 xlsx 压缩包"])
        }
        // 共享字符串表（App 自写表没有；Excel/WPS 另存过的会有）
        var shared: [String] = []
        if let e = archive["xl/sharedStrings.xml"] {
            var data = Data()
            _ = try archive.extract(e) { data.append($0) }
            shared = parseSharedStrings(data)
        }
        guard let entry = archive["xl/worksheets/sheet1.xml"] else {
            throw NSError(domain: "Makeup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "xlsx 中找不到工作表"])
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try structure(parseGrid(data, sharedStrings: shared))
    }

    /// 把单元格网格还原成结构化考勤表（表头行 = 含「学号」的那一行）
    private static func structure(_ grid: [[String]]) throws -> Parsed {
        func fail(_ msg: String) -> NSError {
            NSError(domain: "Makeup", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let hIdx = grid.firstIndex(where: { $0.contains("学号") }) else {
            throw fail("不是相机扫描/照片签到生成的考勤表（找不到「学号」表头），无法补签")
        }
        let header = grid[hIdx]
        func col(_ name: String) -> Int { header.firstIndex(of: name) ?? -1 }
        let sidIdx = col("学号"), nameIdx = col("姓名"), attIdx = col("出勤")
        guard sidIdx >= 0, nameIdx >= 0, attIdx >= 0 else {
            throw fail("考勤表表头缺少「学号/姓名/出勤」列，无法补签")
        }
        let classIdx = col("班级"), methodIdx = col("确认方式"),
            hitsIdx = col("识别次数"), scoreIdx = col("最高相似度")
        func cell(_ line: [String], _ i: Int) -> String {
            (i >= 0 && line.count > i) ? line[i] : ""
        }
        var rows: [Row] = []
        for line in grid.dropFirst(hIdx + 1) {
            let sid = cell(line, sidIdx).trimmingCharacters(in: .whitespaces)
            guard !sid.isEmpty else { continue }          // 空行/汇总行
            let method = cell(line, methodIdx)
            rows.append(Row(seq: rows.count + 1,
                            studentId: sid,
                            name: cell(line, nameIdx),
                            className: cell(line, classIdx),
                            present: cell(line, attIdx) == "√",
                            method: method,
                            hits: Int(cell(line, hitsIdx)) ?? 0,
                            score: Float(cell(line, scoreIdx)) ?? 0,
                            makeup: method.contains("补签")))
        }
        guard !rows.isEmpty else { throw fail("考勤表中没有学生行") }
        func lineText(_ i: Int) -> String {
            (i < grid.count && !grid[i].isEmpty) ? grid[i][0] : ""
        }
        let title = lineText(0)
        let note = lineText(3).hasPrefix("注") ? lineText(3) : ""
        return Parsed(title: title.isEmpty ? "考勤表" : title,
                      timeText: lineText(1),
                      note: note,
                      rows: rows)
    }

    // MARK: 表格 XML 解析（inlineStr / 共享字符串 / 数字单元格；按 r="B3" 引用对齐列）

    private static func parseGrid(_ data: Data, sharedStrings shared: [String]) -> [[String]] {
        let p = GridParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rows
    }

    private static func parseSharedStrings(_ data: Data) -> [String] {
        let p = SharedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    private final class GridParser: NSObject, XMLParserDelegate {
        let shared: [String]
        private(set) var rows: [[String]] = []
        private var row: [String] = []
        private var col = 0
        private var type = ""
        private var buf = ""
        private var inText = false

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            switch name {
            case "row": row = []
            case "c":
                col = attributeDict["r"].flatMap(Self.colIndex) ?? row.count
                type = attributeDict["t"] ?? ""
                buf = ""
            case "t", "v": inText = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { buf += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch name {
            case "t", "v": inText = false
            case "c":
                while row.count <= col { row.append("") }
                if type == "s", let i = Int(buf), shared.indices.contains(i) {
                    row[col] = shared[i]
                } else {
                    row[col] = buf          // inlineStr 的多段 <t> 运行已累加进 buf
                }
            case "row": rows.append(row)
            default: break
            }
        }

        /// "AB12" → 列下标 27（字母部分按 26 进制）
        static func colIndex(_ ref: String) -> Int? {
            var n = 0
            for ch in ref {
                guard ch.isASCII, ch.isLetter,
                      let v = ch.uppercased().first?.asciiValue, (65...90).contains(v) else { break }
                n = n * 26 + (Int(v) - 64)
            }
            return n > 0 ? n - 1 : nil
        }
    }

    private final class SharedParser: NSObject, XMLParserDelegate {
        private(set) var strings: [String] = []
        private var buf = ""
        private var inT = false

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            if name == "si" { buf = "" }
            if name == "t" { inT = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { buf += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if name == "t" { inT = false }
            if name == "si" { strings.append(buf) }
        }
    }
}

// MARK: - 手动补签主界面

struct MakeupSignView: View {
    let course: Course
    let fileURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var students: [Student] = []
    @State private var sheet: AttendanceSheet.Parsed?
    @State private var loadError: String?
    @State private var showCamera = false
    @State private var showGrid = false
    @State private var banner: String?
    @State private var bannerOK = false
    /// 缺勤行点按 → 「头像补签」确认
    @State private var pendingAbsent: AttendanceSheet.Row?
    /// 补签行撤销确认
    @State private var pendingUndo: AttendanceSheet.Row?

    private var presentSids: Set<String> {
        Set(sheet?.rows.filter { $0.present }.map { $0.studentId } ?? [])
    }
    private var absentRows: [AttendanceSheet.Row] {
        sheet?.rows.filter { !$0.present } ?? []
    }
    private var makeupRows: [AttendanceSheet.Row] {
        sheet?.rows.filter { $0.present && $0.makeup } ?? []
    }
    private var canScan: Bool { students.contains { $0.feature != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if let e = loadError {
                    // 不用 ContentUnavailableView——部署目标 iOS 16，它是 iOS 17 才有的
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.orange)
                        Text("无法补签").font(.headline)
                        Text(e).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let s = sheet {
                    List {
                        Section {
                            Text(s.title).font(.headline)
                            if !s.timeText.isEmpty {
                                Text(s.timeText).font(.caption).foregroundStyle(.secondary)
                            }
                            let total = s.rows.count
                            let present = s.rows.filter { $0.present }.count
                            Text("应到 \(total) 人 · 实到 \(present) 人 · 缺勤 \(total - present) 人")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Section {
                            Button {
                                showCamera = true
                            } label: {
                                Label("前置摄像头扫脸补签", systemImage: "faceid")
                                    .font(.headline)
                            }
                            .disabled(!canScan)
                            Button {
                                showGrid = true
                            } label: {
                                Label("头像库点击确认补签", systemImage: "person.crop.circle.badge.checkmark")
                                    .font(.headline)
                            }
                            if !canScan {
                                Text("花名册暂无可用人脸特征，仅支持头像库补签")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("补签结果直接写回本表（\(fileURL.lastPathComponent)），已出勤 \(makeupRows.count) 条补签可撤销")
                                .font(.caption).foregroundStyle(.secondary)
                        } header: { Text("补签方式") }

                        if !absentRows.isEmpty {
                            Section("缺勤 \(absentRows.count) 人（点名字可直接补签）") {
                                ForEach(absentRows) { r in
                                    Button { pendingAbsent = r } label: {
                                        HStack(spacing: 10) {
                                            avatar(r.studentId, r.name)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(r.name).foregroundStyle(.primary)
                                                Text("\(r.className)  \(r.studentId)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                        }

                        Section("已出勤 \(s.rows.count - absentRows.count) 人") {
                            ForEach(s.rows.filter { $0.present }) { r in
                                HStack(spacing: 10) {
                                    avatar(r.studentId, r.name)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(r.name)
                                            if r.makeup {
                                                Text("补签").font(.caption.bold())
                                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                                    .background(.green.opacity(0.15), in: Capsule())
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        Text("\(r.className)  \(r.studentId)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(r.method).font(.caption).foregroundStyle(.secondary)
                                        if r.score > 0 {
                                            Text(String(format: "%.3f", r.score))
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                    if r.makeup {
                                        Button("撤销") { pendingUndo = r }
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("正在读取考勤表…")
                }
            }
            .navigationTitle("手动补签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .overlay(alignment: .top) {
                if let banner {
                    Text(banner)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(bannerOK ? Color.green : Color.red, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: banner)
        }
        .onAppear(perform: load)
        .confirmationDialog("头像补签", isPresented: .init(
            get: { pendingAbsent != nil }, set: { if !$0 { pendingAbsent = nil } })) {
            if let r = pendingAbsent {
                Button("确认 \(r.name)（\(r.studentId)）补签") {
                    commitAbsent(r)
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text("将以「头像补签」记入本表，可随时撤销")
        }
        .confirmationDialog("撤销补签", isPresented: .init(
            get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } })) {
            if let r = pendingUndo {
                Button("撤销 \(r.name) 的补签", role: .destructive) { undo(r) }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text("撤销后该生恢复为缺勤，结果写回本表")
        }
        .fullScreenCover(isPresented: $showCamera) {
            MakeupCameraView(
                students: students,
                alreadySigned: presentSids,
                onCommit: { st, sc in
                    try self.commit(studentId: st.studentId, name: st.name,
                                    method: "扫脸补签", score: sc)
                })
        }
        .fullScreenCover(isPresented: $showGrid) {
            MakeupAvatarGridView(
                students: students,
                alreadySigned: presentSids,
                onCommit: { st, _ in
                    try self.commit(studentId: st.studentId, name: st.name,
                                    method: "头像补签", score: 0)
                })
        }
    }

    // MARK: - 数据

    private func load() {
        students = Database.shared.students(courseId: course.id)
        do {
            sheet = try AttendanceSheet.parse(url: fileURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 通用补签提交：先写盘成功再更新内存（写失败时表格状态不变）
    private func commit(studentId: String, name: String,
                        method: String, score: Float) throws {
        guard var s = sheet else {
            throw NSError(domain: "Makeup", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "表格尚未加载"])
        }
        guard let i = s.rows.firstIndex(where: { !$0.present && $0.studentId == studentId }) else {
            throw NSError(domain: "Makeup", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) 已在出勤名单中"])
        }
        var r = s.rows[i]
        r.present = true
        r.method = method
        r.hits = score > 0 ? 1 : 0     // 头像补签无识别次数
        r.score = score
        r.makeup = true
        s.rows[i] = r
        try writeSheet(s)
        sheet = s
        showBanner("✓ \(name) \(method)成功", ok: true)
        print("[补签-v6.9.0] \(method) \(studentId) \(name)，已写回 \(fileURL.lastPathComponent)")
    }

    private func commitAbsent(_ r: AttendanceSheet.Row) {
        do {
            try commit(studentId: r.studentId, name: r.name,
                       method: "头像补签", score: 0)
        } catch {
            showBanner(error.localizedDescription, ok: false)
        }
    }

    /// 撤销补签：仅「确认方式含补签」的行可撤销，写回同一份表
    private func undo(_ row: AttendanceSheet.Row) {
        guard var s = sheet, let i = s.rows.firstIndex(where: { $0.id == row.id }),
              s.rows[i].makeup else { return }
        var r = s.rows[i]
        r.present = false
        r.method = ""
        r.hits = 0
        r.score = 0
        r.makeup = false
        s.rows[i] = r
        do {
            try writeSheet(s)
            sheet = s
            showBanner("已撤销 \(r.name) 的补签", ok: true)
            print("[补签-v6.9.0] 撤销补签 \(r.studentId) \(r.name)")
        } catch {
            showBanner("写入失败：\(error.localizedDescription)", ok: false)
        }
    }

    /// 整表重写回原 xlsx（文件名/位置不变——"同一份 Excel"）
    private func writeSheet(_ s: AttendanceSheet.Parsed) throws {
        let rows = s.rows.map { r in
            (Student(courseId: course.id, studentId: r.studentId, name: r.name,
                     className: r.className, feature: nil),
             r.present, r.method, r.hits, r.score)
        }
        try AttendanceExporter().rewriteSession(
            url: fileURL, title: s.title, timeText: s.timeText, note: s.note, rows: rows)
    }

    private func showBanner(_ text: String, ok: Bool) {
        banner = text
        bannerOK = ok
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { banner = nil }
    }

    /// 名册证件照头像（v6.7.18 起入库）；无照片用姓名首字占位
    private func avatar(_ sid: String, _ name: String) -> some View {
        Group {
            if let st = students.first(where: { $0.studentId == sid }),
               let d = st.photo, let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemFill)
                    Text(String(name.prefix(1))).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}

// MARK: - 扫脸补签（前置相机，复用个人签到引擎的识别链路）

/// 与个人签到相机页同一套识别链路（方向/镜像自校准、大脸量程兜底、
/// EMA 多帧平均、饱和/范数闸全部沿用），区别仅在落盘：onCommit 接管，
/// 把确认的人写回原考勤表 xlsx（记「扫脸补签」），而不是个人签到目录。
struct MakeupCameraView: View {
    let students: [Student]
    let alreadySigned: Set<String>
    let onCommit: (Student, Float) throws -> Void

    @StateObject private var engine: PersonalSignInEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showManualSign = false

    init(students: [Student], alreadySigned: Set<String>,
         onCommit: @escaping (Student, Float) throws -> Void) {
        self.students = students
        self.alreadySigned = alreadySigned
        self.onCommit = onCommit
        _engine = StateObject(wrappedValue: PersonalSignInEngine(
            students: students, alreadySigned: alreadySigned, onCommit: onCommit))
    }

    var body: some View {
        ZStack {
            PersonalSignInPreview(engine: engine)
                .ignoresSafeArea()

            // 识别框 + 姓名标签（与个人签到页同一坐标映射）
            GeometryReader { geo in
                if let r = engine.faceBox, engine.imageSize.width > 0 {
                    let rect = mirroredViewRect(r, in: geo.size, img: engine.imageSize,
                                                flipX: engine.displayFlipX)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(boxColor, lineWidth: 3.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Text(engine.faceLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(boxColor, in: Capsule())
                        .position(x: rect.midX, y: max(20, rect.minY - 18))
                }
            }
            .ignoresSafeArea()
            .animation(nil, value: engine.faceBox)

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.bold())
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("扫脸补签").font(.headline)
                        Text("本场已出勤 \(engine.signedCount) 人")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                .padding(.top, 8)
                Spacer()
                if let msg = engine.justSigned {
                    Text(msg)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.green, in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Text(engine.note)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 6)
                Button { engine.confirm() } label: {
                    Label(engine.confirmTitle, systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .padding(.horizontal, 34).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.confirmEnabled ? .green : .gray)
                .disabled(!engine.confirmEnabled)
                .padding(.top, 10)

                // 扫不出来时的兜底：头像库自领（与个人签到 v6.8.1 同一网格）
                Button { showManualSign = true } label: {
                    Label("头像库补签", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 26).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(engine.confirmEnabled)
                .padding(.top, 8)
                .padding(.bottom, 34)
            }
        }
        .animation(.spring(response: 0.3), value: engine.justSigned)
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
        .fullScreenCover(isPresented: $showManualSign) {
            ManualSignInGridView(engine: engine, students: students)
        }
    }

    private var boxColor: Color {
        switch engine.level {
        case .confirmed: return .green
        case .uncertain: return .orange
        case .unknown:   return .red
        }
    }

    /// 与个人签到页同一套 aspectFill 裁切 + 镜像补偿坐标映射
    private func mirroredViewRect(_ r: CGRect, in size: CGSize, img: CGSize,
                                  flipX: Bool) -> CGRect {
        let scale = max(size.width / img.width, size.height / img.height)
        let dispW = img.width * scale, dispH = img.height * scale
        let offX = (size.width - dispW) / 2
        let offY = (size.height - dispH) / 2
        let x = flipX ? size.width - (offX + r.maxX * scale) : offX + r.minX * scale
        return CGRect(x: x,
                      y: offY + r.minY * scale,
                      width: r.width * scale,
                      height: r.height * scale)
    }
}

// MARK: - 头像库补签（复用 v6.8.1 手动签到网格）

/// 仅把引擎换成补签引擎：头像网格、已签到遮罩、确认按钮、错误横幅
/// 全部沿用 ManualSignInGridView，提交经 onCommit 写回原考勤表。
struct MakeupAvatarGridView: View {
    let students: [Student]
    let alreadySigned: Set<String>
    let onCommit: (Student, Float) throws -> Void

    @StateObject private var engine: PersonalSignInEngine

    init(students: [Student], alreadySigned: Set<String>,
         onCommit: @escaping (Student, Float) throws -> Void) {
        self.students = students
        self.alreadySigned = alreadySigned
        self.onCommit = onCommit
        _engine = StateObject(wrappedValue: PersonalSignInEngine(
            students: students, alreadySigned: alreadySigned, onCommit: onCommit))
    }

    var body: some View {
        ManualSignInGridView(engine: engine, students: students)
    }
}
