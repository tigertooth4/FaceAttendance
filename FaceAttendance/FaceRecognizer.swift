import CoreML
import Accelerate
import UIKit

/// Core ML 人脸识别器：InsightFace ResNet@WebFace600K（buffalo_l 的 w600k_r50）特征提取 + 特征库比对。
/// 较 MobileFaceNet 识别率大幅提升（实测真脸通过率 84% vs 63%，阈值 0.40 时误判为 0）。
/// v6：与检测器同步改为经典 neuralnetwork 格式（同一条 torch→mlprogram 管线
/// 在 iOS 26 上产出错误结果，已整组弃用）。
/// 类型整体非隔离：识别在串行识别队列执行，MLModel 推理本身线程安全。
nonisolated final class FaceRecognizer {

    static let shared = FaceRecognizer()

    private var model: MLModel?
    private(set) var loadError: String?
    /// 诊断：首次特征统计只打印一次
    private var embLogged = false
    /// 诊断：最近一次特征提取失败的原因（导入时逐人定位用）
    private(set) var lastFailReason: String?
    private var embedError: String?

    private init() {
        guard let url = Bundle.main.url(forResource: "ResNet50Face",
                                        withExtension: "mlmodelc") else {
            loadError = "未找到 ResNet50Face 模型，请确认 ResNet50Face.mlmodel 已加入工程 Target"
            return
        }
        let config = MLModelConfiguration()
        // v6.7.3：R50 强制 CPU 运行时（BNNS fp32），与 SCRFD 检测器同一选择——
        // 设备实锤：同一 112x112 对齐块，ONNX 参考范数 ≈21（17.4–24.9），
        // 而 ANE 运行时输出范数仅 12.1，特征空间被压缩 → 相似度挤在 0.30–0.40
        // 中间带、匹配聚集到少数学生、人名大面积错配。检测器走 CPU 后与参考
        // 实现候选数完全一致（206/261 vs 159–236），证明 CPU 运行时数值忠实。
        // 112x112 小图 CPU 每张约 10ms，速度无感。
        config.computeUnits = .cpuOnly
        do { model = try MLModel(contentsOf: url, configuration: config) }
        catch { loadError = "模型加载失败: \(error.localizedDescription)" }
        runSelfTest()
    }

    /// v6.7.3 数值自检：固定合成图案过一遍 R50，与 ONNX 参考值比对。
    /// 设备运行时（ANE/fp16/格式转换）任何算子级偏差都会立刻暴露，
    /// 不再靠"识别率惨淡"这种滞后症状反推。参考值由 w600k_r50.onnx 离线算出。
    private func runSelfTest() {
        guard model != nil else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 112, 112,
                                  kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess,
              let buffer = pb else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for r in 0..<112 {
                for c in 0..<112 {
                    let px = base + r * rowBytes + c * 4
                    for ch in 0..<3 {   // B,G,R 三通道同一公式，与离线复刻一致
                        px[ch] = UInt8((r * 31 + c * 17 + ch * 13) % 256)
                    }
                    px[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard let feat = embed(buffer) else { return }
        // 自检期望（w600k_r50.onnx fp32 离线算出）：该合成图案原始范数=12.001，
        // 归一化后前 3 维 = -1.0954/-0.5911/0.6747 ÷ 12.001。
        // embed 返回的是归一化特征，这里校验前 3 维；原始范数由 embed 内日志打印对照
        let exp: [Float] = [-0.09128, -0.04925, 0.05622]
        let dev = zip(feat, exp).map { abs($0 - $1) }.max() ?? 9
        let ok = dev < 0.01
        runtimeDeviated = !ok
        print(String(format:
            "[R50自检-v6.7.3] 前3维=%.4f/%.4f/%.4f 期望≈%.4f/%.4f/%.4f 最大偏差=%.4f → %@",
            feat[0], feat[1], feat[2], exp[0], exp[1], exp[2], dev,
            ok ? "通过（运行时与参考一致）" : "【偏差超限】R50 运行时输出与参考实现不符，识别结果不可信！"))
    }

    /// 数值自检结果：true = 设备运行时输出偏离参考实现（识别不可信）
    private(set) var runtimeDeviated = false

    /// 输入 112x112 BGRA 像素缓冲（已对齐），输出归一化 512 维特征。
    /// 张量自行构建（(x-127.5)/128 RGB NCHW），不经 Core ML 图像输入的运行时转换。
    /// v6.7.4 诊断：导入/相机产生的对齐块 PNG，照片签到时随分享列表一并带出
    nonisolated(unsafe) static var pendingDumpURLs: [URL] = []

    func embed(_ pixelBuffer: CVPixelBuffer) -> [Float]? {
        embedWithRawNorm(pixelBuffer)?.vec
    }

    /// 嵌入 + 原始范数（归一化前的 L2 范数，是运行时数值健康度的直接探针：
    /// ONNX 参考——合成图案 12.001，证件照 17.4-24.9，课堂脸 20.5-20.8）
    func embedWithRawNorm(_ pixelBuffer: CVPixelBuffer) -> (vec: [Float], rawNorm: Float)? {
        guard let model else { embedError = "模型未加载"; return nil }
        guard let tensor = PixelTensor.make(from: pixelBuffer, size: 112) else {
            embedError = "张量构建失败"
            return nil
        }
        let out: MLFeatureProvider
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["face_input": MLFeatureValue(multiArray: tensor)])
            out = try model.prediction(from: input)
        } catch {
            embedError = "推理失败: \(error.localizedDescription)"
            return nil
        }
        guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
              let arr = out.featureValue(for: name)?.multiArrayValue else {
            embedError = "输出读取失败"
            return nil
        }

        let count = arr.count
        var feat = [Float](repeating: 0, count: count)
        // MLMultiArray 可能是 Float16 或 Float32
        if arr.dataType == .float32 {
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
            feat = Array(UnsafeBufferPointer(start: ptr, count: count))
        } else {
            for i in 0..<count { feat[i] = arr[i].floatValue }
        }
        var norm: Float = 0
        vDSP_svesq(feat, 1, &norm, vDSP_Length(count))  // sum of squares
        norm = sqrt(norm)
        guard norm > 1e-6 else { return nil }
        if !embLogged {
            embLogged = true
            // v6.7.3：首次调用即 runSelfTest 的合成图案——原始范数可直接对照
            // ONNX 参考值 12.001；ANE 运行时（v6.7.2 之前）此处会暴露偏差
            print(String(format: "[R50自检-v6.7.3] 合成图案原始范数=%.3f（ONNX参考=12.001）原始前3维=%.3f/%.3f/%.3f 维度=%d",
                         norm, feat[0], feat[1], feat[2], count))
        }
        var scale = 1 / norm
        vDSP_vsmul(feat, 1, &scale, &feat, 1, vDSP_Length(count))
        return (feat, norm)
    }

    /// 余弦相似度（特征均已归一化）：feat · gallery
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(min(a.count, b.count)))
        return dot
    }

    /// 高质量缩小 CGImage（多尺度兜底用）
    private static func downsampled(_ cg: CGImage, width w: Int, height h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 对整张静态照片做人脸检测 + 对齐 + 特征提取（用于花名册导入）。
    /// 用 SCRFD 关键点（原图全分辨率），充分利用证件照分辨率。
    /// 返回最大人脸的特征；无人脸返回 nil。
    /// v6.7.4 诊断参数：diagTag 非空时打印该学生特征的原始范数；
    /// dumpCrop 为真时把 112x112 对齐块存盘并登记进 pendingDumpURLs
    ///（随下一次照片签到的分享列表带出设备）
    func featureFromPhoto(_ image: UIImage, diagTag: String? = nil,
                          dumpCrop: Bool = false) -> [Float]? {
        // v6.7.14：先按 EXIF 方向归一化位图——UIImage(data:) 只把旋转记在
        // imageOrientation 里，cgImage 仍是原始像素；带旋转标记的证件照会侧躺
        // 入库。实测侧躺提取的特征与正脸图库余弦从 0.90+ 掉到 0.48~0.69，
        // 即便导入"成功"也是劣质底库，签到时必然大面积待确认/认错人。
        // （UIGraphicsImageRenderer 可在任意队列使用；scale 跟随原图，
        //  默认跟随设备 3x 会无谓放大三倍）
        var cg0: CGImage? = image.cgImage
        if image.imageOrientation != .up, let raw = cg0 {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = image.scale
            fmt.opaque = true
            let normalized = UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            if let n = normalized.cgImage {
                print(String(format: "[R50导入-v6.7.30] EXIF 方向=%d 已归一化 %dx%d → %dx%d",
                             image.imageOrientation.rawValue, raw.width, raw.height, n.width, n.height))
                cg0 = n
            }
        }
        guard let cg0 else {
            lastFailReason = "照片解码失败"
            return nil
        }
        // v6.7.13：低分辨率证件照先放大再检测——新花名册实测照片只有
        // 69×78/99×111/199×223，脸仅 33~96px：五点关键点在该尺度回归抖动大，
        // 且嵌入质量差。放大到长边 640 后脸约 300px，检测/对齐都稳。
        // （对原本就清晰的大图无影响——max<640 才触发）
        var cg = cg0
        if max(cg0.width, cg0.height) < 640 {
            let s = 640.0 / CGFloat(max(cg0.width, cg0.height))
            if let up = Self.downsampled(cg0, width: Int(CGFloat(cg0.width) * s),
                                         height: Int(CGFloat(cg0.height) * s)) {
                cg = up
                print(String(format: "[R50导入-v6.7.30] 低分辨率照片 %dx%d → 放大 %dx%d 再检测",
                             cg0.width, cg0.height, cg.width, cg.height))
            }
        }
        // v6.2：导入检测走 CPU 专用实例（BNNS fp32，数值最忠实参考实现，
        // 绕开 ANE 对少数输入的算子级偏差）。
        // v6.7.13：maxSideFactor=2.0——证件照的脸本就占画面 50%+，教室场景的
        // 0.35 巨框上限会把真脸误拦（69×78 照片上限 24px vs 真脸 33×42）
        var face = SCRFDDetector.sharedImport.detect(in: cg, maxSideFactor: 2.0).max(by: {
            $0.box.width * $0.box.height < $1.box.width * $1.box.height
        })
        if face == nil {
            // 低阈值兜底：证件照保证单人正面；少数照片 s32 头得分被设备运行时
            // 异常压低到 0.3 附近（参考实现 0.87+），0.2 兜底 + 几何校验可救回
            if let best = SCRFDDetector.sharedImport.detectBestEffort(in: cg, floor: 0.2,
                                                                      maxSideFactor: 2.0) {
                face = best
                print(String(format: "[R50-v6.2] 低阈值兜底命中 score=%.3f", best.score))
            }
        }
        if face == nil {
            // 多尺度兜底（v6.3）：缩小照片，使大脸从 s32 头区间移入 s16/s8 头区间，
            // 绕开设备运行时对 s32 头的计算偏差（参考实现：0.5× 时 s16 层 0.88）
            for es in [CGFloat(0.5), CGFloat(0.35)] where face == nil {
                let w = Int(CGFloat(cg.width) * es), h = Int(CGFloat(cg.height) * es)
                guard w >= 64, h >= 64,
                      let small = Self.downsampled(cg, width: w, height: h) else { continue }
                var cand = SCRFDDetector.sharedImport.detect(in: small, maxSideFactor: 2.0).max(by: {
                    $0.box.width * $0.box.height < $1.box.width * $1.box.height
                })
                if cand == nil {
                    cand = SCRFDDetector.sharedImport.detectBestEffort(in: small, floor: 0.2,
                                                                       maxSideFactor: 2.0)
                }
                if var f = cand {
                    // 坐标系换算回原图
                    let inv = 1 / es
                    f.box = CGRect(x: f.box.minX * inv, y: f.box.minY * inv,
                                   width: f.box.width * inv, height: f.box.height * inv)
                    f.kps = f.kps.map { CGPoint(x: $0.x * inv, y: $0.y * inv) }
                    face = f
                    print(String(format: "[R50-v6.3] 多尺度兜底命中 缩放=%.2f score=%.3f",
                                 Double(es), f.score))
                }
            }
        }
        guard let face else {
            lastFailReason = "检测无人脸[\(SCRFDDetector.sharedImport.debugStatus)]"
            return nil
        }
        guard let m = FaceAligner.similarityTransform(src: face.kps, dst: FaceAligner.template),
              let pb = FaceAligner.alignedPixelBuffer(cgImage: cg, transform: m)
        else {
            lastFailReason = "人脸对齐失败"
            return nil
        }
        if dumpCrop, let tag = diagTag,
           let url = FaceAligner.dumpAlignedCrop(pb, tag: "导入_\(tag)") {
            FaceRecognizer.pendingDumpURLs.append(url)
        }
        if let tag = diagTag {
            // v6.7.5：kps 数值对拍——与离线参考逐点核对，一锤定音区分
            // “kps 数值坏”与“warp 渲染坏”。格式：kps=(x,y)|... 框=(x,y,w,h)
            let kpStr = face.kps.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) }
                .joined(separator: "|")
            print(String(format: "[R50导入-v6.7.5] %@ 框=(%.0f,%.0f %.0fx%.0f) kps=%@",
                         tag, face.box.minX, face.box.minY,
                         face.box.width, face.box.height, kpStr))
        }
        let result = embedWithRawNorm(pb)
        if let tag = diagTag, let r = result {
            // 参考：证件照原始范数 17.4-24.9；显著偏离即本机运行时数值异常
            print(String(format: "[R50导入-v6.7.5] %@ 原始范数=%.2f（参考17.4-24.9）",
                         tag, r.rawNorm))
        }
        if result == nil {
            lastFailReason = "特征提取失败[\(embedError ?? "未知")]"
        }
        return result?.vec
    }
}
