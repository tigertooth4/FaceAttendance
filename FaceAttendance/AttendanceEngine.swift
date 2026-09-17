import AVFoundation
import CoreImage
import Combine
import UIKit

/// 扫描签到引擎：相机视频流（4K）→ SCRFD 检测（关键点）→ 跟踪 → ResNet50 识别 → 多帧融合。
/// 检测始终在"转正后"的画面坐标系进行，因此横竖屏切换时框与预览天然对齐。
final class AttendanceEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: 对外状态（UI 绑定）
    @Published var overlays: [FaceOverlay] = []          // 当前画面的人脸标签
    @Published var confirmedCount = 0                    // 已确认人数（绿）
    @Published var uncertainCount = 0                    // 待确认（橙）
    @Published var unknownFaces = 0                      // v6.7.8 起：花名册未签到人数（考勤语义）
    @Published var startedAt: Date?
    @Published var isRunning = false
    @Published var error: String?
    /// 转正后的画面尺寸（像素，供预览层做坐标换算），主线程读写
    @Published var orientedImageSize: CGSize = .zero
    /// v6.7.6：方向自校准是否已锁定。未锁定时不发布人脸框（教科书映射在本设备
    /// 与检测画布相差 180°，未锁定期间画框必错位，宁可短暂无框）。
    /// v6.7.3 的 calibratedPreviewAngle 已废除：把检测校准角套到预览层是
    /// v6.7.3–v6.7.5 相机框错位的直接原因——预览的 videoRotationAngle 与检测画布的
    /// 转正常量是两套语义（设备实测：画布需 .left/270° 人脸才正立，而预览 90° 一直
    /// 显示正常），混用会把预览转反、框随之整体错位。预览永远只跟界面方向。
    @Published private(set) var orientationLocked = false

    let session = AVCaptureSession()

    private var course: Course!
    private var allStudents: [Student] = []              // 全部学生（含无特征者，用于标签显示）
    private var students: [Student] = []                 // 有特征的学生（参与比对）
    private var gallery: [[Float]] = []

    nonisolated private let tracker = FaceTracker()
    nonisolated(unsafe) private var frameIndex = 0
    private let videoQueue = DispatchQueue(label: "video")
    nonisolated private let recogQueue = DispatchQueue(label: "recog")   // 串行，保护模型
    nonisolated(unsafe) private var pendingRequest = false                     // 有未完成的检测

    // v6.7.9：识别改为"同帧进行"——检测完成的当帧直接从本轮检出中选目标、
    // 用同一个 pixelBuffer 生成正立图送识别，彻底废除旧的跨帧交接
    // （主线程选目标→下一处理帧才捕获图像并按位置找回人脸）。旧设计有
    // 1–2 秒交接延迟，扫视中目标框必然过期、按位置匹配每轮静默落空：
    // v6.7.8 日志实锤锁定后 18 轮检测仅 1 次识别成功。targetLock 保护
    // recognitionInFlight 与 recogSnapshot（视频线程与主线程都读写）。
    nonisolated(unsafe) private var recognitionInFlight = false
    nonisolated private let targetLock = NSLock()
    /// 识别资格快照（主线程在 publishOverlays 里从 results 复制，视频线程只读）
    nonisolated(unsafe) private var recogSnapshot:
        [Int: (junk: Bool, score: Float, attempts: Int, frameRecognized: Int)] = [:]
    // 每跟踪目标的识别结果
    private struct TrackResult {
        var studentId: String?
        var score: Float = 0
        var candidates: [(student: Student, score: Float)] = []
        var frameRecognized: Int = -1
        var attempts: Int = 0          // 已识别次数（低分目标会重试）
        var ambiguous = false          // top1/top2 差距过小，禁止自动确认
        var junk = false               // v6.7.7：范数闸连续判定为非人脸（墙/桌面/黑暗
                                       // 纹理误检），不再选为识别目标、不发布框
        // v6.7.16：多帧嵌入平均（EMA）——手扫单帧噪声大（运动模糊/侧视角/小脸
        // kps 抖动），同轨道嵌入指数滑动平均后再比对可降噪。只存 EMA 向量和
        // 帧数，归属判定取 单帧成绩 与 平均成绩 的高者（见 applyRecognition）
        var embEMA: [Float] = []
        var embFrames: Int = 0
    }
    private var results: [Int: TrackResult] = [:]

    // MARK: - v6.7.16 GPU 检测通路 + CPU 影子对拍
    // v6.4 因 GPU 算子级偏差（框飘出人脸）全场景退回 CPU（BNNS fp32），
    // 代价是 1920² 张量单次 ~0.5s、全场每秒仅约 2 次采样——"帧少且烂"的
    // 吞吐侧根因。本版重议 GPU（Metal）：主跑 SCRFDDetector.shared（cpuAndGPU），
    // 并定期用 CPU 实例同帧重算比对（影子对拍，同步执行保证严格同帧）：
    // 连续 3 次通过 → validated（之后每 300 帧抽查）；任何一次召回 <0.7 或
    // 关键点相对偏差 >0.10 → rejected，永久回退 CPU。正确性不再靠赌。
    private enum GPUVerdict { case pending, validated, rejected }
    nonisolated(unsafe) private var gpuVerdict: GPUVerdict = .pending
    nonisolated(unsafe) private var gpuShadowChecks = 0        // 已通过的对拍次数
    nonisolated(unsafe) private var nextShadowFrame = 0        // 下一次对拍帧号（0=尽快首拍）

    // 场次级融合：学号 → (最高分, 命中次数, 人工确认, 存在歧义)
    private(set) var studentBest: [String: (score: Float, hits: Int, manual: Bool, ambiguous: Bool)] = [:]
    private var manualAssigned: [Int: String] = [:]      // trackId → 人工指定的学号

    // MARK: - 配置

    func configure(course: Course, students: [Student]) {
        self.course = course
        self.allStudents = students
        self.students = students.filter { $0.feature != nil }
        self.gallery = self.students.map { $0.feature! }
    }

    // MARK: - 相机

    func start() {
        if let err = FaceRecognizer.shared.loadError { error = err; return }
        if let err = SCRFDDetector.sharedImport.loadError { error = err; return }
        // v6.7.6：不再在 start 时武装画布转储（首帧必是热身暗帧，存了也是黑的）；
        // 改为方向校准锁定的那一刻武装（见 calibrateOrientation），
        // 存下"模型真正看到的、已转正的画布"供核对镜像/方向
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.start() } else { self?.error = "请先在系统设置中允许使用相机" }
                }
            }
            return
        }
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            // 4K：后排小脸保留更多像素，SCRFD 关键点更准（iPhone 13 Pro 无压力）
            if self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            } else {
                self.session.sessionPreset = .hd1920x1080
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                DispatchQueue.main.async { self.error = "无法打开相机" }
                return
            }
            self.session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(output) { self.session.addOutput(output) }
            // 注意：不要在数据输出连接上设置旋转（videoRotationAngle/videoOrientation）——
            // iOS 17+ 会物理旋转像素缓冲。保持缓冲为传感器原生方向，
            // 检测在转正后的画面进行，坐标系与预览层始终一致。
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async {
                self.startedAt = Date()
                self.isRunning = true
            }
        }
    }

    func stop() {
        videoQueue.async { [weak self] in self?.session.stopRunning() }
        DispatchQueue.main.async { self.isRunning = false }
    }

    /// 当前设备方向对应的缓冲转正角度（0/90/180/270），主线程写入、视频线程读取
    nonisolated(unsafe) private var currentRotationAngle: CGFloat = 90

    /// 界面方向变化时调用（主线程）。angle 与预览层连接使用同一映射，保证框永远对齐。
    func setOrientationAngle(_ angle: CGFloat) {
        // v6.7.2：方向角变化时打一条日志，与方向自检行对照可一锤定音
        if angle != currentRotationAngle {
            print("[相机-v6.7.24] 方向角 \(Int(currentRotationAngle)) → \(Int(angle))（90=竖屏 0/180=横屏 270=倒竖屏）")
            currentRotationAngle = angle
            // v6.7.3：方向角变了，旧锁定作废，下一处理帧立即重新校准
            lockedOrientation = nil
            nextCalibFrame = 0
            orientationLocked = false
        }
    }

    // MARK: - v6.7.3 相机方向自校准

    /// 教科书映射：缓冲转正角度 → EXIF 方向（与预览层 videoRotationAngle 同一映射）
    nonisolated static func orientation(for angle: CGFloat) -> CGImagePropertyOrientation {
        angle == 0 ? .up : angle == 180 ? .down : angle == 270 ? .left : .right
    }

    /// 自校准锁定的转正方向（lockedAngle = 锁定时的缓冲转正角；方向角一变即作废）
    nonisolated(unsafe) private var lockedOrientation: CGImagePropertyOrientation?
    nonisolated(unsafe) private var lockedAngle: CGFloat = -1
    /// 下一次允许校准的处理帧号。v6.7.6：首校从第 12 帧起——开机前若干帧是
    /// 黑/暗热身帧，v6.7.5 首帧即校准必得 0/0/0/0，白白浪费一次并推迟锁定
    nonisolated(unsafe) private var nextCalibFrame = 12
    /// v6.7.6：连续同向胜出计数（小脸稀疏场景下放宽 ≥8 脸的硬门槛）
    nonisolated(unsafe) private var calibWinDeg = -1
    nonisolated(unsafe) private var calibWinStreak = 0

    /// 同一帧连测四个方向，让模型投票选出真正的转正方向（视频队列执行）。
    /// 依据（离线实锤）：SCRFD 对正立人脸召回极高、对旋转/颠倒人脸召回崩塌
    /// （同一教室画面 159 vs 17 候选），四个方向的检出数差距是数量级的。
    /// 胜出条件：①≥8 张脸 且 ≥ 第二名的 2 倍（立即锁定）；
    /// ②同一方向连续 3 次严格胜出且 ≥2 脸（稀疏场景放宽，v6.7.6）。
    /// 锁定后只影响【检测画布/识别对齐图】的方向，绝不动预览层
    /// （v6.7.6 废除 calibratedPreviewAngle，见 orientationLocked 注释）。
    nonisolated private func calibrateOrientation(
        pixelBuffer: CVPixelBuffer, angle: CGFloat, frame: Int
    ) -> CGImagePropertyOrientation {
        let textbook = Self.orientation(for: angle)
        let dirs: [(o: CGImagePropertyOrientation, deg: Int)] =
            [(.up, 0), (.right, 90), (.down, 180), (.left, 270)]
        var counts: [(o: CGImagePropertyOrientation, deg: Int, n: Int)] = []
        for d in dirs {
            let faces = SCRFDDetector.sharedImport.detect(pixelBuffer: pixelBuffer,
                                                          orientation: d.o)
            counts.append((d.o, d.deg, faces.filter { $0.score >= 0.5 }.count))
        }
        let summary = counts.map { "\($0.deg)°=\($0.n)脸" }.joined(separator: " ")
        let sorted = counts.sorted { $0.n > $1.n }
        let best = sorted[0], second = sorted[1]
        // 连续同向胜出统计（全 0 平局不计）
        if best.n >= 2, best.n > second.n {
            if best.deg == calibWinDeg { calibWinStreak += 1 }
            else { calibWinDeg = best.deg; calibWinStreak = 1 }
        } else {
            calibWinDeg = -1; calibWinStreak = 0
        }
        let decisive = best.n >= 8 && best.n >= max(1, second.n) * 2
        if decisive || calibWinStreak >= 3 {
            lockedOrientation = best.o
            lockedAngle = angle
            let verdict = best.o == textbook
                ? "与教科书映射一致"
                : "⚠️与教科书映射不一致，以实测为准（本设备常态：画布与预览是两套转正常量）"
            print("[相机-v6.7.24] 方向校准：\(summary) → 锁定 \(best.deg)°（\(verdict)）")
            // 锁定帧的画布转储：把"模型实际看到的画面"带回来核对（随照片签到分享带出）
            SCRFDDetector.sharedImport.armCanvasDump(tag: "相机_锁定\(best.deg)度")
            DispatchQueue.main.async { self.orientationLocked = true }
            return best.o
        }
        // v6.7.6：全 0 多为热身帧/还没对准教室——45 帧（~3 秒）后就重试，
        // 不再等 150 帧（v6.7.5 整场扫描都困在未锁定→教科书映射→画布颠倒→框错位）
        let backoff = best.n == 0 ? 45 : 30
        nextCalibFrame = frame + backoff
        print("[相机-v6.7.24] 方向校准未定：\(summary)（连胜=\(calibWinStreak)）"
            + "→ 暂不发布人脸框，\(backoff)帧后重试")
        return textbook
    }

    /// 把相机缓冲（传感器原生横屏）转成正立的全分辨率 CGImage 副本（识别对齐用）
    /// v6.5：改用检测器里的 Quartz 旋转实现，不经 CoreImage 仿射
    /// v6.7.3：按【转正方向】而非界面角度——与检测画布共用自校准锁定的方向
    nonisolated private static func uprightCGImage(
        from pb: CVPixelBuffer, orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        SCRFDDetector.uprightCGImage(from: pb, orientation: orientation)
    }

    // MARK: - v6.7.16 CI 区域直出（裁剪路径）

    /// 裁剪直出状态：0 未校验 1 校验通过（只用裁剪）2 回退全帧。
    /// recogQueue 写、视频队列读；首场首个识别任务自动对拍定夺。
    nonisolated(unsafe) private static var cropPathState = 0

    /// 复用的 CIContext（Metal）——同参数反复创建有显著开销
    nonisolated private static let ciCtx = CIContext()

    /// 只把需要的区域从原始缓冲裁出并转正，不再渲染整张 4K 正立图
    /// （旧路径 50~100ms/轮 → 新路径 <5ms/块）。
    /// rect 为正立原图坐标（原点左上，与检测框同系）；内部注意 CIImage
    /// 坐标原点在左下，Y 轴需翻转。正确性由首场对拍背书（recogQueue 内
    /// 与全帧路径比特征余弦 ≥0.98），不依赖人工推证。
    nonisolated private static func uprightCrop(
        from pb: CVPixelBuffer, orientation: CGImagePropertyOrientation,
        rect: CGRect
    ) -> CGImage? {
        let img = CIImage(cvPixelBuffer: pb).oriented(orientation)
        let H = img.extent.height
        let r = rect.intersection(CGRect(x: 0, y: 0, width: img.extent.width, height: H))
        guard r.width >= 16, r.height >= 16 else { return nil }
        let ci = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
        let moved = img.cropped(to: ci).transformed(
            by: CGAffineTransform(translationX: -ci.minX, y: -ci.minY))
        return ciCtx.createCGImage(moved, from: CGRect(x: 0, y: 0,
                                                       width: ci.width, height: ci.height))
    }

    // MARK: - v6.7.16 CPU 影子对拍

    /// GPU 检出 vs 同帧 CPU 检出：召回率 + 匹配对的关键点相对偏差。
    /// 通过 → 计数（3 次后 validated，转低频抽查）；失败 → rejected 永久回退 CPU。
    /// 在视频队列同步执行（严格同帧；每次 +~0.5s，对拍期间丢 1~2 帧可接受）
    nonisolated private func shadowEvaluate(
        gpu: [SCRFDDetector.Face], cpu: [SCRFDDetector.Face],
        frame: Int, cpuMs: Double, gpuMs: Double
    ) {
        let g = gpu.filter { $0.score >= 0.5 }, c = cpu.filter { $0.score >= 0.5 }
        var matched = 0
        var rels: [CGFloat] = []
        for cf in c {
            var bestIoU: CGFloat = 0
            var bestF: SCRFDDetector.Face?
            for gf in g {
                let v = iou(cf.box, gf.box)
                if v > bestIoU { bestIoU = v; bestF = gf }
            }
            if let bf = bestF, bestIoU >= 0.5 {
                matched += 1
                let d = zip(cf.kps, bf.kps).map {
                    hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y)
                }.reduce(0, +) / 5
                rels.append(d / max(1, cf.box.width))
            }
        }
        let recall = c.isEmpty ? 1 : CGFloat(matched) / CGFloat(c.count)
        let medKps = rels.isEmpty ? 0 : rels.sorted()[rels.count / 2]
        let pass = recall >= 0.7 && medKps <= 0.10
        if pass {
            gpuShadowChecks += 1
            nextShadowFrame = frame + (gpuShadowChecks < 3 ? 20 : 300)
            if gpuShadowChecks == 3 { gpuVerdict = .validated }
            print(String(format:
                "[相机-v6.7.24] 影子对拍#%d 通过：GPU %.0fms vs CPU %.0fms，召回 %.2f（%d/%d）关键点相对偏差 %.3f%@",
                gpuShadowChecks, gpuMs, cpuMs, recall, matched, c.count, medKps,
                gpuShadowChecks == 3 ? " → GPU 通路转正，此后每300帧抽查" : ""))
        } else {
            gpuVerdict = .rejected
            print(String(format:
                "[相机-v6.7.24] 影子对拍失败：召回 %.2f（%d/%d）关键点相对偏差 %.3f → GPU 数值不可信，永久回退 CPU 检测",
                recall, matched, c.count, medKps))
        }
    }

    /// 数码变焦（双指捏合）
    func setZoom(_ factor: CGFloat) {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        try? device.lockForConfiguration()
        device.videoZoomFactor = max(1, min(factor, device.activeFormat.videoMaxZoomFactor))
        device.unlockForConfiguration()
    }

    // MARK: - 帧处理

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameIndex += 1
        // 检测限频：每 2 帧一次（约 15 次/秒）；有未完成的检测则丢帧
        guard frameIndex % 2 == 0, !pendingRequest,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pendingRequest = true
        let frame = frameIndex

        // v6.7.3：转正方向不再靠教科书映射猜——由自校准锁定（见 calibrateOrientation）
        let angle = currentRotationAngle
        let textbook = Self.orientation(for: angle)
        var visionOrientation = (lockedAngle == angle ? lockedOrientation : nil) ?? textbook
        // 未锁定或方向角已变：到点重试校准（首帧立即；未定时间隔由 calibrateOrientation 定）
        if (lockedOrientation == nil || lockedAngle != angle), frame >= nextCalibFrame {
            visionOrientation = calibrateOrientation(pixelBuffer: pixelBuffer,
                                                     angle: angle, frame: frame)
        }
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let swapped = (visionOrientation == .right || visionOrientation == .left)
        let orientedSize = swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        // SCRFD 检测（手工 letterbox + 直接推理，视频队列同步执行，已被 pendingRequest 限频）
        // v6.7.16：重议 GPU——主走 shared（cpuAndGPU，Metal），CPU 影子对拍兜底；
        // rejected 后永久回退 sharedImport（CPU）。方向校准期间（未锁定）始终用
        // CPU——四方向投票基数小，不引入第二个变量（见 calibrateOrientation）
        let useGPU = gpuVerdict != .rejected && lockedOrientation != nil && lockedAngle == angle
        let detT0 = Date()
        let faces = useGPU
            ? SCRFDDetector.shared.detect(pixelBuffer: pixelBuffer,
                                          orientation: visionOrientation)
            : SCRFDDetector.sharedImport.detect(pixelBuffer: pixelBuffer,
                                                orientation: visionOrientation)
        let detMs = Date().timeIntervalSince(detT0) * 1000
        pendingRequest = false
        // CPU 影子对拍：GPU 主跑期间同帧 CPU 重算比对（同步执行保证严格同帧；
        // 每次多花 ~0.5s，验证期每 20 帧一次，validated 后每 300 帧抽查）
        if useGPU, frame >= nextShadowFrame {
            let shT0 = Date()
            let cpuFaces = SCRFDDetector.sharedImport.detect(pixelBuffer: pixelBuffer,
                                                             orientation: visionOrientation)
            shadowEvaluate(gpu: faces, cpu: cpuFaces, frame: frame,
                           cpuMs: Date().timeIntervalSince(shT0) * 1000, gpuMs: detMs)
        }
        if frame % 90 == 0 {   // 每 ~3 秒打一条，不刷屏
            let orientSrc = (lockedOrientation != nil && lockedAngle == angle)
                ? "自校准锁定" : "教科书映射（未锁定，框已暂缓发布）"
            print(String(format: "[相机-v6.7.24] %@检测耗时=%.0fms 检出%d脸 方向=%@",
                         useGPU ? "GPU" : "CPU", detMs, faces.count, orientSrc))
        }

        let tracks = tracker.update(detections: faces.map(\.box), frameIndex: frame)

        // v6.7.9 同帧识别：方向已锁定且识别空闲时，从【本轮检出】中直接选
        // 最大合格脸，用【同一个 pixelBuffer】生成正立图送识别——目标框与
        // 图像严格同帧，扫视再快也不存在框过期问题。资格判定走 recogSnapshot
        // （results 的主线程快照），不跨线程读 results。
        // v6.7.10：正立图每轮只生成一次，同时用于①各轨道框区饱和度测量
        // （显示闸+选择过滤）②识别对齐裁剪。
        if lockedOrientation != nil, lockedAngle == angle {
            // 识别目标选择（识别空闲时）
            targetLock.lock()
            let busy = recognitionInFlight
            let snap = recogSnapshot
            targetLock.unlock()
            if !busy {
                // v6.7.16：每轮最多 2 个识别目标。GPU 提速后检测轮加密，
                // 识别名额不再稀缺——尺寸闸 60→48，给后排小脸更多机会，
                // 由多帧 EMA 平均（applyRecognition）去噪兜底。
                // v6.7.16：不再渲染整张 4K 正立图测全脸饱和——只对初筛合格的
                // 候选脸（面积前 4）逐脸 CI 裁小图测量（<5ms/块），
                // 顺带废除了 busy 期间白渲染整帧的旧浪费（v6.7.10 遗留）
                var picks: [(face: SCRFDDetector.Face, tid: Int)] = []
                var nJunk = 0, nDone = 0, nCool = 0
                for f in faces where f.box.height >= 48 {
                    // 检出脸 → 同轮轨道（IoU 最大者；同帧数据必中高重叠）
                    guard let tr = tracks.max(by: { iou($0.box, f.box) < iou($1.box, f.box) }),
                          iou(tr.box, f.box) >= 0.3 else { continue }
                    if let s = snap[tr.id] {
                        if s.junk { nJunk += 1; continue }
                        if s.frameRecognized >= 0 {
                            if s.score >= Thresholds.confirmed || s.attempts >= 6 {
                                nDone += 1; continue
                            }
                            guard frame - s.frameRecognized >= 6 else { nCool += 1; continue }
                        }
                    }
                    picks.append((f, tr.id))
                }
                // 面积降序、同轨道去重后取前 4 候选（测饱和），再取前 2 派任务
                picks.sort {
                    $0.face.box.width * $0.face.box.height
                        > $1.face.box.width * $1.face.box.height
                }
                var seenTid = Set<Int>()
                let cand4 = picks.filter { seenTid.insert($0.tid).inserted }.prefix(4)
                var chosen: [(face: SCRFDDetector.Face, tid: Int, sat: Float)] = []
                var nLowSat = 0
                for (f, tid) in cand4 {
                    // 低饱和误检（墙/桌椅/天花板）跳过——v6.7.10 实测这类块占
                    // 检出大半且框往往最大，"最大脸优先"会让它们反复抢占识别槽
                    guard let satCrop = Self.uprightCrop(from: pixelBuffer,
                                                         orientation: visionOrientation,
                                                         rect: f.box) else { continue }
                    let sat = FaceAligner.meanSaturation(
                        cgImage: satCrop,
                        rect: CGRect(x: 0, y: 0, width: satCrop.width, height: satCrop.height))
                    if sat < 0.15 { nLowSat += 1; continue }
                    chosen.append((f, tid, sat))
                    if chosen.count == 2 { break }
                }
                if !chosen.isEmpty {
                    targetLock.lock()
                    recognitionInFlight = true
                    targetLock.unlock()
                    for (f, tid, boxSat) in chosen {
                        print(String(format:
                            "[相机-v6.7.24] 识别目标→track%d 框=(%.0f,%.0f %.0fx%.0f) 检分=%.2f 框饱和=%.2f",
                            tid, f.box.minX, f.box.minY, f.box.width, f.box.height,
                            f.score, boxSat))
                    }
                    // v6.7.16：识别用图在视频队列内同步生成（CGImage 自持，无缓冲
                    // 回收风险），不再把 pixelBuffer 带上 recogQueue。
                    // 裁剪路径 <5ms/块；状态 0（待对拍）/2（回退）时渲染全帧 ~100ms。
                    let orientation = visionOrientation
                    let cgFull = Self.cropPathState != 1
                        ? Self.uprightCGImage(from: pixelBuffer, orientation: orientation)
                        : nil
                    var jobs: [(tid: Int, img: CGImage?, kps: [CGPoint])] = []
                    for (f, tid, _) in chosen {
                        if Self.cropPathState == 2 {
                            jobs.append((tid, cgFull, f.kps))
                            continue
                        }
                        // 外扩 0.6×：对齐 warp 的采样半径约 1.9×脸宽
                        let pad = f.box.width * 0.6
                        let rect = f.box.insetBy(dx: -pad, dy: -pad)
                        if let crop = Self.uprightCrop(from: pixelBuffer,
                                                       orientation: orientation, rect: rect) {
                            jobs.append((tid, crop,
                                f.kps.map { CGPoint(x: $0.x - rect.minX,
                                                    y: $0.y - rect.minY) }))
                        } else {
                            jobs.append((tid, cgFull, f.kps))   // 贴边裁不出 → 全帧兜底
                        }
                    }
                    recogQueue.async { [weak self] in
                        guard let self else { return }
                        // recogQueue 串行执行，两次嵌入约 0.6s
                        var outs: [(tid: Int, feat: (vec: [Float], norm: Float)?)] = []
                        for (j, job) in jobs.enumerated() {
                            var feat = job.img.flatMap {
                                Self.recognize(cgImage: $0, kps: job.kps)
                            }
                            // 首场首任务：旧全帧 vs 新裁剪 特征对拍（一次性）——
                            // 余弦 ≥0.98 才启用裁剪路径，否则本场永久全帧
                            if j == 0, Self.cropPathState == 0,
                               let full = cgFull, let first = chosen.first {
                                if let viaFull = Self.recognize(cgImage: full,
                                                                kps: first.face.kps),
                                   let viaCrop = feat {
                                    let cos = FaceRecognizer.cosine(viaFull.vec, viaCrop.vec)
                                    Self.cropPathState = cos >= 0.98 ? 1 : 2
                                    print(String(format:
                                        "[相机-v6.7.24] 裁剪直出对拍：全帧 vs 裁剪 特征余弦=%.4f → %@",
                                        cos, Self.cropPathState == 1
                                            ? "启用裁剪路径（此后每轮省 ~100ms）"
                                            : "回退全帧路径（正确性优先）"))
                                    feat = viaFull   // 校验轮采用旧路径结果（语义最保守）
                                } else {
                                    Self.cropPathState = 2
                                    print("[相机-v6.7.24] 裁剪直出对拍无法完成（旧路径嵌入失败）→ 回退全帧路径")
                                }
                            }
                            outs.append((job.tid, feat))
                        }
                        DispatchQueue.main.async {
                            for (tid, feat) in outs {
                                if let feat {
                                    self.applyRecognition(trackId: tid, feature: feat.vec,
                                                          frame: frame)
                                } else {
                                    // 对齐失败/饱和闸/范数闸拦截也计一次尝试。
                                    // v6.7.10：只有"从未成功嵌入"的轨道才判杂波——
                                    // 成功嵌入过的都是真脸（哪怕分数低），模糊帧
                                    // 偶发低范数不该把人永久误杀（v6.7.9 实测
                                    // track40 真脸第二轮遇模糊帧范数 11.3 被误判）
                                    var r = self.results[tid] ?? TrackResult()
                                    r.attempts += 1
                                    if r.attempts >= 2, r.frameRecognized < 0 {
                                        r.junk = true
                                        print(String(format:
                                            "[相机-v6.7.24] track%d 判杂波（连续2次嵌入失败）——不再识别也不再显示",
                                            tid))
                                    }
                                    self.results[tid] = r
                                }
                            }
                            self.targetLock.lock()
                            self.recognitionInFlight = false
                            self.targetLock.unlock()
                            self.publishOverlays(tracks: self.tracker.tracks)
                        }
                    }
                } else if frame % 60 == 0 {
                    // 看门狗：没有可选目标时给出原因拆解，定位识别停滞
                    let nSmall = faces.filter { $0.box.height < 48 }.count
                    print(String(format:
                        "[相机-v6.7.24] 识别待机：本轮%d脸 合格0（杂波%d/已确认或试满%d/冷却%d/低饱和%d/太小%d）",
                        faces.count, nJunk, nDone, nCool, nLowSat, nSmall))
                }
            } else if frame % 150 == 0 {
                // 看门狗：识别占用长期不释放意味着回调链断裂
                print(String(format:
                    "[相机-v6.7.24] 识别看门狗：inFlight 持续占用（帧%d）——若反复出现说明识别回调丢失",
                    frame))
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.orientedImageSize = orientedSize
            self.publishOverlays(tracks: tracks)
        }
    }

    nonisolated private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x1 = max(a.minX, b.minX), y1 = max(a.minY, b.minY)
        let x2 = min(a.maxX, b.maxX), y2 = min(a.maxY, b.maxY)
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        return inter / (a.width * a.height + b.width * b.height - inter + 1e-6)
    }

    /// v6.7.7：相机通路对齐块存前 6 张（存进暂存列表，随照片签到分享带出），
    /// 文件名带嵌入范数——拿到图即可目视核对"模型看到的脸"是否与框一致
    nonisolated(unsafe) private static var camCropDumps = 0

    /// 对齐 + ResNet50 特征提取（recogQueue 后台执行）。
    /// v6.7.7：返回 (特征, 原始范数)；范数 < 14 判定为非人脸块返回 nil——
    /// 离线实测（90 人图库对拍）：墙/桌面/黑暗/百叶窗块的嵌入范数 6–9.5，
    /// 真人脸（含暗光小脸）17.4–26.6，14 是带大裕量的分界。
    /// v6.7.9：范数闸之前再加"饱和闸"——v6.7.8 实测木纹墙条纹块检测分
    /// 高达 0.922（比多数真脸还高）、五点齐全、嵌入范数 21.6，检测阈值/
    /// 几何校验/范数闸全部拦不住，却能以 0.46 撞上花名册冒名确认；但它的
    /// 对齐块平均饱和度只有 0.076（3 块杂波 0.076–0.145，41 张真脸含暗光
    /// 小脸最低 0.171）。饱和闸在 R50 之前执行，拦杂波的同时省下嵌入算力。
    nonisolated private static func recognize(cgImage cg: CGImage,
                                              kps: [CGPoint]) -> (vec: [Float], norm: Float)? {
        guard let m = FaceAligner.similarityTransform(src: kps, dst: FaceAligner.template),
              let pb = FaceAligner.alignedPixelBuffer(cgImage: cg, transform: m)
        else { return nil }
        let sat = FaceAligner.meanSaturation(pb)
        guard sat >= 0.15 else {
            print(String(format:
                "[相机-v6.7.24] 饱和闸拦截：饱和=%.3f < 0.15 → 非人脸块（未跑 R50）", sat))
            return nil
        }
        guard let r = FaceRecognizer.shared.embedWithRawNorm(pb) else { return nil }
        if camCropDumps < 6 {
            camCropDumps += 1
            if let url = FaceAligner.dumpAlignedCrop(
                pb, tag: String(format: "相机%d_范数%.1f_饱和%.2f",
                                camCropDumps, r.rawNorm, sat)) {
                FaceRecognizer.pendingDumpURLs.append(url)
            }
            let kpStr = kps.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) }
                .joined(separator: "|")
            print(String(format: "[相机-v6.7.24] 识别#%d 范数=%.1f 饱和=%.2f kps=%@（对齐块已存）",
                         camCropDumps, r.rawNorm, sat, kpStr))
        }
        guard r.rawNorm >= 14 else {
            print(String(format: "[相机-v6.7.24] 范数闸拦截：范数=%.1f < 14（饱和=%.2f）→ 判为非人脸块",
                         r.rawNorm, sat))
            return nil
        }
        return (r.vec, r.rawNorm)
    }

    // MARK: - 识别与融合（以下均运行在主线程）

    private func applyRecognition(trackId: Int, feature: [Float], frame: Int) {
        var scored: [(Int, Float)] = []
        for (i, g) in gallery.enumerated() {
            scored.append((i, FaceRecognizer.cosine(feature, g)))
        }
        scored.sort { $0.1 > $1.1 }
        let cands = scored.prefix(5).map { (student: self.students[$0.0], score: $0.1) }
        // top1 与 top2 差距过小 → 结果不可靠，最多只能"待确认"
        let ambiguous = scored.count >= 2 && (scored[0].1 - scored[1].1) < 0.05

        var r = results[trackId] ?? TrackResult()
        r.attempts += 1
        r.frameRecognized = frame
        r.candidates = Array(cands)

        // v6.7.16：多帧嵌入平均（EMA，α=0.4，等效最近约 4 帧加权）——手扫单帧
        // 噪声大（运动模糊/侧视角/小脸 kps 抖动），同轨道 EMA 向量与图库的
        // 余弦通常比单帧更稳。本轮证据取 单帧 与 平均 的高者，归属随证据走；
        // 单帧峰值由"更高才更新"规则天然保留，平均只可能锦上添花。
        if r.embEMA.isEmpty {
            r.embEMA = feature
        } else {
            for k in 0..<min(r.embEMA.count, feature.count) {
                r.embEMA[k] = r.embEMA[k] * 0.6 + feature[k] * 0.4
            }
        }
        r.embFrames += 1
        var avgTop1: (idx: Int, score: Float)?
        var avgAmbig = false
        if r.embFrames >= 2 {
            let norm = sqrt(r.embEMA.reduce(0) { $0 + $1 * $1 })
            if norm > 1e-6 {
                let avg = r.embEMA.map { $0 / norm }
                var asc: [(Int, Float)] = []
                for (i, g) in gallery.enumerated() {
                    asc.append((i, FaceRecognizer.cosine(avg, g)))
                }
                asc.sort { $0.1 > $1.1 }
                if let t = asc.first {
                    avgTop1 = t
                    avgAmbig = asc.count >= 2 && (asc[0].1 - asc[1].1) < 0.05
                }
            }
        }
        // 生效证据：平均分更高则采纳平均的归属与歧义判定，否则沿用单帧
        var effIdx = scored.first?.0
        var effScore = scored.first?.1 ?? 0
        var effAmb = ambiguous
        if let a = avgTop1, a.score > effScore {
            effIdx = a.idx
            effScore = a.score
            effAmb = avgAmbig
        }
        if let ei = effIdx, effScore >= Thresholds.uncertain,
           r.studentId == nil || effScore > r.score {
            // 重试时仅在新分数更高（或原本无归属）时更新归属
            r.score = effScore
            r.studentId = students[ei].studentId
            r.ambiguous = effAmb
        }

        // 同一学生只能归属一个跟踪目标：冲突时分数低者让出
        // v6.7.8：让出者即"同一人的重复轨道"（扫视中人离开画面再回来会
        // 建新轨）——尝试数直接拉满，不再浪费识别预算重复识别同一个人；
        // 身份已由分高的轨道持有，考勤结果不受影响
        // v6.7.10：拉满值 4→6，与目标选择的重试上限一致
        var yieldedTo = 0
        if let sid = r.studentId {
            for (tid, res) in results where tid != trackId && res.studentId == sid {
                if manualAssigned[tid] != nil || res.score >= r.score {
                    r.studentId = nil      // 对方是人工指定或分更高：本次让出
                    r.score = 0
                    r.attempts = max(r.attempts, 6)
                    yieldedTo = tid
                    break
                } else {
                    var loser = res
                    loser.studentId = nil    // 对方让出
                    loser.score = 0
                    loser.attempts = min(loser.attempts, 1)   // 允许它再试
                    results[tid] = loser
                }
            }
        }
        results[trackId] = r
        // v6.7.7：每次识别一行日志（~1 次/秒，不刷屏）——相机通路此前
        // 完全没有逐次相似度输出，识别成败只能凭状态栏猜
        let t1 = cands.first
        let t2 = cands.count > 1 ? cands[1] : nil
        let avgStr = avgTop1.map {
            String(format: " 平均=%@ %.3f", students[$0.idx].name, $0.score)
        } ?? ""
        print(String(format:
            "[相机-v6.7.24] track%d 尝试%d top1=%@ %.3f top2=%@ %.3f%@ → %@",
            trackId, r.attempts, t1?.student.name ?? "-", t1?.score ?? 0,
            t2?.student.name ?? "-", t2?.score ?? 0, avgStr,
            yieldedTo > 0 ? "让出(与track\(yieldedTo)同一人，分低归并)"
                : (r.studentId != nil
                    ? (r.ambiguous ? "待确认(歧义)" : (r.score >= Thresholds.confirmed ? "确认" : "待确认"))
                    : "未识别(<0.30)")))
        // 识别完成后立即刷新资格快照，下一检测轮即可用最新状态选目标
        targetLock.lock()
        recogSnapshot = results.mapValues {
            (junk: $0.junk, score: $0.score, attempts: $0.attempts,
             frameRecognized: $0.frameRecognized)
        }
        targetLock.unlock()
    }

    /// 由当前各跟踪目标归属实时重算场次级融合（人工指定 > 自动归属）。
    /// 每次发布标签前调用，保证冲突仲裁 / 人工改判后立即一致。
    private func recomputeStudentBest() {
        var best: [String: (score: Float, hits: Int, manual: Bool, ambiguous: Bool)] = [:]
        for (tid, r) in results {
            if manualAssigned[tid] != nil { continue }    // 人工项单独算
            guard let sid = r.studentId, !sid.isEmpty else { continue }
            var e = best[sid] ?? (score: 0, hits: 0, manual: false, ambiguous: false)
            if r.score > e.score { e.score = r.score; e.ambiguous = r.ambiguous }
            e.hits += 1
            best[sid] = e
        }
        for (_, sid) in manualAssigned where !sid.isEmpty {
            var e = best[sid] ?? (score: 0, hits: 0, manual: false, ambiguous: false)
            e.manual = true
            e.score = 1.0
            e.hits += 1
            e.ambiguous = false
            best[sid] = e
        }
        studentBest = best
    }

    /// 人工修正：把某跟踪目标指定给某学生（或 nil 表示非本班）
    func manualAssign(trackId: Int, studentId: String?) {
        DispatchQueue.main.async {
            if let sid = studentId {
                self.manualAssigned[trackId] = sid
                var r = self.results[trackId] ?? TrackResult()
                r.studentId = sid
                r.score = 1.0
                r.ambiguous = false
                self.results[trackId] = r
            } else {
                self.manualAssigned[trackId] = ""   // 非本班
                self.results[trackId]?.studentId = nil
            }
            self.recomputeStudentBest()
            self.publishOverlays(tracks: self.tracker.tracks)   // 立即刷新标签
        }
    }

    /// 学生状态：绿（自动确认）/ 橙（待确认）
    func levelFor(studentId sid: String) -> MatchLevel {
        guard let e = studentBest[sid] else { return .unknown }
        if e.manual { return .confirmed }
        if e.ambiguous { return .uncertain }   // 歧义结果不得自动确认
        if e.score >= Thresholds.confirmed || (e.hits >= 2 && e.score >= Thresholds.uncertain) {
            return .confirmed
        }
        return .uncertain
    }

    // MARK: - 标签发布（主线程调用）

    private func publishOverlays(tracks: [FaceTracker.Track]) {
        // v6.7.6：方向未锁定期间不发布任何框——此时检测走的是教科书映射，
        // 而本设备实测教科书映射与画布真实方向差 180°（v6.7.5 两轮日志实锤），
        // 画出来必是错位框；锁定一般在对准教室后数秒内完成
        guard orientationLocked else {
            overlays = []
            confirmedCount = 0
            uncertainCount = 0
            unknownFaces = 0
            return
        }
        recomputeStudentBest()
        // 显示新鲜度窗口——只画最近 12 轮（约 10~15 秒）内被检测重新命中过的
        // 轨道。扫视教室时人已离开画面，轨道却按 maxMisses=150 存活（保身份
        // 连续性，便于人再次入镜时续上识别进度）；v6.7.8 时代窗口取 100 是
        // 怕误伤持续可见的真脸，但 v6.7.12 实测约 1 秒/轮 → 100 轮≈1.5 分钟，
        // 相机早已扫走，旧框（尤其是"未识别"红框）残留满屏。12 轮足够覆盖
        // 偶发的单轮漏检，持续可见的真脸每轮都会刷新 lastSeen，不受影响。
        // （识别资格不看此窗口：结果存在 studentBest/results 里，框消失了
        // 考勤成绩不消失）
        let list: [FaceOverlay] = tracks.filter { frameIndex - $0.lastSeen <= 12 }
            .compactMap { t in
            let r = results[t.id]
            if r?.junk == true { return nil }   // v6.7.7：杂波轨道（非人脸）不发布
            let sid = manualAssigned[t.id] ?? r?.studentId
            // v6.7.11 待识别框隐藏：从未识别过的轨道一律不画——屏幕只呈现
            // 已有结果的轨道（姓名绿/橙、"未识别"红），随扫描逐个亮起。
            // v6.7.10 实测"红框海"的构成 = 后排小脸（<60px 永不进识别队列，
            // "…"挂到会话结束）+ 排队等首次识别的轨道——"…"框既不传达信息
            // 又满屏遮挡画面，剩余人数由顶部红色计数（花名册−绿−橙）表达。
            // 点按修正不受影响：已尝试过的轨道（含"未识别"）照常显示可点
            if (sid == nil || sid!.isEmpty), (r?.frameRecognized ?? -1) < 0 {
                return nil
            }
            let score = r?.score ?? 0
            let level: MatchLevel
            let label: String
            if let sid, !sid.isEmpty, let st = allStudents.first(where: { $0.studentId == sid }) {
                level = levelFor(studentId: sid)
                label = st.name
            } else if (r?.frameRecognized ?? -1) >= 0 {
                level = .unknown
                label = "未识别"
            } else {
                level = .unknown
                label = "…"
            }
            // v6.7.7：显示框放大 1.32×——SCRFD 检出框紧贴面部特征区，
            // 用户期望"框住整张脸"；仅影响显示，识别仍用原始检测框
            let disp = t.box.insetBy(dx: -t.box.width * 0.16,
                                     dy: -t.box.height * 0.16)
            return FaceOverlay(id: t.id, rect: disp, label: label, level: level,
                               score: score, studentId: sid,
                               candidates: r?.candidates ?? [])
        }
        // v6.7.12：同一个人扫视中常被跟踪成多个轨道（遮挡/重现后新建），
        // 每个轨道各挂一个框，同一颗头上叠着绿框+好几个"未识别"红框。
        // 显示层去重：有名字的框优先（同名取分高），无名框之间分高者优先；
        // 与已保留框 IoU ≥ 0.35 的丢弃。比对用原始跟踪框而非 1.32× 显示框，
        // 避免相邻两个真人被误并。注意只影响显示——被丢弃轨道的识别结果
        // 早已进 studentBest，考勤不受影响。
        var kept: [FaceOverlay] = []
        var keptBoxes: [CGRect] = []
        let dedupOrder = list.sorted { a, b in
            let an = (a.studentId?.isEmpty == false) ? 1 : 0
            let bn = (b.studentId?.isEmpty == false) ? 1 : 0
            if an != bn { return an > bn }
            return a.score > b.score
        }
        for ov in dedupOrder {
            let rawBox = tracks.first(where: { $0.id == ov.id })?.box ?? ov.rect
            var dup = false
            for kb in keptBoxes where iou(rawBox, kb) >= 0.35 { dup = true; break }
            if !dup { kept.append(ov); keptBoxes.append(rawBox) }
        }
        overlays = kept
        confirmedCount = studentBest.keys.filter { levelFor(studentId: $0) == .confirmed }.count
        uncertainCount = studentBest.keys.filter { levelFor(studentId: $0) == .uncertain }.count
        // v6.7.8：红色计数改回考勤语义——"花名册里还没签到的人数"
        // （总数 − 绿 − 橙，扫视中从满员倒数到 0）。旧实现数的是"当前画面
        // 里没有名字的轨道数"，扫视残影+同人重复轨道会把计数推到 120+
        // 超过全班总人数，既吓人又没意义
        unknownFaces = max(0, allStudents.count - confirmedCount - uncertainCount)
    }

    // MARK: - 结束签到

    /// 生成考勤结果行（按班级、学号排序）
    func finish() -> (startedAt: Date, rows: [(student: Student, present: Bool,
                                               method: String, hits: Int, score: Float)])? {
        guard let course, let startedAt else { return nil }
        // v6.7.12：本场相机诊断图（对齐块_相机*）收进本场的场次文件夹——
        // 旧设计留在 exports 顶层，等下一场照片签到"顺路带走"，跨场次混放
        let sessionDir = AttendanceExporter.sessionDir(courseName: course.name,
                                                       date: startedAt)
        try? FileManager.default.createDirectory(at: sessionDir,
                                                 withIntermediateDirectories: true)
        for u in FaceRecognizer.pendingDumpURLs {
            var dst = sessionDir.appendingPathComponent(u.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                let base = u.deletingPathExtension().lastPathComponent
                dst = sessionDir.appendingPathComponent(
                    "\(base)_\(Int(Date().timeIntervalSince1970)).png")
            }
            try? FileManager.default.moveItem(at: u, to: dst)
        }
        FaceRecognizer.pendingDumpURLs.removeAll()
        let all = Database.shared.students(courseId: course.id)
        let rows = all.map { st -> (Student, Bool, String, Int, Float) in
            if let e = studentBest[st.studentId] {
                let method = e.manual ? "人工修正"
                    : (levelFor(studentId: st.studentId) == .confirmed
                       ? (e.hits >= 2 ? "多角度确认" : "自动确认") : "待确认")
                return (st, true, method, e.hits, e.score)
            }
            return (st, false, "", 0, 0)
        }
        return (startedAt, rows)
    }
}
