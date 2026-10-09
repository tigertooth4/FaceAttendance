import SwiftUI
import AVFoundation
import Combine      // ObservableObject/@Published/@StateObject 的定义模块
import Accelerate   // vDSP（EMA 归一化）
import QuartzCore   // CACurrentMediaTime
import UIKit        // UIDevice 方向

// MARK: - v6.7.19 个人签到存储（签到目录 + CSV 数据源 + xlsx 重建）

/// 目录结构：Documents/exports/<课程>/个人签到/<名称>_<yyyy-MM-dd>/
///   ├── 签到数据.csv   ← 数据源（追加写，崩溃安全；仅供 App 自己读写）
///   └── 签到表.xlsx    ← 每次确认后按 CSV 全量重建，供随时预览/导出
enum PersonalSignInStore {
    struct Row {
        var seq: Int
        var studentId: String
        var name: String
        var date: String    // yyyy-MM-dd（建目录时选定的签到日期）
        var time: String    // HH:mm:ss（点确认的时刻）
        var csvLine: String { "\(seq),\(studentId),\(name),\(date),\(time)" }
        var cells: [String] { [String(seq), studentId, name, date, time] }
    }

    private static let header = "序号,学号,姓名,签到日期,签到时间"

    static func baseDir(courseName: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("exports")
            .appendingPathComponent(AttendanceExporter.sanitize(courseName))
            .appendingPathComponent("个人签到")
    }

    static func dirURL(courseName: String, name: String, date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return baseDir(courseName: courseName)
            .appendingPathComponent("\(AttendanceExporter.sanitize(name))_\(df.string(from: date))")
    }

    static func csvURL(_ dir: URL) -> URL { dir.appendingPathComponent("签到数据.csv") }
    static func xlsxURL(_ dir: URL) -> URL { dir.appendingPathComponent("签到表.xlsx") }

