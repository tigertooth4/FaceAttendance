import SwiftUI
import UniformTypeIdentifiers   // .spreadsheet (fileImporter)
import QuickLook               // xlsx 应用内预览

// MARK: - 课程列表

struct CourseListView: View {
    @State private var courses: [Course] = []
    @State private var showNewCourse = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(courses) { c in
                    NavigationLink(destination: CourseDetailView(course: c)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.name).font(.headline)
                            // v6.7.30：总人数 = 已提取人脸特征的人数（名册里没提取出特征的不计入）
                            Text("学生 \(c.featureCount) 人 · 创建于 \(c.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { Database.shared.deleteCourse(courses[i].id) }
                    reload()
                }
            }
            .navigationTitle("我的课程")
            .toolbar {
                Button { showNewCourse = true } label: { Image(systemName: "plus") }
            }
            .alert("新建课程", isPresented: $showNewCourse) {
                TextField("课程名称，如：微分几何", text: $newName)
                Button("创建") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        _ = Database.shared.createCourse(name: name)
                        newName = ""
                        reload()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() { courses = Database.shared.listCourses() }
}

// MARK: - 课程详情

struct CourseDetailView: View {
    let course: Course
    @State private var students: [Student] = []
    @State private var featureCount = 0
    @State private var showImporter = false
    @State private var importProgress: String?
    @State private var importError: String?
    @State private var showAttendance = false
    @State private var showPhotoAttendance = false
    @State private var showRandomPick = false
    @State private var showRandomNumber = false
    @State private var showPersonalSignIn = false
    @State private var showHistory = false

    var body: some View {
        List {
            Section {
                if students.isEmpty {
                    Text("尚未导入花名册").foregroundStyle(.secondary)
                } else {
                    // v6.7.30：总人数 = 已提取人脸特征的人数
                    Text("共 \(featureCount) 人")
                }
                // v6.7.14：构建戳常驻花名册页——任何截图自带版本，便于核对构建
                Text("构建 \(Thresholds.buildVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    showImporter = true
                } label: {
                    Label(students.isEmpty ? "导入花名册（.xlsx）" : "重新导入花名册",
                          systemImage: "square.and.arrow.down")
                }
                if let p = importProgress {
                    Text(p).font(.caption).foregroundStyle(.secondary)
                }
                if let e = importError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            } header: { Text("花名册") }

            Section {
                Button {
                    showAttendance = true
                } label: {
                    Label("开始签到（相机扫描）", systemImage: "camera.viewfinder")
                        .font(.headline)
                }
                Button {
                    showPhotoAttendance = true
                } label: {
                    Label("照片签到（上传照片）", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                }
                .disabled(featureCount == 0)
                Button {
                    showPersonalSignIn = true
                } label: {
                    // v6.7.30：入口改名——功能不变（前置相机逐个识别人脸签到）
                        Label("人脸识别签到", systemImage: "person.crop.rectangle.badge.plus")
                        .font(.headline)
                }
                .disabled(featureCount == 0)
                if featureCount == 0 {
                    Text("请先导入花名册并提取人脸特征").font(.caption).foregroundStyle(.secondary)
                }
            }

            // v6.7.30：随机点名 + 随机数生成并为一组"课堂随机工具"
            Section {
                Button {
                    showRandomPick = true
                } label: {
                    Label("随机点名（已提取特征的学生中均匀抽取）", systemImage: "person.fill.questionmark")
                        .font(.headline)
                }
                .disabled(featureCount == 0)
                Button {
                    showRandomNumber = true
                } label: {
                    Label("随机数生成（输入 n，均匀抽取 1 ~ n）", systemImage: "dice")
                        .font(.headline)
                }
            }

            Section {
                Button { showHistory = true } label: {
                    Label("历史考勤记录", systemImage: "folder")
                }
            }
        }
        .navigationTitle(course.name)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.spreadsheet]) { result in
            guard case .success(let url) = result else { return }
            importRoster(url)
        }
        .fullScreenCover(isPresented: $showAttendance) {
            AttendanceView(course: course, students: students)
        }
        .sheet(isPresented: $showPhotoAttendance) {
            PhotoAttendanceView(course: course, students: students)
        }
        .sheet(isPresented: $showRandomPick) {
            RandomPickView(course: course, students: students)
        }
        .sheet(isPresented: $showRandomNumber) {
            RandomNumberView(course: course)
        }
        .sheet(isPresented: $showPersonalSignIn) {
            PersonalSignInListView(course: course, students: students)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(course: course)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        students = Database.shared.students(courseId: course.id)
        featureCount = Database.shared.featureCount(courseId: course.id)
    }

