import CoreML
import CoreImage
import Accelerate
import UIKit

/// SCRFD 人脸检测器（与服务器版同源 det_10g.onnx）。
/// v6.7.23：detSize 实例化——det_10g 原生即 640² 导出（输出锚点 {12800/3200/800}），
/// 1920² 实例（shared/sharedImport）供扫描/照片/导入全精度路；
/// 640² 实例（sharedFast）供个人签到快检路，单次检测提速约一个数量级。
/// v6：模型改为经典 neuralnetwork 格式（spec v4，espresso 运行时）——
/// coremltools 9 的 mlprogram 产物在 iOS 26 上对任意输入都输出"常数签名"
/// （输入张量逐位验证正确、输出却与全黑输入一致，CPU/GPU/ANE 三后端皆然），
/// 整条 torch→mlprogram 管线被弃用；NN 后端是 2017 年以来最成熟的编译路径。
/// v6.5：输入渲染彻底弃用 CoreImage——设备实测 CIContext 仿射渲染（缩小/旋转）
/// 与假定几何不一致，导致检测框整体偏移（导入路径 scale=1 仅平移拷贝所以正常，
/// 拍照 0.476 缩小与相机 0.5 缩小+旋转全部中招，CPU/GPU 后端表现一致）。
/// 改用 Quartz（CGContext）仿射，数学上与服务器版 numpy letterbox 逐像素等价。
/// v6.6：修复 Quartz 画布的【像素格式】——CGImageAlphaInfo.premultipliedFirst
/// 单独使用时 CG 按 ARGB 内存序（大端字）写入，而缓冲是 32BGRA、PixelTensor
/// 按 BGRA 解读：结果是 B 通道被 alpha(255) 顶掉（模型看到恒 +1.0）、R/G 错位。
/// 识别路径因建库与现场同遭扭曲而自洽（余弦不敏感），检测是绝对比对所以崩。
/// 设备实锤：画布亮度均值与张量均值互相矛盾，拟合得字节序=[255, ~R, ~G]。
/// 修复：显式加 byteOrder32Little（32BGRA 的教科书位图标志）。
/// v6.7：修复画布【整体上下颠倒】——设备实测 CGContext(data:) 位图上下文
/// 恒等绘制即为 top-down（缓冲第 0 行=图像顶行、draw 的 rect 原点=图像左上角），
/// v6.5 起按"Quartz 绘制会颠倒"惯例多加的翻 Y 反而翻转了画布：检测框关于
/// 画布水平中线镜像（教室人脸集中在中线附近所以看似正常）、小脸召回崩塌
/// （参考复现：颠倒输入候选 159→17）、画布转储图肉眼可见颠倒。
/// 设备实锤：两张照片顶脸框与参考检测 IoU——镜像假设 0.88/0.81，原始 0.37/0.12。
/// 修复：检测画布、uprightCGImage、FaceAligner 三处全部删去翻 Y；
/// rotationTransform 的 .right/.left 常数按 EXIF 定义互换（原常数是 y-up
/// 假设下凑的）。识别特征因此变化，【必须再次重导花名册】（覆盖式导入）。
/// 输出人脸框 + 五点关键点（观察者视角：左眼、右眼、鼻尖、左嘴角、右嘴角）。
/// 整个类型非隔离：检测在相机后台队列同步执行，MLModel 推理线程安全。
nonisolated final class SCRFDDetector {

    /// GPU（Metal）路径实例。v6.4 曾因算子级偏差（框飘出人脸）停用；
    /// v6.7.16 起【相机扫描重新启用】——由 AttendanceEngine 的 CPU 影子
    /// 对拍背书（同帧比对召回率+关键点偏差，失败自动永久回退 CPU）。
    /// 注意：花名册导入/照片签到不走这里，永远用 sharedImport。
    static let shared = SCRFDDetector(computeUnits: .cpuAndGPU)
    /// CPU（BNNS fp32）路径实例，数值上最忠实参考实现。
    /// 花名册导入 / 照片签到 / 方向校准 / GPU 影子对拍基准 全部走这里——
    /// 宁可慢也要准，且这些场景对吞吐不敏感。
    static let sharedImport = SCRFDDetector(computeUnits: .cpuOnly)
    /// 640² 快检实例（v6.7.23）：det_10g.onnx 原生就是 640² 导出——输出锚点
    /// {12800/3200/800} 正是 640² 的 8/16/32 三层，1920² 一直是靠动态形状
    /// 硬跑的 9× 像素（CPU 实测 ~5.7s/帧，出框慢的根源）。640² 与 1920²
    /// 同权重同结构（137 层，离线逐张量对照 maxdiff≤1e-6，用户截图各档
    /// zoom 均 0.82+ 检出），单次检测快约一个数量级。
    /// .all 交给 Core ML 选后端（经典 NN 格式 conv 网优先落 ANE，预计
    /// 20~60ms）；若设备日志出现异常（三层最高崩塌 / 方向自检翻倒），
    /// 把 computeUnits 改回 .cpuAndGPU 即可（GPU 路径已被影子对拍背书）。
    /// 仅个人签到（前置近距单脸）使用；教室小脸阵列仍走 1920² 全精度路。
    static let sharedFast = SCRFDDetector(computeUnits: .all,
                                          modelName: "SCRFD640", detSize: 640)

    /// 检测输入边长（模型固定输入；1920=扫描/照片/导入全精度路，640=个签快检路）
    let detSize: Int
    private let detThresh: Float = 0.4
    private let nmsThresh: Float = 0.4
    private let strides = [8, 16, 32]
    private let numAnchors = 2

    struct Face: Sendable {
        var box: CGRect      // 正立原图像素坐标（原点左上）
        var kps: [CGPoint]   // 五点关键点（正立原图像素坐标）
        var score: Float
    }

    private var mlModel: MLModel?
    private(set) var loadError: String?
    /// 最近一次检测的诊断信息（导入失败时展示/控制台定位用）
    private(set) var debugStatus = "尚未运行检测"
    /// 诊断：模型自检信息（首次检测时生成）
    private var modelInfo = ""
    /// 诊断：画布转储标签（armCanvasDump 武装后，下一次检测把画布存为 PNG）
    private var canvasDumpTag: String?
    private let dumpLock = NSLock()

    /// CIContext 仅用于"相机像素缓冲 → CGImage 的 1:1 拷贝"（不经仿射，安全）
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 32BGRA 缓冲的位图标志：premultipliedFirst 必须显式配 byteOrder32Little，
    /// 否则 CG 默认按大端字（内存 ARGB）写入，与 BGRA 缓冲/PixelTensor 不符（v6.6）
    private static let bgraBitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private init(computeUnits: MLComputeUnits,
                 modelName: String = "SCRFD", detSize: Int = 1920) {
        self.detSize = detSize
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
            loadError = "未找到 \(modelName) 模型，请确认 \(modelName).mlmodel 已加入工程 Target"
            return
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        do {
            mlModel = try MLModel(contentsOf: url, configuration: config)
        } catch { loadError = "模型加载失败: \(error.localizedDescription)" }
    }

    /// 武装画布转储：下一次检测把"模型实际看到的画布"存到
    /// exports/SCRFD画布_<tag>.png——所见即模型所得，用于核对 letterbox 几何
    func armCanvasDump(tag: String) {
        dumpLock.lock()
        canvasDumpTag = tag
        dumpLock.unlock()
    }

    // MARK: - 检测入口

    /// 静态照片检测（CGImage 需已按 EXIF 转正）。
    /// maxSideFactor：巨框上限 = 画面短边 × 系数。教室场景用默认 0.35
    /// （拦墙面/幕布纹理的巨框误检）；证件照导入传 2.0——证件照的脸本来
    /// 就该占半张图，0.35 会把真脸当巨框拦掉（v6.7.12 实测 69×78/99×111/
    /// 199×223 三档证件照 83 人全灭，检分 0.82+ 的脸被几何校验误杀）
    func detect(in cgImage: CGImage, thresh: Float? = nil,
                maxSideFactor: CGFloat = 0.35) -> [Face] {
        detect(cgImage, pre: .identity,
               uprightW: CGFloat(cgImage.width), uprightH: CGFloat(cgImage.height),
               thresh: thresh, maxSideFactor: maxSideFactor)
    }

    /// 相机帧检测：传感器原生像素缓冲（横向）+ 转正方向。
    /// v6.5：CI 仅做 1:1 拷贝成 CGImage；转正旋转并入画布仿射（Quartz 一次完成
    /// 旋转+缩放+居中+翻 Y），不再经过 CoreImage 的 oriented/仿射渲染。
    func detect(pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                maxSideFactor: CGFloat = 0.35) -> [Face] {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = Self.ciContext.createCGImage(ci, from: ci.extent) else { return [] }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rot = Self.rotationTransform(orientation, w: w, h: h)
        // v6.7.7：相机通路阈值 0.4→0.5——实测试图场景中白板/窗帘/讲台纹理
        // 在 0.4–0.5 分段产生大量误检框（真脸普遍 ≥0.8），抬阈值直接砍掉大半
        // v6.7.19：maxSideFactor 透出——个人签到（前置近距离）脸占半屏，
        // 0.35 的教室巨框上限会把真脸误杀（同 v6.7.13 证件照教训），该路传 2.0
        return detect(cg, pre: rot.t, uprightW: rot.uw, uprightH: rot.uh, thresh: 0.5,
                      maxSideFactor: maxSideFactor)
    }

    /// v6.7.7：五点几何校验（所有检测出口统一过滤）。
    /// SCRFD 对非人脸纹理（百叶窗/墙缝/衣服褶皱）也会报出候选并幻觉出
    /// "标准人脸排布"的关键点，但多数存在眼鼻嘴顺序错乱、左右眼互换、
    /// 关键点飘出框外、框长宽比异常等问题；真脸（含小脸）几乎全过。
    /// 离线对拍（90 人图库）：误检块嵌入范数 6–9.5，真脸 17.4–26.6。
    /// v6.7.8：加 maxSide 上限（画面短边 × 0.35）。讲台木纹/投影幕布等
    /// 大面积纹理会被报成上千像素的"巨脸"——长宽比正常、关键点也在框内，
    /// 旧校验全部放行；显示层糊成满屏红带、"最大脸优先"的识别预算被它
    /// 抢走皆源于此。实测最前排真人脸 ≤200px（相机 2160 宽），上限 756px
    /// 带三倍裕量；照片通路（最短边 3024）上限 1058px，真脸 ≤200px。
    static func geometryOK(_ f: Face, maxSide: CGFloat) -> Bool {
        let b = f.box
        guard b.width >= 12, b.height >= 12 else { return false }
        guard b.width <= maxSide, b.height <= maxSide else { return false }
        let ar = b.width / max(1, b.height)
        guard ar > 0.45, ar < 1.8 else { return false }
        let k = f.kps
        guard k.count == 5 else { return false }
        // 正立人脸：眼在鼻上、鼻在嘴上（1px 容差；小脸关键点有量化噪声）
        let eyeY = min(k[0].y, k[1].y), mouthY = max(k[3].y, k[4].y)
        guard eyeY < k[2].y + 1, k[2].y < mouthY + 1 else { return false }
        // 左右眼不得互换（画布镜像/颠倒的残留候选在此被拦）
        guard k[0].x < k[1].x + 2 else { return false }
        // 关键点应落在框附近（0.7 倍框宽容差，比导入兜底的 0.6 略宽）
        let pad = b.width * 0.7
        for p in k {
            guard p.x > b.minX - pad, p.x < b.maxX + pad,
                  p.y > b.minY - pad, p.y < b.maxY + pad else { return false }
        }
        return true
    }

    /// 导入兜底（v6.2）：常规阈值无候选时，以低阈值取最高分候选并做几何校验。
    /// 仅用于证件照场景（保证单人正面、每张照片必有一张脸）；
    /// 校验框尺寸/长宽比/五点顺序，防止把背景杂波当人脸。
    func detectBestEffort(in cgImage: CGImage, floor thresh: Float,
                          maxSideFactor: CGFloat = 0.35) -> Face? {
        guard let best = detect(in: cgImage, thresh: thresh,
                                maxSideFactor: maxSideFactor)
            .max(by: { $0.score < $1.score })
        else { return nil }
        let b = best.box
        guard b.width >= 30, b.height >= 30 else { return nil }
        let ar = b.width / max(1, b.height)
        guard ar > 0.5, ar < 1.6 else { return nil }
        let k = best.kps
        guard k.count == 5 else { return nil }
        // 正立人脸：双眼在鼻上方、鼻在嘴上方（图像坐标 y 向下增大）
        let eyeY = min(k[0].y, k[1].y), mouthY = max(k[3].y, k[4].y)
        guard eyeY < k[2].y, k[2].y < mouthY else { return nil }
        // 关键点应落在框附近
        let pad = b.width * 0.6
        for p in k {
            guard p.x > b.minX - pad, p.x < b.maxX + pad,
                  p.y > b.minY - pad, p.y < b.maxY + pad else { return nil }
        }
        return best
    }

    /// 转正仿射（用于 Quartz 绘制链 CTM = L · pre 中的 pre 环节）+ 正立尺寸。
    /// v6.7 实测确认：CGContext(data:) 位图上下文按 top-down 行序工作
    /// （draw 的 rect 原点 = 图像左上角，缓冲第 0 行 = 顶行），
    /// 因此 pre 就是标准的"top-down→top-down" EXIF 转正矩阵。
    /// .right=竖屏顺时针90°，.left=270°，.down=180°。
    static func rotationTransform(_ o: CGImagePropertyOrientation,
                                  w: CGFloat, h: CGFloat)
        -> (t: CGAffineTransform, uw: CGFloat, uh: CGFloat) {
        switch o {
        case .right: // v=(h-u.y, u.x)
            // v6.7.2 定案：本组常量（EXIF 教科书 .right = 顺时针 90°）才是正确的。
            // 三重证据：①竖屏照片 EXIF 恒为 .right（旋转 CW 显示），视频缓冲同一
            // 传感器排布；②预览层 videoRotationAngle=90（CW）显示一直正常，画布必须
            // 施加同一旋转才能与预览同坐标系；③v6.7.1 误换为逆时针常量后，设备日志
            // 呈"颠倒输入崩塌"特征（候选 1–17 个、三层最高≤0.26，对照离线实锤
            // 159→17）——证明逆时针常量把画布转了 180°。
            // v6.7 报告的"相机框错位"并非本常量所致；v6.7.2 起日志带关键点
            // 方向自检（眼/嘴上下关系），画布方向由设备日志直接判定。
            return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0), h, w)
        case .left:  // v=(u.y, w-u.x)
            return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w), h, w)
        case .down:  // 180°
            return (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h), w, h)
        default:     // .up（横屏界面，传感器原生方向即正立）
            return (.identity, w, h)
        }
    }

    /// 相机全分辨率正立 CGImage（识别对齐用）：Quartz 旋转，不经 CI 仿射。
    /// angle 与预览层连接使用同一映射（90=竖屏）。
    static func uprightCGImage(from pb: CVPixelBuffer, angle: CGFloat) -> CGImage? {
        let o: CGImagePropertyOrientation =
            angle == 0 ? .up : angle == 180 ? .down : angle == 270 ? .left : .right
        return uprightCGImage(from: pb, orientation: o)
    }

    /// v6.7.3：直接按转正方向生成——相机方向自校准锁定后，识别对齐图必须与
    /// 检测画布走同一方向（教科书映射被设备推翻时，角度映射会带错方向）
    static func uprightCGImage(from pb: CVPixelBuffer,
                               orientation o: CGImagePropertyOrientation) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let src = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        let w = CGFloat(src.width), h = CGFloat(src.height)
        let rot = rotationTransform(o, w: w, h: h)
        if o == .up { return src }
        let uw = Int(rot.uw), uh = Int(rot.uh)
        guard let ctx = CGContext(data: nil, width: uw, height: uh,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: Self.bgraBitmapInfo)   // v6.6：与 BGRA 约定一致
        else { return nil }
        // v6.7：与画布同一修正——恒等绘制即 top-down，删去多余翻 Y，只保留转正旋转
        ctx.concatenate(rot.t)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 渲染画布 + 推理 + 后处理

    private func detect(_ cg: CGImage, pre: CGAffineTransform,
                        uprightW contentW: CGFloat, uprightH contentH: CGFloat,
                        thresh: Float? = nil,
                        maxSideFactor: CGFloat = 0.35) -> [Face] {
        // 相机路径每秒调用十余次、批量导入连续调用数百次：渲染/推理产生大量
        // autoreleased 中间对象，后台线程没有 runloop 不会自动排空，
        // 必须显式 autoreleasepool，否则内存堆积被杀
        autoreleasepool { detectImpl(cg, pre: pre, uprightW: contentW, uprightH: contentH,
                                     thresh: thresh, maxSideFactor: maxSideFactor) }
    }

    private func detectImpl(_ cg: CGImage, pre: CGAffineTransform,
                            uprightW contentW: CGFloat, uprightH contentH: CGFloat,
                            thresh: Float? = nil,
                            maxSideFactor: CGFloat = 0.35) -> [Face] {
        let threshold = thresh ?? detThresh
        guard let mlModel else {
            debugStatus = "模型未初始化（\(loadError ?? "未知原因")）"
            return []
        }
        let det = CGFloat(detSize)
        guard contentW > 1, contentH > 1 else {
            debugStatus = "输入图像尺寸异常 \(Int(contentW))x\(Int(contentH))"
            print("[SCRFD] \(debugStatus)")
            return []
        }
        // 永不放大：小图 1:1 放入画布，大图等比缩小；居中补黑
        let scale = min(1, det / max(contentW, contentH))
        let cw = contentW * scale, ch = contentH * scale
        let padX = (det - cw) / 2, padY = (det - ch) / 2

        // ===== v6.5：Quartz 渲染画布；v6.7：删除多余的翻 Y =====
        // CTM = L · pre：
        //   pre  = 传感器坐标 → 正立 top-down 坐标（静态照片为 identity）
        //   L    = letterbox（缩放 scale + 平移 padX,padY），正立 top-down → 画布 top-down
        // 设备实测（iOS 26）：CGContext(data:) 位图上下文恒等绘制即为 top-down
        // （缓冲第 0 行 = 图像顶行），draw 的 rect 原点拿到图像左上角——
        // v6.5/v6.6 按"Quartz 绘制会颠倒"的惯例多加的翻 Y 反而把画布整体翻转，
        // 检测框关于画布水平中线镜像（近中线的框看似正常，掩盖了两轮）。
        // 证据：两张照片的顶脸框与参考检测做 IoU，镜像假设 0.88/0.81、原始假设 0.37/0.12；
        // 颠倒输入下参考候选数崩塌（159→17），与设备低召回一致。
        // 与 numpy 参考 canvas[padY:padY+ch, padX:padX+cw] = resized 逐像素等价
        var pbOpt: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, detSize, detSize,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &pbOpt) == kCVReturnSuccess, let pb = pbOpt else {
            debugStatus = "画布像素缓冲创建失败"
            print("[SCRFD] \(debugStatus)")
            return []
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * detSize)
            if let ctx = CGContext(data: base, width: detSize, height: detSize,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: Self.rgbSpace,
                                   bitmapInfo: Self.bgraBitmapInfo) {   // v6.6 修复：显式 BGRA 小端
                ctx.interpolationQuality = .high   // 与 FaceAligner 对齐档位一致
                // v6.7：不再翻 Y——恒等绘制即 top-down，翻 Y 会把画布弄颠倒
                ctx.concatenate(CGAffineTransform(translationX: padX, y: padY)
                                    .scaledBy(x: scale, y: scale))
                ctx.concatenate(pre)
                ctx.draw(cg, in: CGRect(x: 0, y: 0,
                                        width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
        }

        // ===== 诊断：画布自检（模型到底看到了什么）=====
        if modelInfo.isEmpty {
            if let desc = mlModel.modelDescription.inputDescriptionsByName["det_input"],
               let shape = desc.multiArrayConstraint?.shape {
                modelInfo = "模型输入=张量\(shape)"
            } else {
                modelInfo = "模型输入=?（非张量类型！模型未更新）"
            }
        }
        // 采样闭包：画布亮度统计（~2 千像素抽样）
        let sampleCanvas: () -> (Double, Double) = {
            var lumSum = 0, lumN = 0, nonBlack = 0
            if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pb)
                var i = 0
                while i < self.detSize * self.detSize {
                    let row = i / self.detSize, col = i % self.detSize
                    let px = base + row * rowBytes + col * 4
                    let lum = (Int(px[0]) + Int(px[1]) * 2 + Int(px[2])) / 4
                    lumSum += lum; lumN += 1
                    if lum > 12 { nonBlack += 1 }
                    i += 2053
                }
            }
            return (lumN > 0 ? Double(lumSum) / Double(lumN) : -1,
                    lumN > 0 ? 100.0 * Double(nonBlack) / Double(lumN) : -1)
        }
        let (meanLum, nonBlackPct) = sampleCanvas()
        let canvasInfo = String(format: "画布均值=%.1f 非黑=%.0f%%", meanLum, nonBlackPct)
        // 画布转储（按需武装：每张照片/相机首帧各存一张，所见即模型所得）
        dumpLock.lock()
        let dumpTag = canvasDumpTag
        canvasDumpTag = nil
        dumpLock.unlock()
        if let dumpTag, let base = CVPixelBufferGetBaseAddress(pb),
           let ctx = CGContext(data: base, width: detSize, height: detSize,
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: Self.rgbSpace,
                               bitmapInfo: Self.bgraBitmapInfo),   // 与缓冲实际布局一致
           let dbg = ctx.makeImage() {
            let small = UIImage(cgImage: dbg).preparingThumbnail(of: CGSize(width: 640, height: 640))
            if let data = (small ?? UIImage(cgImage: dbg)).pngData() {
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("exports")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let safe = dumpTag.components(separatedBy:
                    CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
                try? data.write(to: dir.appendingPathComponent("SCRFD画布_\(safe).png"))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        // ===== 诊断结束 =====

        // 像素缓冲 → 归一化张量（全自控，不经 Core ML 图像输入的运行时转换）
        guard let tensor = PixelTensor.make(from: pb, size: detSize) else {
            debugStatus = "[v6.7] 输入张量构建失败"
            print("[SCRFD-v6.7.24] \(debugStatus)")
            return []
        }
        let ts = PixelTensor.sampleStats(tensor)
        let tensorInfo = String(format: "张量均值=%.2f 范围[%.2f, %.2f]（应≈(画布均值-127.5)/128；B通道被alpha顶掉时会明显偏高）",
                                ts.mean, ts.min, ts.max)

        // 直接推理（张量输入，不经 Vision）；记录耗时供速度评估
        let provider: MLDictionaryFeatureProvider
        let prediction: MLFeatureProvider
        let inferMs: Double
        do {
            provider = try MLDictionaryFeatureProvider(
                dictionary: ["det_input": MLFeatureValue(multiArray: tensor)])
            let t0 = Date()
            prediction = try mlModel.prediction(from: provider)
            inferMs = Date().timeIntervalSince(t0) * 1000
        } catch {
            debugStatus = "[v6.7] 推理执行失败: \(error.localizedDescription)"
            print("[SCRFD-v6.7.24] \(debugStatus)")
            return []
        }

        // 按输出形状归类：scores [N,1] / bbox [N,4] / kps [N,10]，各按 N 降序对应 stride 8/16/32
        var scores: [MLMultiArray] = []
        var bboxes: [MLMultiArray] = []
        var kpss: [MLMultiArray] = []
        for name in prediction.featureNames {
            guard let arr = prediction.featureValue(for: name)?.multiArrayValue else { continue }
            // NN 输出形状可能是 [N,C] 或 [1,N,C]：列数取最后一维，行数=总数/列数
            let cols = arr.shape.last?.intValue ?? 1
            switch cols {
            case 1: scores.append(arr)
            case 4: bboxes.append(arr)
            case 10: kpss.append(arr)
            default: continue
            }
        }
        guard scores.count == 3, bboxes.count == 3, kpss.count == 3 else {
            let shapes = prediction.featureNames.compactMap {
                (prediction.featureValue(for: $0)?.multiArrayValue?.shape as? [NSNumber])?.description ?? "?"
            }
            debugStatus = "输出分组异常 s/b/k=\(scores.count)/\(bboxes.count)/\(kpss.count)，形状=\(shapes)"
            print("[SCRFD] \(debugStatus)")
            return []
        }
        // 首次检测：记录全部输出的形状/stride/类型（设备若有行对齐填充会在此暴露）
        if !modelInfo.contains("输出=") {
            let desc = prediction.featureNames.compactMap { n -> String? in
                guard let a = prediction.featureValue(for: n)?.multiArrayValue else { return nil }
                return "\(n):形状\(a.shape)stride\(a.strides)\(a.dataType == .float32 ? "f32" : "f16")"
            }.joined(separator: " | ")
            modelInfo += "；输出=\(desc)"
        }
        let rowsOf: (MLMultiArray) -> Int = { a in
            let c = max(1, a.shape.last?.intValue ?? 1)
            return a.count / c
        }
        let byRows: (MLMultiArray, MLMultiArray) -> Bool = { rowsOf($0) > rowsOf($1) }
        scores.sort(by: byRows); bboxes.sort(by: byRows); kpss.sort(by: byRows)
        // 整批转为 [Float]（stride 安全提取 + vImage 加速 Float16），避免逐元素下标调用
        let sData = scores.map { Self.floatArray($0) }
        let bData = bboxes.map { Self.floatArray($0) }
        let kData = kpss.map { Self.floatArray($0) }

        var allScores: [Float] = []
        var allBoxes: [[Float]] = []
        var allKps: [[Float]] = []

        for (i, stride) in strides.enumerated() {
            let fw = detSize / stride
            let n = rowsOf(scores[i])
            let ss = sData[i], bb = bData[i], kk = kData[i]
            let fstride = Float(stride)
            for k in 0..<n {
                let s = ss[k]
                if s < threshold { continue }
                // anchor 中心：index = (y*fw + x) * numAnchors + a
                let cell = k / numAnchors
                let cx = Float(cell % fw) * fstride
                let cy = Float(cell / fw) * fstride
                let bo = k * 4, ko = k * 10
                allBoxes.append([cx - bb[bo] * fstride, cy - bb[bo + 1] * fstride,
                                 cx + bb[bo + 2] * fstride, cy + bb[bo + 3] * fstride])
                var kp: [Float] = []
                kp.reserveCapacity(10)
                for j in 0..<5 {
                    kp.append(cx + kk[ko + j * 2] * fstride)
                    kp.append(cy + kk[ko + j * 2 + 1] * fstride)
                }
                allKps.append(kp)
                allScores.append(s)
            }
        }

        guard !allScores.isEmpty else {
            // 所有分数都低于阈值：报告各层最高分，判断是模型输出问题还是阈值问题
            var layerMax: [String] = []
            for d in sData { layerMax.append(String(format: "%.3f", d.max() ?? -1)) }
            setDebug("[v6.7.24] 无超过阈值 \(threshold) 的候选；三层最高分=\(layerMax)；\(canvasInfo)；\(tensorInfo)；\(modelInfo)")
            return []
        }
        // 按分数降序 + NMS
        var alive = allScores.indices.sorted { allScores[$0] > allScores[$1] }
        var keep: [Int] = []
        while !alive.isEmpty {
            let i = alive.removeFirst()
            keep.append(i)
            alive.removeAll { iou(allBoxes[i], allBoxes[$0]) > nmsThresh }
        }

        // 诊断：最高分人脸的【画布原始坐标】+ letterbox 参数，
        // 与参考实现/画布转储对照可定位"框偏移"发生在模型输出还是坐标换算
        var rawInfo = ""
        if let top = keep.first {
            let b = allBoxes[top]
            rawInfo = String(format:
                "；顶脸画布框=[%.0f,%.0f %.0fx%.0f] 分=%.3f pad=(%.0f,%.0f)",
                b[0], b[1], b[2] - b[0], b[3] - b[1], allScores[top], padX, padY)
        }

        // 画布坐标 → 正立原图坐标：减去居中偏移再除以缩放比
        let inv = 1 / scale
        let faces = keep.compactMap { i -> Face? in
            let b = allBoxes[i]
            let box = CGRect(x: (CGFloat(b[0]) - padX) * inv,
                             y: (CGFloat(b[1]) - padY) * inv,
                             width: CGFloat(b[2] - b[0]) * inv,
                             height: CGFloat(b[3] - b[1]) * inv)
            // 框完全在补黑区域外才有效
            guard box.maxX > 0, box.maxY > 0,
                  box.minX < contentW, box.minY < contentH else { return nil }
            var pts: [CGPoint] = []
            for j in 0..<5 {
                pts.append(CGPoint(x: (CGFloat(allKps[i][j * 2]) - padX) * inv,
                                   y: (CGFloat(allKps[i][j * 2 + 1]) - padY) * inv))
            }
            return Face(box: box, kps: pts, score: allScores[i])
        }
        let layerMaxOK = sData.map { String(format: "%.3f", $0.max() ?? -1) }.joined(separator: "/")
        // v6.7.2 方向自检：SCRFD 五点顺序 = [左眼(画面左), 右眼, 鼻, 左嘴角, 右嘴角]
        // （已用 ONNX 参考在证件照上验证：k0.x<k1.x 且眼 y<鼻 y<嘴 y）。
        // 正立画布：眼在嘴上方；画布颠倒 180°：眼在嘴下方且左右眼互换；
        // 画布左右镜像：仅左右眼互换。统计计入日志，方向问题一看便知。
        var upN = 0, downN = 0, mirrorN = 0
        for f in faces where f.score >= 0.5 && f.kps.count == 5 && f.box.height >= 16 {
            let k = f.kps
            let eyeY = (k[0].y + k[1].y) / 2, mouthY = (k[3].y + k[4].y) / 2
            if eyeY < mouthY - 2 { upN += 1 } else if eyeY > mouthY + 2 { downN += 1 }
            if k[0].x > k[1].x + 2 { mirrorN += 1 }
        }
        let orientInfo = "；方向自检=眼上\(upN)/眼下\(downN)/左右反\(mirrorN)"
        // v6.7.7：统一五点几何校验——白墙/窗帘/桌面/黑暗区域产生的误检框
        // 大多关键点排布异常，在此过滤（真脸几乎不受影响，离线已验证）
        // v6.7.8：同时拦巨框（画面短边×maxSideFactor，见 geometryOK 注释；
        // 教室 0.35 / 证件照导入 2.0，由调用方按场景传入）
        let maxSide = min(contentW, contentH) * maxSideFactor
        let kept = faces.filter { Self.geometryOK($0, maxSide: maxSide) }
        let geoInfo = kept.count == faces.count ? "" : "；几何校验拦\(faces.count - kept.count)"
        setDebug("[v6.7.24] 候选 \(allScores.count) 个，NMS 后 \(faces.count) 张脸，最高分 \(String(format: "%.3f", allScores.max() ?? 0))（输入 \(Int(contentW))x\(Int(contentH)) 缩放 \(String(format: "%.2f", scale))；推理=\(String(format: "%.0f", inferMs))ms\(rawInfo)；三层最高=\(layerMaxOK)\(orientInfo)\(geoInfo)；\(canvasInfo)；\(tensorInfo)；\(modelInfo)）")
        return kept
    }

    /// 相机路径每帧都调用：只有诊断内容变化时才打印，避免刷屏
    private func setDebug(_ msg: String) {
        if msg != debugStatus {
            debugStatus = msg
            print("[SCRFD-v6.7.24] \(msg)")
        } else {
            debugStatus = msg
        }
    }

    // MARK: - 工具

    /// 整批提取为 [Float]：stride 安全（设备 NN 输出可能存在行对齐填充，
    /// 不能假设内存连续）；连续时走快速路径，Float16 用 vImage 转换
    private static func floatArray(_ a: MLMultiArray) -> [Float] {
        let count = a.count
        // 检查是否紧密连续（row-major，无填充）
        var contiguous = true
        var expect = 1
        for d in stride(from: a.shape.count - 1, through: 0, by: -1) {
            if a.strides[d].intValue != expect { contiguous = false; break }
            expect *= a.shape[d].intValue
        }
        if contiguous {
            if a.dataType == .float32 {
                let ptr = a.dataPointer.bindMemory(to: Float.self, capacity: count)
                return Array(UnsafeBufferPointer(start: ptr, count: count))
            }
            var out = [Float](repeating: 0, count: count)
            var src = vImage_Buffer(data: a.dataPointer, height: 1,
                                    width: vImagePixelCount(count), rowBytes: count * 2)
            out.withUnsafeMutableBytes { dstPtr in
                var dst = vImage_Buffer(data: dstPtr.baseAddress!, height: 1,
                                        width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
            return out
        }
        // 非连续：按逻辑下标逐元素读取（MLMultiArray 下标内部处理 strides）
        let dims = a.shape.count
        let cols = max(1, a.shape[dims - 1].intValue)
        let rows = count / cols
        var out = [Float](repeating: 0, count: count)
        for r in 0..<rows {
            for c in 0..<cols {
                let idx: [NSNumber]
                switch dims {
                case 1:  idx = [NSNumber(value: r * cols + c)]
                case 2:  idx = [NSNumber(value: r), NSNumber(value: c)]
                default: idx = [0, NSNumber(value: r), NSNumber(value: c)]   // [1,N,C]
                }
                out[r * cols + c] = a[idx].floatValue
            }
        }
        return out
    }

    private func iou(_ a: [Float], _ b: [Float]) -> Float {
        let x1 = max(a[0], b[0]), y1 = max(a[1], b[1])
        let x2 = min(a[2], b[2]), y2 = min(a[3], b[3])
        let inter = max(0, x2 - x1) * max(0, y2 - y1)
        let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return union > 0 ? inter / union : 0
    }
}

/// BGRA 像素缓冲 → NCHW fp32 张量，逐通道 (x-127.5)/128 归一化（RGB 顺序）。
/// 逐行 vDSP 提取通道（兼容任意 rowBytes 对齐）+ vDSP 标量仿射，全部基本原语。
/// 检测与识别模型共用：模型输入均为张量（不经 Core ML 图像输入的运行时转换，
/// 规避其对图像像素值域的不透明处理——设备实测该路径会把输入压成常数）。
nonisolated enum PixelTensor {
    static func make(from pb: CVPixelBuffer, size: Int) -> MLMultiArray? {
        guard let arr = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?
            .assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let planeCount = size * size
        let dstBase = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * planeCount)
        var scale = Float(1.0 / 128.0)
        var offset = Float(-127.5 / 128.0)
        // BGRA 内存字节序：B=0, G=1, R=2；模型通道序：R=0, G=1, B=2
        // 逐行 vDSP 提取（兼容任意 rowBytes 对齐），再整平面做 (x-127.5)/128
        let byteToChannel = [(2, 0), (1, 1), (0, 2)]
        for (byteOffset, ch) in byteToChannel {
            let dst = dstBase + ch * planeCount
            for row in 0..<size {
                vDSP_vfltu8(base + row * rowBytes + byteOffset, 4,
                            dst + row * size, 1, vDSP_Length(size))
            }
            vDSP_vsmsa(dst, 1, &scale, &offset, dst, 1, vDSP_Length(planeCount))
        }
        return arr
    }

    /// 抽样统计（诊断用）：均值/最小/最大
    static func sampleStats(_ arr: MLMultiArray) -> (mean: Float, min: Float, max: Float) {
        let n = arr.count
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
        var sum = 0.0, lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        var i = 0
        let step = max(1, n / 2048)
        while i < n {
            let v = ptr[i]
            sum += Double(v); lo = min(lo, v); hi = max(hi, v)
            i += step
        }
        let cnt = Double((n + step - 1) / step)
        return (Float(sum / cnt), lo, hi)
    }
}
