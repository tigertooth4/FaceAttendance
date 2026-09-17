import SwiftUI
import AVFoundation

/// 相机预览 + 人脸标签层 + 手势（捏合变焦 / 点击修正）。
/// 人脸框为正立画面像素坐标（原点左上），与预览层方向天然一致——横竖屏切换无需额外转换。
struct CameraView: UIViewRepresentable {

    @ObservedObject var engine: AttendanceEngine
    var onTapOverlay: (FaceOverlay) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = engine.session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.applyOrientation()
        }

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.onPinch(_:)))
        v.addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.onTap(_:)))
        v.addGestureRecognizer(tap)
        context.coordinator.view = v
        context.coordinator.applyOrientation()   // 初始方向
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.engine = engine
        context.coordinator.onTapOverlay = onTapOverlay
        context.coordinator.applyOrientation()
        context.coordinator.updateLabels(engine.overlays)
    }

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    // MARK: - 预览 View

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()   // 界面旋转/尺寸变化时重设方向
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var view: PreviewView?
        var engine: AttendanceEngine
        var onTapOverlay: (FaceOverlay) -> Void = { _ in }
        private var labelLayers: [Int: CALayer] = [:]   // trackId → 标签层
        private var baseZoom: CGFloat = 1
        private var orientationObserver: NSObjectProtocol?

        init(engine: AttendanceEngine) {
            self.engine = engine
            super.init()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    // 设备转动但界面被系统锁定时不改变预览方向（与界面保持一致）
                    self?.applyOrientation()
                }
        }

        deinit {
            if let o = orientationObserver {
                NotificationCenter.default.removeObserver(o)
            }
        }

        /// 当前界面方向 → 缓冲转正角度（与检测坐标系使用同一映射，框永远对齐预览）
        private func currentRotationAngle() -> CGFloat {
            // 优先取界面方向：App 实际怎么转，预览就怎么转
            if let scene = view?.window?.windowScene {
                let io: UIInterfaceOrientation
                if #available(iOS 26.0, *) {
                    io = scene.effectiveGeometry.interfaceOrientation
                } else {
                    io = scene.interfaceOrientation
                }
                switch io {
                case .portrait:           return 90
                case .portraitUpsideDown: return 270
                // 界面 landscapeLeft = 设备 landscapeRight（映射相反）
                case .landscapeLeft:      return 0
                case .landscapeRight:     return 180
                default: break
                }
            }
            // 回退：设备方向
            switch UIDevice.current.orientation {
            case .landscapeLeft:       return 180
            case .landscapeRight:      return 0
            case .portraitUpsideDown:  return 270
            default:                   return 90
            }
        }

        /// 方向变化：同步预览层连接角度 + 通知引擎调整检测坐标系
        func applyOrientation() {
            let interfaceAngle = currentRotationAngle()
            engine.setOrientationAngle(interfaceAngle)
            // v6.7.6 定案：预览层【永远】只按界面方向设置 videoRotationAngle——
            // 这是 AVFoundation 自己的显示通路，历届版本肉眼验证正确。
            // v6.7.3 曾把检测自校准的角度套到预览层（calibratedPreviewAngle），
            // 但检测画布的转正常量与预览旋转角是两套语义（设备实测相差 180°）：
            // 校准锁定 270° 时预览被转成倒置，框随之整体错位——这正是
            // "扫描时人脸框位置不对"的直接根因。检测方向由引擎自校准保证，
            // 预览方向由界面方向保证，二者各自正确即坐标一致，无需互相同步。
            let angle = interfaceAngle
            guard let view, let conn = view.previewLayer.connection else { return }
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            } else {
                let vo: AVCaptureVideoOrientation =
                    angle == 0 ? .landscapeRight : angle == 180 ? .landscapeLeft :
                    angle == 270 ? .portraitUpsideDown : .portrait
                if conn.isVideoOrientationSupported { conn.videoOrientation = vo }
            }
        }

        @objc func onPinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                if let dev = (engine.session.inputs.first as? AVCaptureDeviceInput)?.device {
                    baseZoom = dev.videoZoomFactor
                }
            case .changed:
                engine.setZoom(baseZoom * g.scale)
            default: break
            }
        }

        @objc func onTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let point = g.location(in: view)
            for o in engine.overlays {
                let rect = viewRect(for: o.rect, in: view)
                // 命中检测：框本体 + 上方标签区域
                let hitArea = rect.insetBy(dx: -10, dy: -10)
                    .union(CGRect(x: rect.minX, y: rect.minY - 34,
                                  width: max(rect.width, 90), height: 34))
                if hitArea.contains(point) {
                    onTapOverlay(o)
                    return
                }
            }
        }

        /// 正立画面像素坐标（原点左上）→ 预览视图坐标（aspectFill 裁切）
        private func viewRect(for r: CGRect, in view: UIView) -> CGRect {
            let img = engine.orientedImageSize
            guard img.width > 0, img.height > 0, view.bounds.width > 0 else { return .zero }
            let scale = max(view.bounds.width / img.width, view.bounds.height / img.height)
            let dispW = img.width * scale, dispH = img.height * scale
            let offX = (view.bounds.width - dispW) / 2
            let offY = (view.bounds.height - dispH) / 2
            return CGRect(x: offX + r.minX * scale,
                          y: offY + r.minY * scale,
                          width: r.width * scale,
                          height: r.height * scale)
        }

        func updateLabels(_ overlays: [FaceOverlay]) {
            guard let view else { return }
            // 关键：禁用 CALayer 隐式动画，否则每次位置更新都会做 0.25s 补间动画，
            // 更新频率高于动画时长时标签就会一直"漂移/乱跑"
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let layer = view.previewLayer
            var seen = Set<Int>()

            for o in overlays {
                seen.insert(o.id)
                let rect = viewRect(for: o.rect, in: view)

                let container: CALayer
                if let l = labelLayers[o.id] {
                    container = l
                } else {
                    container = CALayer()
                    let text = CATextLayer()
                    text.name = "text"
                    text.fontSize = 13
                    text.alignmentMode = .center
                    text.contentsScale = view.traitCollection.displayScale
                    text.isWrapped = false
                    container.addSublayer(text)
                    layer.addSublayer(container)
                    labelLayers[o.id] = container
                }

                let color: UIColor
                switch o.level {
                case .confirmed: color = .systemGreen
                case .uncertain: color = .systemOrange
                case .unknown:   color = .systemRed
                }

                container.frame = rect
                container.borderColor = color.cgColor
                container.borderWidth = 2
                container.cornerRadius = 4

                if let text = container.sublayers?.first(where: { $0.name == "text" }) as? CATextLayer {
                    text.string = o.label
                    text.foregroundColor = UIColor.white.cgColor
                    text.backgroundColor = color.cgColor
                    let w = max(rect.width, 88)
                    text.frame = CGRect(x: (rect.width - w) / 2, y: -28, width: w, height: 24)
                }
            }

            // 移除消失的跟踪目标
            for (id, l) in labelLayers where !seen.contains(id) {
                l.removeFromSuperlayer()
                labelLayers.removeValue(forKey: id)
            }
        }
    }
}