    private func importRoster(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        importProgress = "解析花名册…"
        importError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            defer { url.stopAccessingSecurityScopedResource() }
            // 模型未加载成功时直接报错，不要静默地让所有人脸提取失败
            if let err = SCRFDDetector.shared.loadError ?? FaceRecognizer.shared.loadError {
                DispatchQueue.main.async {
                    importProgress = nil
                    importError = "模型未就绪：\(err)"
                }
                return
            }
            do {
                let entries = try RosterParser().parse(url: url)
                let total = entries.count
                var ok = 0
                var failed: [String] = []
                var failedDetail: [String] = []
                var feats: [(String, [Float])] = []   // v6.7.4：收集特征算库内区分度
                for (i, e) in entries.enumerated() {
                    DispatchQueue.main.async {
                        importProgress = "提取人脸特征 \(i + 1)/\(total)：\(e.name)"
                    }
                    // 后台线程没有 runloop，Vision/ML 的 autoreleased 中间对象会堆积
                    // 直到系统杀进程——每张照片处理完立即排空
                    // v6.1：失败后自动重试一次（排除连续批量处理时的瞬时渲染/推理失败），
                    // 并留存该照片当时的具体失败原因
                    var feature: [Float]? = nil
                    var thumb: Data? = nil   // v6.7.18：证件照缩略图入库（随机点名头像）
                    var reason = "照片数据无法解码（文件可能损坏）"
                    for attempt in 1...2 where feature == nil {
                        var decoded = false
                        autoreleasepool {
                            if let img = UIImage(data: e.photoData) {
                                decoded = true
                                if thumb == nil { thumb = rosterThumb(img) }
                                // v6.7.4：全员打印原始范数；前 5 人的对齐块存盘待分享
                                feature = FaceRecognizer.shared.featureFromPhoto(
                                    img,
                                    diagTag: "第\(i + 1)人_\(e.name)_\(e.studentId)",
                                    dumpCrop: i < 5)
                            }
                        }
                        if decoded, feature == nil, let r = FaceRecognizer.shared.lastFailReason {
                            reason = r
                        }
                        if attempt == 1 && feature == nil {
                            print("[导入] \(e.studentId) \(e.name) 首试失败：\(reason)，自动重试")
                        } else if attempt == 2 && feature != nil {
                            print("[导入] \(e.studentId) \(e.name) 重试成功")
                        }
                    }
                    if let f = feature {
                        ok += 1
                        feats.append((e.studentId, f))
                    } else {
                        failed.append("\(e.studentId) \(e.name)")
                        failedDetail.append("\(e.studentId) \(e.name)：\(reason)")
                        print("[导入失败] \(e.studentId) \(e.name)：\(reason)")
                    }
                    Database.shared.upsertStudent(courseId: course.id, studentId: e.studentId,
                                                  name: e.name, className: e.className,
                                                  feature: feature, photo: thumb)
                }
                // v6.7.1：记录特征管线版本戳——对齐块方向 v6.7 起翻转，
                // 旧管线特征与新探针余弦≈0（实测 0.008），必然全红；
                // 照片签到会校验此戳，不匹配时显著提示重导
                // v6.7.30：全量替换语义——本次名册里没有的学号从库中移除
                //（名册删了人重导后总人数不再停在旧人数）；空名册不触发删除，
                // 防止误传空表把整班清掉
                var removedStale: [String] = []
                if total > 0 {
                    removedStale = Database.shared.deleteStudentsNotIn(
                        courseId: course.id, keepIds: Set(entries.map { $0.studentId }))
                    if !removedStale.isEmpty {
                        print("[导入] 移除旧名单残留 \(removedStale.count) 人：\(removedStale.joined(separator: "、"))")
                    }
                }
                UserDefaults.standard.set(Thresholds.featurePipelineVersion,
                                          forKey: "featurePipelineVersion")
                print("[导入-v6.7.5] 特征管线=\(Thresholds.featurePipelineVersion) 已重建 \(ok)/\(total) 人")
                // v6.7.4 库内区分度自检：两两余弦分布是"特征是否塌陷"的照妖镜。
                // ONNX 参考：mean=0.095 p99=0.304 max=0.396；若 mean>0.5 即全员挤成
                // 一团（必然是设备端对齐块/张量通路问题，与模型无关）
                if feats.count >= 2 {
                    var sims: [Float] = []
                    sims.reserveCapacity(feats.count * (feats.count - 1) / 2)
                    for a in 0..<feats.count {
                        for b in (a + 1)..<feats.count {
                            sims.append(FaceRecognizer.cosine(feats[a].1, feats[b].1))
                        }
                    }
                    sims.sort()
                    let mean = sims.reduce(0, +) / Float(sims.count)
                    let p99 = sims[min(sims.count - 1, Int(Float(sims.count - 1) * 0.99))]
                    let mx = sims.last ?? 0
                    print(String(format:
                        "[导入-v6.7.5] 库内区分度：%d对 mean=%.3f p99=%.3f max=%.3f（参考0.095/0.304/0.396，明显偏高即特征塌陷）",
                        sims.count, mean, p99, mx))
                }
                DispatchQueue.main.async {
                    // v6.7.14：结果行带构建戳——截图即可确认跑的是新构建
                    importProgress = "导入完成：\(ok)/\(total) 人成功（构建 \(Thresholds.buildVersion) · 特征管线 \(Thresholds.featurePipelineVersion)）"
                        + (failed.isEmpty ? "" : "；未检出人脸：\(failed.prefix(5).joined(separator: "、"))")
                        + (failed.count > 5 ? " 等\(failed.count)人" : "")
                        + (removedStale.isEmpty ? "" : "；已移除旧名单多出的 \(removedStale.count) 人")
                    // 有失败时展示具体原因（含该照片当时的画布/张量/最高分诊断，
                    // Xcode 控制台有逐人完整 [导入失败] 日志）
                    if !failedDetail.isEmpty {
                        importError = failedDetail.prefix(2).joined(separator: "\n")
                    }
                    reload()
                }
            } catch {
                DispatchQueue.main.async {
                    importProgress = nil
                    importError = error.localizedDescription
                }
            }
        }
    }

