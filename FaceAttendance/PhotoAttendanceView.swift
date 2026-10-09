import SwiftUI
import PhotosUI
import ImageIO

/// 照片签到：上传多张班级照片 → 逐张检测/识别/标注 → 多照片融合 → 导出 Excel。
/// 与实时扫描并行存在，共用同一套识别模型与阈值。
/// v6.7.30：识别完成即【自动】保存 Excel 到场次文件夹（此前只在手动点
/// "保存签到结果到 Excel"时才生成——与相机扫描的自动导出行为不一致，
/// 不点按钮历史记录里就永远没有 Excel）；识别前打印库内区分度
/// （mean/p99/max），一次性区分"特征库质量差"与"现场探针问题"。
/// v6.7.31：场次文件夹默认只留 原图/标注图/Excel——SCRFD 画布与对齐块等
/// 调试图不再默认存盘（总闸 SCRFDDetector.debugArtifactsEnabled，照片签到页
/// 「调试模式」开关可临时打开排查问题）；拍照入口的照片也不再写系统相册。
struct PhotoAttendanceView: View {
    let course: Course
    let students: [Student]

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var processing = false
    @State private var progress = ""
    @State private var annotated: [ShareableFile] = []   // 标注后照片（已存盘）
    @State private var photoTime: Date?
    @State private var summary: (confirmed: Int, uncertain: Int, absent: Int)?
    @State private var rows: [(student: Student, present: Bool, method: String,
                               hits: Int, score: Float)] = []
    @State private var exportedFile: ShareableFile?
    @State private var previewFile: ShareableFile?
    @State private var error: String?
    /// v6.7.30：识别完成时自动保存的 Excel（场次文件夹内），
    /// 手动点"保存签到结果到 Excel"直接分享它，不重复写盘
    @State private var autoSavedURL: URL?
    // v6.7.15：连拍相机入口
    @State private var showCamera = false
    @State private var cameraPhotos: [(data: Data, takenAt: Date?)] = []
    @State private var cameraRunToken = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $pickerItems, matching: .images) {
                        Label("选择班级照片（可多选）", systemImage: "photo.on.rectangle.angled")
                    }
                    // v6.7.15：连拍相机——拍完自动存系统相册，点「开始签到」直接进识别
                    Button { showCamera = true } label: {
                        Label("拍摄班级照片（可连拍，自动存入相册）", systemImage: "camera.fill")
                    }
                    if processing { Text(progress).font(.caption).foregroundStyle(.secondary) }
                    if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
                } header: { Text("照片") }

                if let s = summary {
                    Section {
                        Text("签到时间：\(photoTime?.formatted(date: .abbreviated, time: .shortened) ?? "未知")（取自照片拍摄时间）")
                            .font(.caption)
                        HStack(spacing: 16) {
                            Label("\(s.confirmed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Label("\(s.uncertain)", systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
                            Label("\(s.absent)", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        if let url = autoSavedURL {
                            Label("Excel 已自动保存：\(url.lastPathComponent)（历史考勤记录中可随时导出）",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    } header: { Text("签到结果（绿=已确认 橙=待确认 红=缺勤）") }
                }

                if !annotated.isEmpty {
                    Section {
                        ForEach(annotated) { f in
                            Button { previewFile = f } label: {
                                HStack {
                                    if let ui = UIImage(contentsOfFile: f.url.path) {
                                        Image(uiImage: ui)
                                            .resizable().scaledToFill()
                                            .frame(width: 64, height: 48)
                                            .clipped().cornerRadius(6)
                                    }
                                    Text(f.url.lastPathComponent)
                                        .font(.caption).foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "eye").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("标注照片（点击查看大图）") }
                }

                if summary != nil {
                    Section {
                        Button {
                            export()
                        } label: {
                            Label("保存签到结果到 Excel", systemImage: "square.and.arrow.down")
                                .font(.headline)
                        }
                    }
                }
            }
            .navigationTitle("照片签到")
            .toolbar { Button("关闭") { dismiss() } }
            .task(id: pickerItems) { process() }
            .task(id: cameraRunToken) { processCamera() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { photos in
                    cameraPhotos = photos
                    cameraRunToken += 1
                }
            }
            .sheet(item: $previewFile) { f in
                NavigationStack {
                    QuickLookPreview(url: f.url)
                        .navigationTitle(f.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("关闭") { previewFile = nil } }
                }
            }
            .sheet(item: $exportedFile) { f in
                ShareSheet(items: [f.url])
            }
        }
    }

    // MARK: - 处理流程

    private func process() {
        guard !pickerItems.isEmpty, !processing else { return }
        guard pipelineAllowed() else { return }
        processing = true
        error = nil
        annotated = []
        summary = nil
        autoSavedURL = nil
        let items = pickerItems

        Task {
            // 1. 读出照片数据与拍摄时间（EXIF）
            var photos: [(data: Data, takenAt: Date?)] = []
            for (i, item) in items.enumerated() {
                await MainActor.run { progress = "读取照片 \(i + 1)/\(items.count)…" }
                if let d = try? await item.loadTransferable(type: Data.self) {
                    photos.append((d, Self.exifDate(from: d)))
                }
            }
            await runRecognition(photos: photos)
        }
    }

    /// v6.7.15：拍照入口——连拍照片在内存（v6.7.31 起不再写系统相册，
    /// 点「开始签到」后原图由下方管线存进本场次文件夹），直接进识别
    private func processCamera() {
        guard cameraRunToken > 0, !cameraPhotos.isEmpty, !processing else { return }
        guard pipelineAllowed() else { return }
        processing = true
        error = nil
        annotated = []
        summary = nil
        autoSavedURL = nil
        let photos = cameraPhotos
        print("[照片签到-v6.7.31] 拍照签到：\(photos.count) 张连拍照片进入识别（原图将存入场次文件夹）")
        Task { await runRecognition(photos: photos) }
    }

    /// 两个入口共用的前置闸门：特征管线版本戳 + R50 运行时自检；不通过写 error
    private func pipelineAllowed() -> Bool {
        // v6.7.1：特征管线版本戳校验——对齐块方向 v6.7 起翻转，
        // 旧管线建库特征与新探针余弦≈0（实测 0.008），必然全红；
        // 与其静默误报，不如直接拦截并给出重导指引
        let stamped = UserDefaults.standard.string(forKey: "featurePipelineVersion")
        guard stamped == Thresholds.featurePipelineVersion else {
            error = stamped == nil
                ? "花名册特征为旧管线所建（未带版本戳），与当前算法不兼容，识别必然全红——请回课程页重新导入花名册后再签到"
                : "花名册特征管线(\(stamped!))与当前(\(Thresholds.featurePipelineVersion))不一致，识别必然全红——请回课程页重新导入花名册后再签到"
            print("[照片签到-v6.7.2] 特征管线不匹配：库=\(stamped ?? "无戳") 当前=\(Thresholds.featurePipelineVersion)，已拦截")
            return false
        }
        // v6.7.3：R50 运行时自检未过（设备算子输出与参考实现不符）时直接拦截——
        // 继续签到必然大面积错名，先把运行时问题暴露出来
        guard !FaceRecognizer.shared.runtimeDeviated else {
            error = "识别模型自检未通过：本机运行时输出与参考实现不符（见控制台 [R50自检-v6.7.3]），识别结果不可信，已拦截签到。请把控制台日志发回分析"
            print("[照片签到-v6.7.3] R50 运行时自检未通过，已拦截签到")
            return false
        }
        return true
    }

    /// 共用识别收尾：后台跑 recognizeAll，回主线程更新结果
    private func runRecognition(photos: [(data: Data, takenAt: Date?)]) async {
        let featured = students.filter { $0.feature != nil }
        // CPU 密集处理放到后台
        let result = await Task.detached {
            Self.recognizeAll(photos: photos, students: featured, courseName: course.name)
        }.value
        await MainActor.run {
            processing = false
            if result.facesTotal == 0 {
                error = "未在所选照片中检测到人脸"
                return
            }
            annotated = result.annotated
            photoTime = result.earliest ?? Date()
            buildRows(fusion: result.fusion)
            // v6.7.30：识别完成即自动保存 Excel 到场次文件夹（与相机扫描
            // "完成签到"的自动导出行为一致），历史考勤记录立即可见；
            // 不再依赖用户记得点"保存签到结果到 Excel"
            if let url = saveExcel() {
                autoSavedURL = url
                print("[照片签到-v6.7.31] Excel 已自动保存到场次文件夹：\(url.lastPathComponent)")
            }
        }
    }

    /// 汇总融合结果为导出行（按班级、学号排序）
    private func buildRows(fusion: [String: (score: Float, hits: Int, ambiguous: Bool)]) {
        let all = Database.shared.students(courseId: course.id)
        var confirmed = 0, uncertain = 0, absent = 0
        rows = all.map { st in
            if let e = fusion[st.studentId] {
                // 歧义结果（top1/top2 过近）不自动确认；多角度命中可覆盖歧义
                let isConfirmed = (!e.ambiguous && e.score >= Thresholds.confirmed)
                    || (e.hits >= 2 && e.score >= Thresholds.uncertain)
                let method = isConfirmed ? (e.hits >= 2 ? "多角度确认" : "自动确认") : "待确认"
                if isConfirmed { confirmed += 1 } else { uncertain += 1 }
                return (st, true, method, e.hits, e.score)
            }
            absent += 1
            return (st, false, "", 0, Float(0))
        }
        summary = (confirmed, uncertain, absent)
    }

    /// 纯写盘导出（v6.7.30 从 export 拆出）：识别收尾自动调用一次
    @discardableResult
    private func saveExcel() -> URL? {
        guard let t = photoTime else { return nil }
        do {
            return try AttendanceExporter().export(courseName: course.name,
                                                   startedAt: t, rows: rows)
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"   // self. 区分 catch 隐式 error
            return nil
        }
    }

    /// 手动按钮：分享已自动保存的 Excel；若自动保存失败过则现场重试一次
    private func export() {
        if let url = autoSavedURL ?? saveExcel() {
            exportedFile = ShareableFile(url: url)
        }
    }

    // MARK: - 静态处理逻辑（后台线程）

    struct FaceHit {
        let box: CGRect          // 正立图像像素坐标（原点左上）
        let label: String
        let level: MatchLevel
        var kps: [CGPoint] = []  // v6.7.5：五点关键点（标注图上画点核对）
    }

    struct ProcessResult {
        var fusion: [String: (score: Float, hits: Int, ambiguous: Bool)]
        var annotated: [ShareableFile]
        var earliest: Date?
        var facesTotal: Int
    }

    nonisolated static func recognizeAll(photos: [(data: Data, takenAt: Date?)],
                             students: [Student], courseName: String) -> ProcessResult {
        let gallery = students.map { $0.feature! }
        // v6.7.30：库内区分度探针——两两余弦 mean/p99/max（83 人=3403 对，
        // 512 维余弦纯 CPU 毫秒级）。健康库 ≈0.10/0.30/0.40（v6.7.4 标定）；
        // mean 明显>0.2 或 max 逼近 0.8 = 特征库本身区分度差（小照片放大
        // 建库的典型特征）——现场识别率低/误识别的根因在库，不在探针
        if gallery.count >= 2 {
            var pairs: [Float] = []
            pairs.reserveCapacity(gallery.count * (gallery.count - 1) / 2)
            for i in 0..<gallery.count {
                for j in (i + 1)..<gallery.count {
                    pairs.append(FaceRecognizer.cosine(gallery[i], gallery[j]))
                }
            }
            pairs.sort()
            let mean = pairs.reduce(0, +) / Float(pairs.count)
            let p99 = pairs[min(pairs.count - 1, Int(Float(pairs.count) * 0.99))]
            print(String(format:
                "[照片签到-v6.7.31] 库内区分度：%d人 %d对 mean=%.3f p99=%.3f max=%.3f（健康≈0.10/0.30/0.40；mean>0.2=库质量差）",
                gallery.count, pairs.count, mean, p99, pairs.last ?? 0))
        }
        var fusion: [String: (score: Float, hits: Int, ambiguous: Bool)] = [:]
        var annotated: [ShareableFile] = []
        var facesTotal = 0

        // 签到时间 = 最早一张照片的拍摄时间（无 EXIF 用当前时间）
        let sessionDate = photos.compactMap { $0.takenAt }.min() ?? Date()
        // v6.7.12：每一场签到独立文件夹（如"9月23日周三14点05分的签到"），
        // 标注图/原图/诊断图/Excel 全部收在里面，不再按日混放
        let dir = AttendanceExporter.sessionDir(courseName: courseName,
                                                date: sessionDate)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.fileStamp.string(from: sessionDate)

        for (idx, p) in photos.enumerated() {
            // 每张照片的检测/对齐/标注都在独立 autoreleasepool 内完成，
            // 防止后台线程上 autoreleased 对象堆积导致系统因内存杀进程
            autoreleasepool {
                processOne(photo: p, idx: idx, gallery: gallery, students: students,
                           fusion: &fusion, annotated: &annotated,
                           facesTotal: &facesTotal, dir: dir, stamp: stamp)
            }
        }
        return ProcessResult(fusion: fusion, annotated: annotated,
                             earliest: sessionDate, facesTotal: facesTotal)
    }

    /// 处理单张照片：检测 → 识别 → 标注 → 存盘（在 autoreleasepool 内被调用）
    nonisolated private static func processOne(
            photo p: (data: Data, takenAt: Date?), idx: Int,
            gallery: [[Float]], students: [Student],
            fusion: inout [String: (score: Float, hits: Int, ambiguous: Bool)],
            annotated: inout [ShareableFile], facesTotal: inout Int,
            dir: URL, stamp: String) {
            // v6.7.8：暂存诊断图改【移动接管】——旧实现每次照片签到都扫描
            // exports 下全部 对齐块_/SCRFD画布_ 文件挂上分享列表但不清理，
            // 跨场次无限累积（实测一次带出 82 个，旧版误检块混在新结果里
            // 误导排查）。现在扫到即【移入】本次标注目录：每张诊断图只随
            // 最近一场签到带出一回，exports 顶层不再残留
            if idx == 0 {
                FaceRecognizer.pendingDumpURLs.removeAll()   // 统一由下方目录扫描接管
                let exports = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first!
                    .appendingPathComponent("exports")
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: exports, includingPropertiesForKeys: nil) {
                    let dumps = files.filter {
                        $0.lastPathComponent.hasPrefix("对齐块_")
                            || $0.lastPathComponent.hasPrefix("SCRFD画布_")
                    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    var moved = 0
                    for f in dumps {
                        var dst = dir.appendingPathComponent(f.lastPathComponent)
                        if FileManager.default.fileExists(atPath: dst.path) {
                            let base = f.deletingPathExtension().lastPathComponent
                            dst = dir.appendingPathComponent(
                                "\(base)_\(Int(Date().timeIntervalSince1970)).png")
                        }
                        if (try? FileManager.default.moveItem(at: f, to: dst)) != nil {
                            annotated.append(ShareableFile(url: dst))
                            moved += 1
                        }
                    }
                    print("[照片签到-v6.7.31] 带出暂存诊断图 \(moved)/\(dumps.count) 个（已移入本场次文件夹，不再跨场累积）")
                }
            }
            guard let ui0 = UIImage(data: p.data),
                  let upright = normalize(ui0),
                  let cg = upright.cgImage else { return }

            // v6.7.12：原始照片在场次文件夹留底（扩展名按真实字节判定），
            // 方便与标注图逐张对比；不进分享列表，保持结果列表干净
            let origExt: String
            if p.data.count >= 2 {
                let b0 = p.data[p.data.startIndex], b1 = p.data[p.data.startIndex + 1]
                if b0 == 0xFF && b1 == 0xD8 { origExt = "jpg" }
                else if b0 == 0x89 && b1 == 0x50 { origExt = "png" }
                else { origExt = "heic" }   // iPhone 相册原图多为 HEIC
            } else { origExt = "jpg" }
            try? p.data.write(to: dir.appendingPathComponent(
                "原图_\(stamp)_\(idx + 1).\(origExt)"))

            // SCRFD 全分辨率检测（关键点精度远高于 Vision，识别准确率的关键）
            // v6.4：改走 CPU 实例（与花名册导入同一运行时）——GPU 实例在设备上
            // bbox/关键点回归值有算子级偏差（标注框整体偏向左上），CPU 数值正确
            SCRFDDetector.sharedImport.armCanvasDump(tag: "照片\(idx + 1)")
            let detT0 = Date()
            // v6.7.8：照片通路阈值 0.4→0.5，与相机一致——v6.7.7 只改了相机
            // 通路，照片侧低分误检（天花板纹理+头顶发丝这类）仍会漏进来；
            // 离线对拍（52+45 张真脸）验证 0.5 阈值零召回损失
            let detections = SCRFDDetector.sharedImport.detect(in: cg, thresh: 0.5)
            let detMs = Date().timeIntervalSince(detT0) * 1000
            facesTotal += detections.count

            // 1) 逐脸比对，得到原始匹配
            var raw: [(box: CGRect, kps: [CGPoint], sid: String?, name: String,
                       score: Float, ambiguous: Bool)] = []
            var rawNorms: [Float] = []     // v6.7.4：原始范数（运行时数值健康度探针）
            var probeDumps = 0
            var normFiltered = 0           // v6.7.7：范数闸拦截的非人脸块计数
            for (fi, det) in detections.enumerated() {
                var sid: String? = nil
                var name = ""
                var bestScore: Float = 0
                var ambiguous = false
                if let m = FaceAligner.similarityTransform(src: det.kps, dst: FaceAligner.template),
                   let pb = FaceAligner.alignedPixelBuffer(cgImage: cg, transform: m),
                   !gallery.isEmpty {
                    // v6.7.9：饱和闸（先于 R50，拦杂波的同时省嵌入算力）——
                    // v6.7.8 实测木纹墙条纹块检测分高达 0.922（比多数真脸还高）、
                    // 五点齐全、嵌入范数 21.6，检测阈值/几何校验/范数闸全部拦不住，
                    // 却能以 0.46 撞上花名册冒名确认（"墙壁识别成人脸"的元凶）。
                    // 但它的对齐块平均饱和度只有 0.076：离线实测 3 块杂波
                    // 0.076–0.145，41 张真脸（含暗光小脸）最低 0.171。
                    let sat = FaceAligner.meanSaturation(pb)
                    if sat < 0.15 {
                        normFiltered += 1
                        // v6.7.12：杂波块只存场次文件夹+日志，不进结果分享列表——
                        // 用户曾把列表里的杂波对齐块当成"识别出的人"（阴影误判疑云）
                        if normFiltered <= 3 {
                            _ = FaceAligner.dumpAlignedCrop(pb,
                                tag: String(format: "照片%d_脸%d_杂波饱和%.2f",
                                            idx + 1, fi + 1, sat),
                                into: dir)
                        }
                        print(String(format:
                            "[照片签到-v6.7.31] 照片%d 脸%d 检分=%.3f 饱和=%.3f < 0.15 → 杂波拦截（不参与比对，未跑 R50）",
                            idx + 1, fi + 1, det.score, sat))
                        continue
                    }
                    guard let r = FaceRecognizer.shared.embedWithRawNorm(pb) else {
                        raw.append((det.box, det.kps, nil, "", 0, false))
                        continue
                    }
                    // v6.7.7：范数闸——墙面/水杯/百叶窗/黑暗角落等误检块被
                    // 强制对齐成 112×112 后，嵌入范数实测只有 6–9.5（真人脸
                    // 17.4–26.6），却能在 90 人库里随机撞上 0.3–0.5 的余弦
                    // 相似度而冒出人名。范数 < 14 → 判杂波：不比对、不标注、
                    // 不计数；前 3 个存图带出，可直接看到被拦的是什么
                    if r.rawNorm < 14 {
                        normFiltered += 1
                        // v6.7.12：同上——杂波块只存场次文件夹，不进分享列表
                        if normFiltered <= 3 {
                            _ = FaceAligner.dumpAlignedCrop(pb,
                                tag: String(format: "照片%d_脸%d_杂波范数%.1f",
                                            idx + 1, fi + 1, r.rawNorm),
                                into: dir)
                        }
                        print(String(format:
                            "[照片签到-v6.7.31] 照片%d 脸%d 检分=%.3f 饱和=%.2f 范数=%.1f < 14 → 杂波拦截（不参与比对）",
                            idx + 1, fi + 1, det.score, sat, r.rawNorm))
                        continue
                    }
                    rawNorms.append(r.rawNorm)
                    var scored: [(Int, Float)] = []
                    for (i, g) in gallery.enumerated() {
                        scored.append((i, FaceRecognizer.cosine(r.vec, g)))
                    }
                    scored.sort { $0.1 > $1.1 }
                    if let top = scored.first {
                        let gap: Float = scored.count >= 2 ? scored[0].1 - scored[1].1 : 1
                        // v6.7.4：前 8 张脸的对齐块存盘进分享列表——文件名带设备判定，
                        // 拿到图即可目视核对"模型看到的脸"与"设备说是谁"是否一致
                        if probeDumps < 8,
                           let url = FaceAligner.dumpAlignedCrop(pb,
                               tag: String(format: "照片%d_脸%d_设备判定%@_%.2f",
                                           idx + 1, fi + 1, students[top.0].name, top.1),
                               into: dir) {   // v6.7.8：直接落本场标注目录，不再中转
                            annotated.append(ShareableFile(url: url))
                            probeDumps += 1
                        }
                        if fi < 12 {
                            print(String(format:
                                "[照片签到-v6.7.31] 照片%d 脸%d 检分=%.3f 饱和=%.2f 原始范数=%.1f top1=%@ %.3f top2=%@ %.3f gap=%.3f",
                                idx + 1, fi + 1, det.score, sat, r.rawNorm,
                                students[top.0].name, top.1,
                                scored.count >= 2 ? students[scored[1].0].name : "-",
                                scored.count >= 2 ? scored[1].1 : 0, gap))
                            // v6.7.5：kps 数值对拍——与离线参考逐点核对，
                            // 区分“kps 数值坏”与“warp 渲染坏”
                            let kpStr = det.kps.map {
                                String(format: "(%.1f,%.1f)", $0.x, $0.y)
                            }.joined(separator: "|")
                            print(String(format:
                                "[照片签到-v6.7.31] 照片%d 脸%d 框=(%.0f,%.0f %.0fx%.0f) kps=%@",
                                idx + 1, fi + 1, det.box.minX, det.box.minY,
                                det.box.width, det.box.height, kpStr))
                        }
                        if top.1 >= Thresholds.uncertain {
                            sid = students[top.0].studentId
                            name = students[top.0].name
                            bestScore = top.1
                            // top1/top2 差距过小 → 歧义，不得自动确认
                            ambiguous = scored.count >= 2 && gap < 0.05
                        }
                    }
                }
                raw.append((det.box, det.kps, sid, name, bestScore, ambiguous))
            }

            // 2) 同一照片内同一学生只保留最高分的人脸（两人同名仲裁）
            var bestBySid: [String: Int] = [:]
            for (i, r) in raw.enumerated() {
                guard let s = r.sid else { continue }
                if let j = bestBySid[s] {
                    if r.score > raw[j].score { bestBySid[s] = i }
                } else {
                    bestBySid[s] = i
                }
            }

            // v6.7.4：每张照片一行摘要——新增原始范数中位（参考≈20.6）与
            // 非歧义 ≥0.40 脸数（健康管线约 17/31，塌陷管线≈0）
            let matched = raw.filter { $0.sid != nil }
            rawNorms.sort()
            let medNorm: Float = rawNorms.isEmpty ? 0 : rawNorms[rawNorms.count / 2]
            let confCnt = raw.filter { !$0.ambiguous && $0.score >= Thresholds.confirmed }.count
            print(String(format:
                "[照片签到-v6.7.31] 照片%d：检测%d脸 识别%d人(≥0.30) 非歧义≥0.40共%d脸 最高相似度=%.3f 原始范数中位=%.1f（参考≈20.6）杂波拦截%d(饱和+范数) 检测耗时=%.0fms\n    检测状态：%@",
                idx + 1, detections.count, matched.count, confCnt,
                matched.map { $0.score }.max() ?? 0, medNorm, normFiltered, detMs,
                SCRFDDetector.sharedImport.debugStatus))

            // 3) 生成标注与融合
            var hits: [FaceHit] = []
            for (i, r) in raw.enumerated() {
                var label = "未识别"
                var level = MatchLevel.unknown
                if let sid = r.sid, bestBySid[sid] == i {
                    label = r.name
                    level = (!r.ambiguous && r.score >= Thresholds.confirmed) ? .confirmed : .uncertain
                    var e = fusion[sid] ?? (score: 0, hits: 0, ambiguous: false)
                    if r.score > e.score { e.score = r.score; e.ambiguous = r.ambiguous }
                    e.hits += 1
                    fusion[sid] = e
                }
                hits.append(FaceHit(box: r.box, label: label, level: level, kps: r.kps))
            }

            // 4) 保存标注图到日期子文件夹
            if let marked = annotate(cg: cg, hits: hits),
               let jpg = marked.jpegData(compressionQuality: 0.9) {
                let url = dir.appendingPathComponent("标注_\(stamp)_\(idx + 1).jpg")
                if (try? jpg.write(to: url)) != nil {
                    annotated.append(ShareableFile(url: url))
                }
            }

            // 5) v6.6 诊断：把本次检测的画布转储一并加入列表（所见即模型所得，
            //    在结果列表里直接点开预览/分享，无需文件共享权限）。
            //    v6.7.12：立即移入本场次文件夹，不再留在 exports 顶层等下一场顺走
            let dumpURL = FileManager.default.urls(for: .documentDirectory,
                                                   in: .userDomainMask).first!
                .appendingPathComponent("exports")
                .appendingPathComponent("SCRFD画布_照片\(idx + 1).png")
            if FileManager.default.fileExists(atPath: dumpURL.path) {
                var dst = dir.appendingPathComponent(dumpURL.lastPathComponent)
                if FileManager.default.fileExists(atPath: dst.path) {
                    dst = dir.appendingPathComponent(
                        "SCRFD画布_照片\(idx + 1)_\(Int(Date().timeIntervalSince1970)).png")
                }
                if (try? FileManager.default.moveItem(at: dumpURL, to: dst)) != nil {
                    annotated.append(ShareableFile(url: dst))
                }
            }
    }

    /// 把 UIImage 转正为正立 CGImage（按 EXIF 方向）
    nonisolated static func normalize(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 保持原像素尺寸
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// 在照片上绘制人脸框与姓名标签（UIKit 文本绘制，中文无乱码）
    nonisolated static func annotate(cg: CGImage, hits: [FaceHit]) -> UIImage? {
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let lineWidth = max(4, size.width / 300)
        // v6.7.30：标注字号减一档（/45 → /52，3000px 宽照片约 67pt → 58pt）
        let fontSize = max(14, size.width / 52)
        return renderer.image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            for h in hits {
                let rect = h.box   // 已是正立图像像素坐标（原点左上）
                let color: UIColor
                switch h.level {
                case .confirmed: color = .systemGreen
                case .uncertain: color = .systemOrange
                case .unknown:   color = .systemRed
                }
                color.setStroke()
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                path.lineWidth = lineWidth
                path.stroke()
                // 标签背景 + 文字（框上方，越界时放框内）
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: fontSize),
                    .foregroundColor: UIColor.white,
                ]
                let textSize = (h.label as NSString).size(withAttributes: attrs)
                let labelW = textSize.width + 16, labelH = textSize.height + 8
                let labelY = rect.minY - labelH - 4 > 0 ? rect.minY - labelH - 4 : rect.minY + 4
                let labelRect = CGRect(x: max(0, rect.minX), y: labelY,
                                       width: labelW, height: labelH)
                color.withAlphaComponent(0.9).setFill()
                UIBezierPath(roundedRect: labelRect, cornerRadius: 4).fill()
                (h.label as NSString).draw(at: CGPoint(x: labelRect.minX + 8,
                                                       y: labelRect.minY + 4),
                                           withAttributes: attrs)
                // v6.7.5：五点关键点画青色圆点——点应落在双眼/鼻尖/嘴角上，
                // 点飞了即 kps 数值坏，点准但识别错即 warp/模型侧问题
                if h.kps.count == 5 {
                    UIColor.systemCyan.setFill()
                    let r = max(3, lineWidth)
                    for p in h.kps {
                        UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r,
                                                    width: 2 * r, height: 2 * r)).fill()
                    }
                }
            }
        }
    }

    /// 从 JPEG/HEIC 数据中读取 EXIF 拍摄时间
    nonisolated static func exifDate(from data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return df.date(from: s)
    }

    nonisolated static func exportsDir(courseName: String) -> URL {
        let safe = courseName.components(separatedBy:
            CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("exports").appendingPathComponent(safe)
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        return df
    }()
    static let dayStamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}
