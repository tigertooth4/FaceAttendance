import CoreGraphics
import CoreImage
import UIKit

/// 人脸五点对齐：SCRFD 关键点 → ArcFace 112x112 标准模板
/// 纯几何/位图运算，类型整体非隔离（可在任意队列调用）。
nonisolated enum FaceAligner {

    /// ArcFace 标准模板（左/右眼角、鼻尖、左/右嘴角，观察者视角）
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// 由 5 组对应点估计相似变换（Umeyama 闭式解）。
    /// 返回 CGAffineTransform，满足 dst ≈ transform applied to src。
    static func similarityTransform(src: [CGPoint], dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == 5, dst.count == 5 else { return nil }
        var mxS = CGPoint.zero, mxD = CGPoint.zero
        for i in 0..<5 { mxS.x += src[i].x; mxS.y += src[i].y; mxD.x += dst[i].x; mxD.y += dst[i].y }
        mxS.x /= 5; mxS.y /= 5; mxD.x /= 5; mxD.y /= 5

        // 复数域最小二乘：a+bi = Σ(d)·conj(s) / Σ|s|²
        var numRe = 0.0, numIm = 0.0, den = 0.0
        for i in 0..<5 {
            let sx = src[i].x - mxS.x, sy = src[i].y - mxS.y
            let dx = dst[i].x - mxD.x, dy = dst[i].y - mxD.y
            numRe += dx * sx + dy * sy
            numIm += dy * sx - dx * sy
            den += sx * sx + sy * sy
        }
        guard den > 1e-8 else { return nil }
        let a = numRe / den, b = numIm / den
        // x' = a·x - b·y + tx ; y' = b·x + a·y + ty
        let tx = mxD.x - (a * mxS.x - b * mxS.y)
        let ty = mxD.y - (b * mxS.x + a * mxS.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// 把整张图按 transform 绘制进 112x112 的 BGRA 像素缓冲。
    /// transform 将图像坐标映射到 112 模板坐标。
    static func alignedPixelBuffer(cgImage: CGImage,
                                   transform: CGAffineTransform) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 112, 112,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // v6.6 修复：premultipliedFirst 必须显式配 byteOrder32Little——单独使用时
        // CG 按大端字（内存 ARGB）写入，缓冲实为 32BGRA，PixelTensor 按 BGRA 读，
        // 导致 B 通道被 alpha(255) 顶掉、R/G 错位（识别因建库/现场同遭扭曲而自洽，
        // 所以症状隐蔽；修复后特征分布才与参考实现一致，需重导花名册重建特征库）
        let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: 112, height: 112, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: colorSpace,
                                  bitmapInfo: bgraInfo)
        else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: 112, height: 112))
        // v6.7.5：弃用 Quartz 变换绘制，改手写逐像素双线性 pull-warp。
        // 原因：v6.7.4 设备实测——自检通过、检测框准确、库特征仍塌陷，
        // 对齐块落盘显示采样位置/缩放错误（百叶窗/门框/半张脸），
        // 而离线同变换 cv2.warpAffine 结果完全正确。Quartz 的
        // concatenate+draw 在大平移+高插值档位下的采样行为无法核验，
        // 手写 warp 与 cv2.warpAffine 逐像素等价（逆变换拉回采样、
        // 越界补黑），把最后一块黑盒变成白盒。
        pullWarpBilinear(cgImage: cgImage, transform: transform, into: base,
                         bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return buffer
    }

    /// pull-warp 源图铺平缓存（线程安全，单条目：相机帧每帧换对象自动失效）
    private static let flatLock = NSLock()
    nonisolated(unsafe) private static var flatCache:
        (id: ObjectIdentifier, w: Int, h: Int, buf: [UInt8])?

    /// 逐像素双线性 pull-warp：对 112x112 输出缓冲的每个像素 q，
    /// 用 transform（图像坐标→112 坐标）的逆映射求源点 p=M⁻¹(q)，
    /// 在源图（恒等绘制的 BGRA 位图，top-down，与画布/自检同一安全路径）
    /// 上做双线性插值；源点越界补黑——与 cv2.warpAffine 默认边界一致。
    private static func pullWarpBilinear(cgImage: CGImage,
                                         transform m: CGAffineTransform,
                                         into dst: UnsafeMutableRawPointer,
                                         bytesPerRow dstRowBytes: Int) {
        let sw = cgImage.width, sh = cgImage.height
        guard sw > 0, sh > 0 else { return }
        // 源图 1:1 恒等绘制到连续 BGRA 缓冲（v6.7 已验证：恒等绘制即 top-down）。
        // 照片签到同一 cg 连续 warp 数十张脸：单条目缓存避免重复铺平大图。
        let srcRowBytes = sw * 4
        let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        flatLock.lock()
        var src: [UInt8]
        if let c = flatCache, c.id == ObjectIdentifier(cgImage),
           c.w == sw, c.h == sh {
            src = c.buf
            flatLock.unlock()
        } else {
            flatLock.unlock()
            var buf = [UInt8](repeating: 0, count: srcRowBytes * sh)
            buf.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress,
                      let c = CGContext(data: base, width: sw, height: sh,
                                        bitsPerComponent: 8, bytesPerRow: srcRowBytes,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: bgraInfo) else { return }
                c.draw(cgImage, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            }
            flatLock.lock()
            flatCache = (ObjectIdentifier(cgImage), sw, sh, buf)
            flatLock.unlock()
            src = buf
        }
        // M⁻¹：112 输出坐标 → 源图坐标
        let inv = m.inverted()
        let ia = Float(inv.a), ib = Float(inv.b)
        let ic = Float(inv.c), id_ = Float(inv.d)
        let itx = Float(inv.tx), ity = Float(inv.ty)
        src.withUnsafeBytes { sptr in
            guard let sb = sptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else { return }
            let db = dst.assumingMemoryBound(to: UInt8.self)
            for v in 0..<112 {
                let rowBase = v * dstRowBytes
                // 源点 = inv · (u, v)
                let fv = Float(v)
                let baseX = ic * fv + itx
                let baseY = id_ * fv + ity
                for u in 0..<112 {
                    let x = ia * Float(u) + baseX
                    let y = ib * Float(u) + baseY
                    let dp = db + rowBase + u * 4
                    // 双线性需要 [x0, x0+1]×[y0, y0+1] 全部在图内，否则补黑
                    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
                    if x0 < 0 || y0 < 0 || x0 + 1 >= sw || y0 + 1 >= sh {
                        dp[0] = 0; dp[1] = 0; dp[2] = 0; dp[3] = 255
                        continue
                    }
                    let fx = x - Float(x0), fy = y - Float(y0)
                    let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                    let w01 = (1 - fx) * fy, w11 = fx * fy
                    let p00 = sb + y0 * srcRowBytes + x0 * 4
                    let p10 = p00 + 4
                    let p01 = p00 + srcRowBytes
                    let p11 = p01 + 4
                    for ch in 0..<3 {
                        let val = w00 * Float(p00[ch]) + w10 * Float(p10[ch])
                                + w01 * Float(p01[ch]) + w11 * Float(p11[ch])
                        dp[ch] = UInt8(clamping: Int(val + 0.5))
                    }
                    dp[3] = 255
                }
            }
        }
    }

    /// v6.7.4 诊断：把 112x112 对齐块原样存成 PNG（exports/对齐块_<tag>.png）。
    /// 这是识别模型真正"看到"的图——歪/错位/颠倒/糊在这里一目了然。
    /// 返回文件 URL，便于加入照片签到的分享列表带出设备。
    /// v6.7.8：into 参数——照片通路把本场诊断图直接写进当次标注目录，
    /// 不再经 exports 顶层中转（避免下一场签到被目录扫描重复带出）；
    /// 相机/导入通路不传，仍落 exports 顶层，等下一次照片签到统一
    /// 移动接管（见 PhotoAttendanceView.processOne idx==0）
    /// v6.7.9：对齐块平均饱和度（每 2 像素采样）——"这是不是一张脸"的
    /// 内容级判据。离线实测：木纹墙/天花板条纹块对齐后 0.076–0.145，
    /// 真人脸（含暗光小脸 41 张）最低 0.171；0.15 是带双边裕量的分界。
    /// 缓冲为 32BGRA（本类 alignedPixelBuffer 产物）。
    static func meanSaturation(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 1 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var sum: Float = 0, n: Float = 0
        var y = 0
        while y < h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < w {
                let p = row.advanced(by: x * 4)
                let b = Float(p[0]), g = Float(p[1]), r = Float(p[2])
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                if mx > 8 { sum += (mx - mn) / mx }
                n += 1
                x += 2
            }
            y += 2
        }
        return n > 0 ? sum / n : 1
    }

    /// v6.7.10：任意框区的平均饱和度（正立图坐标，缩采样到 32×32 计算，
    /// 一轮 40 框也只花 ~20ms）。与 meanSaturation(_ pb:) 同一信号，用在
    /// 更靠前的位置：显示层立即隐藏低饱和误检框（墙/桌椅/天花板），识别
    /// 选择同步跳过——不必等识别端两轮失败才判杂波。
    static func meanSaturation(cgImage: CGImage, rect: CGRect) -> Float {
        let r = rect.intersection(CGRect(x: 0, y: 0,
                                         width: cgImage.width, height: cgImage.height))
        guard !r.isNull, r.width >= 4, r.height >= 4,
              let crop = cgImage.cropping(to: r) else { return 1 }
        var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &buf, width: 32, height: 32,
                                  bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bgraInfo) else { return 1 }
        ctx.interpolationQuality = .low
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        var sum: Float = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let b = Float(buf[i]), g = Float(buf[i + 1]), rr = Float(buf[i + 2])
            let mx = max(rr, max(g, b)), mn = min(rr, min(g, b))
            if mx > 8 { sum += (mx - mn) / mx }
        }
        return sum / (32 * 32)
    }

    static func dumpAlignedCrop(_ pb: CVPixelBuffer, tag: String,
                                into destDir: URL? = nil) -> URL? {
        // v6.7.31：调试转储总闸（与 SCRFDDetector.debugArtifactsEnabled 同键，
        // 照片签到页「调试模式」开关控制）——关闭时所有对齐块转储直接为空操作，
        // 场次文件夹只留 原图/标注图/Excel
        guard SCRFDDetector.debugArtifactsEnabled else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bgraInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bgraInfo),
              let img = ctx.makeImage(),
              let data = UIImage(cgImage: img).pngData()
        else { return nil }
        let dir = destDir ?? FileManager.default.urls(for: .documentDirectory,
                                                      in: .userDomainMask).first!
            .appendingPathComponent("exports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = tag.components(separatedBy:
            CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined()
        let url = dir.appendingPathComponent("对齐块_\(safe).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