    /// v6.7.18：证件照缩略图（随机点名头像用）——长边压到 320px、jpeg 0.85，
    /// 90 人合计约 2MB；UIGraphics 的 draw(in:) 会自动按 EXIF 方向绘制，
    /// 与 v6.7.14 的特征提取方向归一化同口径，头像不会侧躺
    private func rosterThumb(_ img: UIImage) -> Data? {
        let maxSide: CGFloat = 320
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * s).rounded(),
                          height: (img.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1   // 不按屏幕 3x 放大，像素尺寸即逻辑尺寸
        return UIGraphicsImageRenderer(size: size, format: fmt)
            .jpegData(withCompressionQuality: 0.85) { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }
    }
}

// MARK: - 历史考勤记录

struct HistoryView: View {
    let course: Course
    @State private var sessions: [(url: URL, count: Int, date: Date)] = []
    @State private var looseFiles: [URL] = []
    @State private var shareFile: ShareableFile?
    @State private var previewFile: ShareableFile?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty && looseFiles.isEmpty {
                    Text("暂无考勤记录").foregroundStyle(.secondary)
                }
                // v6.7.12：每场签到一个文件夹（标注图+原图+Excel+诊断图），
                // 点进去看该场全部文件；左滑删除整场
                if !sessions.isEmpty {
                    Section("签到场次") {
                        ForEach(sessions, id: \.url) { s in
                            NavigationLink {
                                SessionFolderView(course: course, url: s.url)
                            } label: {
                                Label("\(s.url.lastPathComponent)（\(s.count) 个文件）",
                                      systemImage: "folder.fill")
                            }
                        }
                        .onDelete { idx in
                            for i in idx {
                                try? FileManager.default.removeItem(at: sessions[i].url)
                            }
                            loadFiles()
                        }
                    }
                }
                if !looseFiles.isEmpty {
                    Section("其他文件（旧版结构）") {
                        ForEach(looseFiles, id: \.self) { url in
                            FileRow(url: url, previewFile: $previewFile,
                                    shareFile: $shareFile, course: course)
                        }
                        .onDelete { idx in
                            for i in idx {
                                try? FileManager.default.removeItem(at: looseFiles[i])
                            }
                            loadFiles()
                        }
                    }
                }
            }
            .navigationTitle("\(course.name) · 考勤记录")
            .toolbar { Button("完成") { dismiss() } }
            .onAppear(perform: loadFiles)
            .sheet(item: $previewFile) { file in
                NavigationStack {
                    QuickLookPreview(url: file.url)
                        .navigationTitle(file.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { previewFile = nil } }
                }
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url])
            }
        }
    }

    private func loadFiles() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("exports")
            .appendingPathComponent(course.name.components(separatedBy:
                CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined())
        let fm = FileManager.default
        let fileExts = ["xlsx", "jpg", "jpeg", "png", "heic"]
        var sess: [(URL, Int, Date)] = []
        var loose: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in top {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let sub = (try? fm.contentsOfDirectory(at: u,
                            includingPropertiesForKeys: nil)) ?? []
                if u.lastPathComponent.hasSuffix("的签到") {
                    // v6.7.12 场次文件夹：按修改时间倒序（文件夹名里的
                    // "M月d日"按字符串排序会乱，如"10月"排到"9月"前面）
                    let mdate = (try? u.resourceValues(
                        forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ?? .distantPast
                    sess.append((u, sub.count, mdate))
                } else {
                    // 旧版按日子文件夹（照片标注_2026-09-04）：内容平铺进"其他文件"
                    loose += sub.filter { fileExts.contains($0.pathExtension.lowercased()) }
                }
            } else if fileExts.contains(u.pathExtension.lowercased()) {
                loose.append(u)
            }
        }
        sessions = sess.sorted { $0.2 > $1.2 }
        looseFiles = loose.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// MARK: - 场次文件夹内容

/// v6.7.12：单场签到的全部文件（考勤表/标注图/原图/诊断图），
/// 点文件名预览、点图标分享、左滑删除单个文件
struct SessionFolderView: View {
    let course: Course
    let url: URL
    @State private var files: [URL] = []
    @State private var shareFile: ShareableFile?
    @State private var previewFile: ShareableFile?
    // v6.9.0：手动补签——选中的考勤表 + 多场选择/无表提示
    @State private var makeupFile: ShareableFile?
    @State private var pickMakeup = false
    @State private var noSheetAlert = false

    private var xlsxFiles: [URL] {
        files.filter { $0.pathExtension.lowercased() == "xlsx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        List {
            ForEach(files, id: \.self) { f in
                FileRow(url: f, previewFile: $previewFile, shareFile: $shareFile,
                        course: course)
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                load()
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // v6.9.0：进场次后右上角「手动补签」，对这场 xlsx 补签（写回同一份表）
            Button {
                let xs = xlsxFiles
                if xs.count == 1 {
                    makeupFile = ShareableFile(url: xs[0])
                } else if xs.count > 1 {
                    pickMakeup = true
                } else {
                    noSheetAlert = true
                }
            } label: {
                Label("手动补签", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("选择要补签的考勤表", isPresented: $pickMakeup,
                            titleVisibility: .visible) {
            ForEach(xlsxFiles, id: \.self) { f in
                Button(f.lastPathComponent) { makeupFile = ShareableFile(url: f) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("本场次没有 Excel 考勤表", isPresented: $noSheetAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("补签针对的是相机扫描/照片签到生成的 xlsx 考勤表")
        }
        .sheet(item: $makeupFile) { file in
            MakeupSignView(course: course, fileURL: file.url)
        }
        .sheet(item: $previewFile) { file in
            NavigationStack {
                QuickLookPreview(url: file.url)
                    .navigationTitle(file.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("关闭") { previewFile = nil } }
            }
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func load() {
        files = ((try? FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// 文件行：点名字预览，点图标分享（历史记录与场次文件夹共用）。
/// v6.9.0：course 非空且是 xlsx 时，多出「手动补签」入口（写回同一份表）
struct FileRow: View {
    let url: URL
    @Binding var previewFile: ShareableFile?
    @Binding var shareFile: ShareableFile?
    var course: Course? = nil
    @State private var showMakeup = false

    var body: some View {
        HStack {
            Button { previewFile = ShareableFile(url: url) } label: {
                Label(url.lastPathComponent, systemImage: icon)
                    .foregroundStyle(.primary)
            }
            Spacer()
            if let course, url.pathExtension.lowercased() == "xlsx" {
                Button { showMakeup = true } label: {
                    Image(systemName: "pencil.and.list.clipboard")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("手动补签")
            }
            Button { shareFile = ShareableFile(url: url) } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
        }
        .sheet(isPresented: $showMakeup) {
            if let course {
                MakeupSignView(course: course, fileURL: url)
            }
        }
    }

    private var icon: String {
        switch url.pathExtension.lowercased() {
        case "xlsx": return "tablecells"
        case "jpg", "jpeg", "png", "heic": return "photo"
        default: return "doc"
        }
    }
}

/// 系统分享面板（微信/AirDrop/邮件/存到文件…）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Quick Look 应用内文件预览（支持 xlsx）
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { url as QLPreviewItem }
    }
}