    /// 新建签到目录：已存在同名同日期目录时直接复用（不清空历史数据）
    /// v6.7.30：roster = 课程全部学生（重建 xlsx 的全名单）
    static func createSession(courseName: String, name: String, date: Date,
                              roster: [Student]) throws -> URL {
        let dir = dirURL(courseName: courseName, name: name, date: date)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: csvURL(dir).path) {
            try (header + "\n").write(to: csvURL(dir), atomically: true, encoding: .utf8)
            try rebuildXLSX(dir: dir, title: titleText(name: name, date: date), roster: roster)
            print("[个签-v6.7.30] 新建签到目录：\(dir.lastPathComponent)")
        }
        return dir
    }

    static func loadRows(dir: URL) -> [Row] {
        guard let text = try? String(contentsOf: csvURL(dir), encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").dropFirst().compactMap { line in
            let f = line.components(separatedBy: ",")
            guard f.count == 5, let seq = Int(f[0]) else { return nil }
            return Row(seq: seq, studentId: f[1], name: f[2], date: f[3], time: f[4])
        }
    }

    /// 追加一行并重建 xlsx，返回新行序号
    @discardableResult
    static func append(dir: URL, name: String, sessionDate: Date,
                       studentId: String, studentName: String,
                       roster: [Student]) throws -> Int {
        let rows = loadRows(dir: dir)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        let row = Row(seq: rows.count + 1, studentId: studentId, name: studentName,
                      date: df.string(from: sessionDate), time: tf.string(from: Date()))
        let handle = try FileHandle(forWritingTo: csvURL(dir))
        handle.seekToEndOfFile()
        handle.write(Data((row.csvLine + "\n").utf8))
        try handle.close()
        try rebuildXLSX(dir: dir, title: titleText(name: name, date: sessionDate),
                        roster: roster)
        print("[个签-v6.7.30] 签到写入 #\(row.seq) \(studentId) \(studentName) \(row.date) \(row.time)")
        return row.seq
    }

    private static func titleText(name: String, date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "\(name)  签到表（\(df.string(from: date))）"
    }

    private static func rebuildXLSX(dir: URL, title: String, roster: [Student]) throws {
        // v6.7.30：CSV 只存已签到的行，转成 学号→签到时间 的字典喂给全名单重建
        var signed: [String: String] = [:]
        for r in loadRows(dir: dir) { signed[r.studentId] = r.time }
        try AttendanceExporter().rebuildPersonal(
            title: title, roster: roster, signed: signed, to: xlsxURL(dir))
    }

    /// 课程下全部签到目录——v6.7.30 起按签到日期新→旧排（尾缀 _yyyy-MM-dd 解析；
    /// 解析不到用目录修改时间兜底），同一天内按名字倒序
    static func listSessions(courseName: String) -> [(dir: URL, count: Int)] {
        let base = baseDir(courseName: courseName)
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return items.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
        .map { (dir: $0, count: loadRows(dir: $0).count) }
        .sorted {
            let da = Self.sessionDate($0.dir) ?? .distantPast
            let db = Self.sessionDate($1.dir) ?? .distantPast
            if da != db { return da > db }
            return $0.dir.lastPathComponent > $1.dir.lastPathComponent
        }
    }

    /// 目录名尾缀（最后一个下划线之后）按 yyyy-MM-dd 解析；失败用修改时间兜底
    private static func sessionDate(_ dir: URL) -> Date? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tail = dir.lastPathComponent.split(separator: "_").last.map(String.init) ?? ""
        if let d = df.date(from: tail) { return d }
        return (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - 签到目录列表

struct PersonalSignInListView: View {
    let course: Course
    let students: [Student]
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [(dir: URL, count: Int)] = []
    @State private var showNew = false
    @State private var newName = ""
    @State private var newDate = Date()
    @State private var active: ActiveSession?
    @State private var shareFile: ShareableFile?

    /// fullScreenCover(item:) 需要 Identifiable 包装
    struct ActiveSession: Identifiable {
        let dir: URL
        var id: String { dir.path }
        var name: String { String(dir.lastPathComponent.dropLast(11)) }   // 去掉 _yyyy-MM-dd
        var dateText: String { String(dir.lastPathComponent.suffix(10)) }
        var date: Date {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: dateText) ?? Date()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showNew = true } label: {
                        Label("新建个人签到", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                }
                Section {
                    if sessions.isEmpty {
                        Text("暂无签到目录，点上方新建").foregroundStyle(.secondary)
                    }
                    ForEach(sessions, id: \.dir) { s in
                        HStack {
                            Button { active = ActiveSession(dir: s.dir) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.dir.lastPathComponent).foregroundStyle(.primary)
                                        Text("已签到 \(s.count) 人")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "person.crop.rectangle") }
                            }
                            Spacer()
                            Button {
                                shareFile = ShareableFile(url: PersonalSignInStore.xlsxURL(s.dir))
                            } label: {
                                Image(systemName: "square.and.arrow.up").foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { try? FileManager.default.removeItem(at: sessions[i].dir) }
                        reload()
                    }
                } header: { Text("签到目录（点开进入前置相机签到）") }
            }
            .navigationTitle("\(course.name) · 个人签到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onAppear(perform: reload)
            .sheet(isPresented: $showNew) { newSessionSheet }
            // v6.7.30：签到返回后刷新已签到人数——.onAppear 在 sheet 覆盖期间
            // 不重触发，原来返回时目录行下方的"已签到 N 人"停在进入前的数字
            .fullScreenCover(item: $active, onDismiss: reload) { s in
                PersonalSignInCameraView(session: s, course: course, students: students)
            }
            .sheet(item: $shareFile) { f in ShareSheet(items: [f.url]) }
        }
    }

    private var newSessionSheet: some View {
        NavigationStack {
            Form {
                Section("签到名称") {
                    TextField("如：第 3 周课堂签到", text: $newName)
                }
                Section("签到日期") {
                    DatePicker("日期", selection: $newDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                }
            }
            .navigationTitle("新建个人签到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showNew = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        do {
                            // v6.7.30：带课程名册，新格式签到表需要全名单
                            // （实参顺序必须与声明一致——本版首个编译错误即参数顺序反了）
                            let dir = try PersonalSignInStore.createSession(
                                courseName: course.name, name: name, date: newDate,
                                roster: students)
                            print("[个签-v6.7.30] 签到目录就绪：\(dir.path)")
                        } catch {
                            print("[个签-v6.7.30] 创建签到目录失败：\(error.localizedDescription)")
                        }
                        newName = ""
                        newDate = Date()
                        showNew = false
                        reload()
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reload() { sessions = PersonalSignInStore.listSessions(courseName: course.name) }
}

// MARK: - 前置相机签到页

struct PersonalSignInCameraView: View {
    let session: PersonalSignInListView.ActiveSession
    let course: Course
    let students: [Student]
    @StateObject private var engine: PersonalSignInEngine
    @Environment(\.dismiss) private var dismiss
    /// v6.8.1：手动签到（头像网格自领）页面开关
    @State private var showManualSign = false

    init(session: PersonalSignInListView.ActiveSession, course: Course, students: [Student]) {
        self.session = session
        self.course = course
        self.students = students
        _engine = StateObject(wrappedValue: PersonalSignInEngine(
            students: students, sessionDir: session.dir,
            sessionName: session.name, sessionDate: session.date))
    }

    var body: some View {
        ZStack {
            PersonalSignInPreview(engine: engine)
                .ignoresSafeArea()

            // 识别框 + 姓名标签（框为正立未镜像坐标，预览已镜像 → x 翻转显示）
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
                        .position(x: rect.midX,
                                  y: max(20, rect.minY - 18))   // 识别框上方
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
                        Text(session.dir.lastPathComponent).font(.headline)
                        Text("已签到 \(engine.signedCount) 人")
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

                // v6.8.1：识别失败/无法确认时的兜底入口——手动签到（头像网格自领）。
                // 与确认签到按钮互补：识别成功（确认可点）时禁用本按钮，防止
                // 已刷脸者再手动重复签/代签；识别不出（确认灰掉）时启用
                Button { showManualSign = true } label: {
                    Label("手动签到", systemImage: "person.crop.circle.badge.questionmark")
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

    /// 正立图像素坐标 → 预览视图坐标（aspectFill 裁切）。
    /// flipX=true：缓冲为真像、预览已镜像（isVideoMirrored），像素点 (x,y)
    /// 显示在 (viewW−x, y)；v6.7.20 镜像自校准锁定"缓冲即镜像"后传 false
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

// MARK: - v6.8.1 手动签到（识别失败兜底）：头像网格自领

/// 头像列表页：按名册顺序列出全部选课学生，每排 3 人（头像在上、姓名在下），
/// 可上下滑动翻页。学生找到自己的头像 → 点一下头像 → 头像中部浮出
/// 「确认签到」按钮 → 点确认即完成签到（落盘路径与刷脸签到完全一致：
/// 追加同一份 CSV、重建同一份 签到表.xlsx，该行打「√ 已签到」+ 签到时间），
/// 顶部横幅提示签到成功后自动返回人脸识别页。
/// 点错头像：直接滑动离开（不点确认不会签），或点另一个头像——选中态
/// 只有一份，旧位置的确认按钮自动消失、浮到新头像中部。
struct ManualSignInGridView: View {
    let engine: PersonalSignInEngine
    let students: [Student]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Student?
    @State private var banner: String?
    @State private var bannerOK = false

    private let columns = [GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(students) { s in
                            cell(s)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("手动签到 · 找到自己的头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
            }
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
        }
        .animation(.spring(response: 0.3), value: banner)
    }

    private func cell(_ s: Student) -> some View {
        let signed = engine.isSigned(s.studentId)
        return VStack(spacing: 6) {
            ZStack {
                avatar(s)
                if signed {
                    // 本场次已签到的学生：头像压暗 + √ 标记，不能再选（防重复签到）
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill").font(.title)
                        Text("已签到").font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.45))
                }
                if selected?.id == s.id {
                    Button { confirm(s) } label: {
                        Text("确认签到")
                            .font(.callout.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.green, in: Capsule())
                            .shadow(radius: 5)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected?.id == s.id ? Color.green : .clear, lineWidth: 3)
            )
            Text(s.name)
                .font(.subheadline.bold())
                .foregroundStyle(signed ? .secondary : .primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 选中态唯一：点新头像时旧头像上的确认按钮随选中转移自动消失
            withAnimation(.spring(response: 0.25)) {
                selected = signed ? nil : s
            }
        }
    }

    /// 头像：优先名册证件照缩略图（v6.7.18 起入库）；旧数据无照片时用姓名首字占位
    private func avatar(_ s: Student) -> some View {
        Group {
            if let data = s.photo, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.secondarySystemFill)
                    Text(String(s.name.prefix(1)))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 点头像中部的「确认签到」：与刷脸签到同一落盘路径（同一 CSV → 同一签到表.xlsx）
    private func confirm(_ s: Student) {
        do {
            try engine.manualSign(s)
            bannerOK = true
            banner = "✓ \(s.name) 签到成功"
            selected = nil
            // 短暂展示成功后返回人脸识别页（相机页还有 engine.justSigned 横幅接力提示）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
        } catch {
            bannerOK = false
            banner = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { banner = nil }
    }
}

/// 前置相机预览层（aspectFill + 镜像），方向跟随界面
struct PersonalSignInPreview: UIViewRepresentable {
    let engine: PersonalSignInEngine

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = engine.session
        v.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = v
        context.coordinator.applyOrientation()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject {
        let engine: PersonalSignInEngine
        weak var view: PreviewView?
        private var observer: NSObjectProtocol?

        init(engine: PersonalSignInEngine) {
            self.engine = engine
            super.init()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            observer = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.applyOrientation() }
        }

        deinit {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
        }

        /// 与扫描签到同一套映射：预览角度由界面方向决定（历代版本肉眼验证正确），
        /// 检测方向由引擎用同一角度换算——两套各自正确即坐标一致（v6.7.6 定案）
        func applyOrientation() {
            let angle: CGFloat
            switch UIDevice.current.orientation {
            case .landscapeLeft:       angle = 180
            case .landscapeRight:      angle = 0
            case .portraitUpsideDown: angle = 270
            default:                   angle = 90
            }
            engine.setOrientationAngle(angle)
            guard let view, let conn = view.previewLayer.connection else { return }
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            } else {
                let vo: AVCaptureVideoOrientation =
                    angle == 0 ? .landscapeRight : angle == 180 ? .landscapeLeft :
                    angle == 270 ? .portraitUpsideDown : .portrait
                if conn.isVideoOrientationSupported { conn.videoOrientation = vo }
            }
            // 前置相机预览镜像（自拍镜像体验）；识别框显示侧做 x 翻转补偿，
            // 检测/识别始终在传感器原始（未镜像）坐标系进行
            if conn.isVideoMirroringSupported, !conn.isVideoMirrored {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
    }
}

// MARK: - 识别引擎（前置相机 · 单人）

final class PersonalSignInEngine: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "personal.signin.video")
    private let students: [Student]
    private let gallery: [(idx: Int, feat: [Float])]
    // v6.9.0：补签模式下不绑定个人签到目录（sessionDir 等为 nil，
    // 落盘由 onCommit 接管）；个人签到入口仍走原 CSV 路径
    private let sessionDir: URL?
    private let sessionName: String?
    private let sessionDate: Date?

    /// v6.9.0：手动补签接管器——非 nil 时 commit 不再写个人签到 CSV/xlsx，
    /// 改由调用方负责把该学生写回原考勤表（闭包参数：学生、本次识别相似度）。
    /// 个人签到流程不设置，行为与旧版完全一致。
    var onCommit: ((Student, Float) throws -> Void)?

    // —— 发布到界面（主线程写）——
    @Published private(set) var faceBox: CGRect?      // 正立未镜像像素坐标
    @Published private(set) var faceLabel = ""
    @Published private(set) var level: MatchLevel = .unknown
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var note = "请正对前置摄像头"
    @Published private(set) var signedCount = 0
    @Published private(set) var confirmEnabled = false
    @Published private(set) var confirmTitle = "确认签到"
    /// 框显示是否需要 x 翻转补偿：缓冲为真像时预览是镜像 → 需要补偿（默认）；
    /// 镜像自校准锁定"缓冲即镜像"后取消补偿（框与预览天然同坐标系）
    @Published private(set) var displayFlipX = true
    @Published var justSigned: String?

    // 以下状态在 nonisolated 的 captureOutput（视频队列）里读写，
    // 与扫描引擎同一模式：nonisolated(unsafe) + 单队列串行访问保证安全
    nonisolated(unsafe) private var pending = false    // 上一次检测未结束则丢帧
    private var signedSids: Set<String> = []
    private var matched: Student?
    private var matchedScore: Float = 0
    nonisolated(unsafe) private var lastConfirmedSid: String?  // 刚签过的人留在镜头前不重复提示
    // EMA 多帧平均（与扫描签到 v6.7.16 同思路：α=0.4，证据取单帧与平均的高者）
    nonisolated(unsafe) private var ema: [Float] = []
    nonisolated(unsafe) private var emaFrames = 0
    nonisolated(unsafe) private var lastBox: CGRect?
    /// 界面方向角（90=竖屏），主线程写、视频线程读
    nonisolated(unsafe) private var currentAngle: CGFloat = 90
    // v6.7.20：方向自校准锁定值（界面角度一变即作废重校）——前置传感器的
    // 转正方向与教科书映射不一致（实测：教科书 .right 输入三层最高分≤0.26
    // 的颠倒崩塌，同 v6.7.2 后置案例），只能让模型同帧四方向投票
    nonisolated(unsafe) private var lockedOri: CGImagePropertyOrientation?
    nonisolated(unsafe) private var lockedAngle: CGFloat = -1
    nonisolated(unsafe) private var calibWinDeg = -1
    nonisolated(unsafe) private var calibWinStreak = 0
    // v6.7.20：镜像自校准——前置缓冲是"真像"还是"镜像"两种约定未定，
    // 用 R50 得分投票：镜像画面的对齐块是镜像脸，对图库（正像）得分崩塌；
    // 翻转版连续 3 次高出 ≥0.12 → 锁定用翻转块识别
    nonisolated(unsafe) private var flipLocked: Bool?
    nonisolated(unsafe) private var flipWins = 0
    nonisolated(unsafe) private var normWins = 0

    init(students: [Student], sessionDir: URL, sessionName: String, sessionDate: Date) {
        self.students = students
        self.gallery = students.enumerated().compactMap { i, s in
            s.feature.map { (idx: i, feat: $0) }
        }
        self.sessionDir = sessionDir
        self.sessionName = sessionName
        self.sessionDate = sessionDate
        super.init()
        let rows = PersonalSignInStore.loadRows(dir: sessionDir)
        signedSids = Set(rows.map { $0.studentId })
        signedCount = rows.count
    }

    /// v6.9.0：补签引擎——不绑定个人签到目录。alreadySigned 用于初始化
    /// 已签到集合（本场次已出勤的学生不再重复补签，扫到也只提示"已签到"）；
    /// 每次提交由 onCommit 接管（写回原考勤表 xlsx）
    init(students: [Student], alreadySigned: Set<String>,
         onCommit: @escaping (Student, Float) throws -> Void) {
        self.students = students
        self.gallery = students.enumerated().compactMap { i, s in
            s.feature.map { (idx: i, feat: $0) }
        }
        self.sessionDir = nil
        self.sessionName = nil
        self.sessionDate = nil
        self.onCommit = onCommit
        super.init()
        signedSids = alreadySigned
        signedCount = alreadySigned.count
    }

    func setOrientationAngle(_ angle: CGFloat) {
        if angle != currentAngle { lockedOri = nil; lockedAngle = -1 }  // v6.7.20：方向变了重校
        currentAngle = angle
    }

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.start() } else { self?.note = "请先在系统设置中允许使用相机" }
                }
            }
            return
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080   // 前置无 4K；单人近距离 1080p 足够
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.note = "无法打开前置相机" }
                return
            }
            self.session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }
            // 与扫描签到同一约定：数据输出连接不设旋转/镜像，缓冲保持传感器原生方向
            self.session.commitConfiguration()
            self.session.startRunning()
            print("[个签-v6.7.30] 前置相机已启动：\(self.sessionName ?? "手动补签")，候选 \(self.gallery.count) 人")
        }
    }

    func stop() {
        videoQueue.async { [weak self] in self?.session.stopRunning() }
    }

    /// 点"确认签到"（刷脸识别成功时）：追加一行 CSV 并重建 xlsx
    func confirm() {
        guard confirmEnabled, let s = matched else { return }
        do { try commit(s) } catch {
            note = "写入失败：\(error.localizedDescription)"
        }
    }

    /// v6.8.1：手动签到（头像网格自领）——与刷脸签到完全同一落盘路径：
    /// 追加同一份 CSV、重建同一份 签到表.xlsx（该行打「√ 已签到」+ 时间）。
    /// 已签到过的学号抛错，由头像网格页以横幅提示，不产生重复行。
    func manualSign(_ s: Student) throws {
        guard !signedSids.contains(s.studentId) else {
            throw NSError(domain: "PersonalSignIn", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(s.name) 已签到过"])
        }
        try commit(s)
    }

    /// v6.8.1：头像网格页用——该学号本场次是否已签到（已签到的头像打「已签到」遮罩）
    func isSigned(_ studentId: String) -> Bool { signedSids.contains(studentId) }

    /// 刷脸签到与手动签到共用的落盘提交
    private func commit(_ s: Student) throws {
        // v6.9.0：补签模式——提交动作由调用方接管（写回原考勤表 xlsx），
        // 其余状态维护（已签到集合/计数/横幅）与刷脸路径保持一致
        if let onCommit {
            try onCommit(s, matchedScore)
            signedSids.insert(s.studentId)
            lastConfirmedSid = s.studentId
            signedCount += 1
            justSigned = "✓ \(s.name) 补签成功"
            confirmEnabled = false
            confirmTitle = "已签到"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.justSigned = nil
            }
            print(String(format: "[补签-v6.9.0] 扫脸补签 %@ %@（相似度 %.3f）",
                         s.studentId, s.name, matchedScore))
            return
        }
        guard let sessionDir, let sessionName, let sessionDate else {
            throw NSError(domain: "PersonalSignIn", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "签到目录未绑定，无法写入"])
        }
        let seq = try PersonalSignInStore.append(
            dir: sessionDir, name: sessionName, sessionDate: sessionDate,
            studentId: s.studentId, studentName: s.name,
            roster: students)
        signedSids.insert(s.studentId)
        lastConfirmedSid = s.studentId
        signedCount += 1
        justSigned = "✓ \(s.name) 已签到（第 \(seq) 人）"
        confirmEnabled = false
        confirmTitle = "已签到"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.justSigned = nil
        }
        print("[个签-v6.8.1] 签到写入 #\(seq) \(s.studentId) \(s.name)（刷脸/手动共用路径）")
    }

    // MARK: - 视频帧处理（videoQueue，检测约 0.5s/次，自然节流约 2Hz）

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !pending, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pending = true
        defer { pending = false }
        let t0 = CACurrentMediaTime()

        // v6.7.20：方向自校准——同帧四方向让模型投票（胜出方向的人脸结果
        // 直接复用为本帧检测结果，不重复推理）
        let (ori, faces, cgDetected) = detectWithCalibration(pb)
        let rot = SCRFDDetector.rotationTransform(
            ori, w: CGFloat(CVPixelBufferGetWidth(pb)), h: CGFloat(CVPixelBufferGetHeight(pb)))
        let detMs = (CACurrentMediaTime() - t0) * 1000

        // 取最大脸（个人签到场景一次一人）
        let face = faces.filter { $0.box.height >= 60 }.max {
            $0.box.width * $0.box.height < $1.box.width * $1.box.height
        }
        guard let f = face else {
            ema = []; emaFrames = 0; lastBox = nil; lastConfirmedSid = nil
            DispatchQueue.main.async {
                self.imageSize = CGSize(width: rot.uw, height: rot.uh)
                self.faceBox = nil
                self.level = .unknown
                self.matched = nil
                self.note = "请正对前置摄像头"
                self.confirmEnabled = false
                self.confirmTitle = "确认签到"
            }
            return
        }

        // EMA 连续性：框跳动大说明换了人/丢了目标，重置平均
        if let lb = lastBox, Self.iou(lb, f.box) < 0.3 { ema = []; emaFrames = 0 }
        lastBox = f.box

        // 对齐 + 饱和闸 + R50 + 范数闸（与扫描签到同一链路）；
        // v6.7.20：镜像锁定后改用水平翻转图 + 镜像关键点
        var feature: [Float]?
        if let cg0 = cgDetected ?? SCRFDDetector.uprightCGImage(from: pb, orientation: ori) {
            var cg = cg0
            var kps = f.kps
            if flipLocked == true, let fc = Self.flippedCG(cg0) {
                cg = fc
                kps = kps.map { CGPoint(x: CGFloat(cg0.width) - $0.x, y: $0.y) }
            }
            feature = Self.embedFace(cg: cg, kps: kps)
        }

        var bestIdx: Int?
        var best: Float = 0
        var second: Float = 0
        if let feat = feature, !gallery.isEmpty {
            if ema.isEmpty { ema = feat } else {
                for k in 0..<min(ema.count, feat.count) {
                    ema[k] = ema[k] * 0.6 + feat[k] * 0.4
                }
            }
            emaFrames += 1
            // 证据向量：单帧与 EMA 分别打分，取归属的高者（同扫描签到 v6.7.16）
            var vectors: [[Float]] = [feat]
            if emaFrames >= 2 {
                var n: Float = 0
                vDSP_svesq(ema, 1, &n, vDSP_Length(ema.count))
                if n > 1e-6 {
                    var s = 1 / sqrtf(n)
                    var normed = [Float](repeating: 0, count: ema.count)
                    vDSP_vsmul(ema, 1, &s, &normed, 1, vDSP_Length(ema.count))
                    vectors.append(normed)
                }
            }
            for v in vectors {
                let r = topScore(v)
                if r.best > best { best = r.best; bestIdx = r.idx; second = r.second }
            }
        }

        // v6.7.20 镜像自校准探针：方向已锁定、镜像未定时，低分帧加跑一次
        // 水平翻转对齐块对比图库——真像 R50 高分、镜像脸对齐块得分崩塌；
        // 翻转版连续 3 次高出 ≥0.12 → 锁定用翻转块识别（框显示同步取消 x 补偿）
        if flipLocked == nil, lockedOri != nil, feature != nil, best < Thresholds.confirmed,
           let c0 = cgDetected ?? SCRFDDetector.uprightCGImage(from: pb, orientation: ori),
           let fc = Self.flippedCG(c0) {
            let mkps = f.kps.map { CGPoint(x: CGFloat(c0.width) - $0.x, y: $0.y) }
            if let ff = Self.embedFace(cg: fc, kps: mkps) {
                let fr = topScore(ff)
                if fr.best - best > 0.12 { flipWins += 1; normWins = 0 }
                else if best - fr.best > 0.12 { normWins += 1; flipWins = 0 }
                print(String(format:
                    "[个签-v6.7.30] 镜像探针：正向=%.3f 翻转=%.3f（翻连胜=%d 正连胜=%d）",
                    best, fr.best, flipWins, normWins))
                if flipWins >= 3 {
                    flipLocked = true
                    ema = []; emaFrames = 0
                    DispatchQueue.main.async { self.displayFlipX = false }
                    print("[个签-v6.7.30] 镜像校准锁定：缓冲为镜像画面 → 识别改用翻转块")
                } else if normWins >= 3 {
                    flipLocked = false
                    print("[个签-v6.7.30] 镜像校准锁定：缓冲为正立真像")
                }
            }
        }

        let stu = bestIdx.map { students[$0] }
        let ambiguous = best > 0 && (best - second) < 0.05
        let lvl: MatchLevel =
            feature == nil ? .unknown :
            best >= Thresholds.confirmed && !ambiguous ? .confirmed :
            best >= Thresholds.uncertain ? .uncertain : .unknown
        let ms = (CACurrentMediaTime() - t0) * 1000
        print(String(format: "[个签-v6.7.30] 检测=%.0fms 总=%.0fms 脸=%dx%d top1=%@ %.3f %@",
                     detMs, ms, Int(f.box.width), Int(f.box.height),
                     stu?.name ?? "—", best, lvl.thresholdText))

        DispatchQueue.main.async {
            self.imageSize = CGSize(width: rot.uw, height: rot.uh)
            self.faceBox = f.box
            self.level = lvl
            self.matched = (lvl == .confirmed) ? stu : nil
            self.matchedScore = best
            if let s = stu, lvl == .confirmed {
                if self.signedSids.contains(s.studentId) || self.lastConfirmedSid == s.studentId {
                    self.faceLabel = "\(s.name)（已签到）"
                    self.note = "\(s.name) 今天已签到过"
                    self.confirmEnabled = false
                    self.confirmTitle = "已签到"
                } else {
                    self.faceLabel = String(format: "%@ %.2f", s.name, best)
                    self.note = "已识别：\(s.name)，请点确认签到"
                    self.confirmEnabled = true
                    self.confirmTitle = "确认签到"
                }
            } else if let s = stu, lvl == .uncertain {
                self.faceLabel = String(format: "%@？ %.2f", s.name, best)
                self.note = "疑似 \(s.name)，请正对摄像头保持不动"
                self.confirmEnabled = false
                self.confirmTitle = "确认签到"
            } else {
                self.faceLabel = "未识别"
                self.note = feature == nil ? "画面质量不足，请靠近光线好的位置"
                                           : "未识别到本课程学生"
                self.confirmEnabled = false
                self.confirmTitle = "确认签到"
            }
        }
    }

    /// v6.7.20：同帧四方向探测，让 SCRFD 投票选出真正的转正方向。
    /// 依据（v6.7.2/v6.7.5 实锤）：SCRFD 对正立人脸召回极高、对旋转/颠倒
    /// 人脸召回崩塌，四个方向检出数是数量级差距。单人场景没有扫描引擎的
    /// "≥8 脸"条件，改为：① winner ≥1 脸且其余全 0 → 立即锁定；
    /// ② 同一方向连续 2 次严格胜出 → 锁定。未锁定时返回本轮最优方向的
    /// 结果（教科书方向恰好正确则零延迟出框）
    /// v6.7.21：返回值带出正立 CGImage（检测/识别/镜像探针复用同一帧渲染）
    nonisolated private func detectWithCalibration(
        _ pb: CVPixelBuffer
    ) -> (ori: CGImagePropertyOrientation, faces: [SCRFDDetector.Face], cg: CGImage?) {
        let angle = currentAngle
        if let l = lockedOri, lockedAngle == angle {
            var cg: CGImage?
            let fs = detectFaces(pb: pb, ori: l, cg: &cg)
            return (l, fs, cg)
        }
        let dirs: [(CGImagePropertyOrientation, Int)] =
            [(.up, 0), (.right, 90), (.down, 180), (.left, 270)]
        var best: (o: CGImagePropertyOrientation, deg: Int,
                   faces: [SCRFDDetector.Face], cg: CGImage?) = (.up, 0, [], nil)
        var counts: [Int] = []
        for (o, deg) in dirs {
            var cg: CGImage?
            let fs = detectFaces(pb: pb, ori: o, cg: &cg).filter { $0.score >= 0.5 }
            counts.append(fs.count)
            if fs.count > best.faces.count { best = (o, deg, fs, cg) }
        }
        let summary = "0°=\(counts[0])脸 90°=\(counts[1])脸 180°=\(counts[2])脸 270°=\(counts[3])脸"
        let second = counts.sorted(by: >)[1]
        if !best.faces.isEmpty, best.faces.count > second {
            if best.deg == calibWinDeg { calibWinStreak += 1 }
            else { calibWinDeg = best.deg; calibWinStreak = 1 }
        } else { calibWinDeg = -1; calibWinStreak = 0 }
        let decisive = !best.faces.isEmpty && second == 0
        if decisive || calibWinStreak >= 2 {
            lockedOri = best.o
            lockedAngle = angle
            print("[个签-v6.7.30] 方向校准：\(summary) → 锁定 \(best.deg)°")
        } else {
            print("[个签-v6.7.30] 方向校准未定：\(summary)（连胜=\(calibWinStreak)）")
        }
        return (best.faces.isEmpty ? AttendanceEngine.orientation(for: angle) : best.o,
                best.faces, best.cg)
    }

    /// v6.7.21：两级量程检测——SCRFD-10GF 对占屏过半的大脸失效（超出锚点
    /// 量程；离线实锤：用户截图半屏脸 zoom1 零检出、等效拉远 2× 后 0.85
    /// 稳定检出）。前置自拍距离脸必然偏大：zoom1 无脸时把内容缩小一半
    /// 居中补黑（等效视野拉远 2×）再检一次，坐标映射回正立原图。
    /// cg 为缓入缓存参数：zoom2 需要正立图时渲染一次，留给识别复用
    /// v6.7.22：量程阶梯 1×/2×/3×/4× + 成功倍率缓存——20cm 贴脸（脸占屏
    /// 九成）也能落到检测量程内（÷4 → 22%）；缓存上帧成功倍率并优先尝试，
    /// 人脸距离不变时每帧只跑 1 次检测。倍率只作用于检测：识别始终用
    /// 原图全分辨率 + 映射回的关键点，框也框住原图大脸
    /// v6.7.23：检测切 640² 快检实例（sharedFast，见 SCRFDDetector 注释）——
    /// det_10g 原生即 640²，1920² 是 9× 像素的硬跑（CPU ~5.7s/帧=出框慢
    /// 的根源）；640² 单次 ~20-60ms，配合 zoom 缓存，出框进 0.2s 预算
    nonisolated(unsafe) private var lastGoodZoom: CGFloat = 0   // 0=无缓存

    nonisolated private func detectFaces(pb: CVPixelBuffer,
                                         ori: CGImagePropertyOrientation,
                                         cg: inout CGImage?) -> [SCRFDDetector.Face] {
        let ladder: [CGFloat] = [1, 2, 3, 4]
        // v6.7.23：无缓存时先试 zoom2——离线实锤自拍距离（脸占屏过半）
        // zoom1 必空检，先试它白花一次推理；zoom2 对贴脸大脸与一臂远小脸
        // 都能检出（等效视野拉远后均落进 SCRFD 量程），是全场最优起手
        let order = lastGoodZoom > 0
            ? [lastGoodZoom] + ladder.filter { $0 != lastGoodZoom } : [2, 1, 3, 4]
        for z in order {
            if z == 1 {
                let f1 = SCRFDDetector.sharedFast.detect(pixelBuffer: pb, orientation: ori,
                                                         maxSideFactor: 2.0)
                if !f1.isEmpty { lastGoodZoom = 1; return f1 }
                continue
            }
            if cg == nil { cg = SCRFDDetector.uprightCGImage(from: pb, orientation: ori) }
            guard let c = cg, let zz = Self.zoomedOutCG(c, z: z) else { return [] }
            var fz = SCRFDDetector.sharedFast.detect(in: zz, thresh: 0.5, maxSideFactor: 2.0)
            if fz.isEmpty { continue }
            // zoomed 图与原图同尺寸、内容缩小 z 倍居中：x = (x' − W(1−1/z)/2) × z
            let W = CGFloat(c.width), H = CGFloat(c.height)
            let ox = W * (1 - 1 / z) / 2, oy = H * (1 - 1 / z) / 2
            for i in fz.indices {
                var b = fz[i].box
                b.origin = CGPoint(x: (b.minX - ox) * z, y: (b.minY - oy) * z)
                b.size = CGSize(width: b.width * z, height: b.height * z)
                fz[i].box = b
                fz[i].kps = fz[i].kps.map { CGPoint(x: ($0.x - ox) * z, y: ($0.y - oy) * z) }
            }
            lastGoodZoom = z
            print("[个签-v6.7.30] 大脸量程兜底：zoom\(Int(z)) 检出 \(fz.count) 脸（zoom1 无检出）")
            return fz
        }
        lastGoodZoom = 0
        return []
    }

    /// 内容缩小 z 倍居中、四周补黑（等效视野拉远）——Quartz 绘制，与
    /// uprightCGImage 同一"恒等绘制即正"约定，方向不变
    nonisolated private static func zoomedOutCG(_ cg: CGImage, z: CGFloat) -> CGImage? {
        let W = cg.width, H = cg.height
        guard let ctx = CGContext(data: nil, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let dw = CGFloat(W) / z, dh = CGFloat(H) / z
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2,
                                width: dw, height: dh))
        return ctx.makeImage()
    }

    /// 对齐 + 饱和闸 + R50 + 范数闸（与扫描签到同一链路），返回归一化特征
    nonisolated private static func embedFace(cg: CGImage, kps: [CGPoint]) -> [Float]? {
        guard let m = FaceAligner.similarityTransform(src: kps, dst: FaceAligner.template),
              let pb112 = FaceAligner.alignedPixelBuffer(cgImage: cg, transform: m)
        else { return nil }
        let sat = FaceAligner.meanSaturation(pb112)
        guard sat >= 0.15, let r = FaceRecognizer.shared.embedWithRawNorm(pb112),
              r.rawNorm >= 14 else {
            print(String(format: "[个签-v6.7.30] 闸拦截：饱和/范数未过（饱和=%.2f）", sat))
            return nil
        }
        return r.vec
    }

    /// Quartz 水平翻转（不用 CI 仿射——v6.7.5 教训：CI 仿射渲染几何不可信）
    nonisolated private static func flippedCG(_ cg: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(cg.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// 特征对图库打分：返回 (top1 学生下标, top1 分, top2 分)
    nonisolated private func topScore(_ feat: [Float]) -> (idx: Int?, best: Float, second: Float) {
        var scored: [(Int, Float)] = gallery.map { ($0.idx, FaceRecognizer.cosine(feat, $0.feat)) }
        scored.sort { $0.1 > $1.1 }
        return (scored.first?.0, scored.first?.1 ?? 0, scored.count > 1 ? scored[1].1 : 0)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let x1 = max(a.minX, b.minX), y1 = max(a.minY, b.minY)
        let x2 = min(a.maxX, b.maxX), y2 = min(a.maxY, b.maxY)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        return Float(inter / (a.width * a.height + b.width * b.height - inter + 1e-6))
    }
}
