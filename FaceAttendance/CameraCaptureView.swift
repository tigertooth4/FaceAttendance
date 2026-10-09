import SwiftUI
import AVFoundation
import Combine   // ObservableObject/@Published/@StateObject 的定义模块

/// v6.7.15：照片签到内置连拍相机。
/// v6.7.31：拍的照片【不再写入系统相册】——只保存在内存里，点「开始签到」后
/// 由照片签到管线把原图/标注图收进本场次文件夹（历史记录里可导出/分享），
/// 不污染手机照片库；返回或「重拍」即丢弃本组照片。
/// 左上角「<」返回即放弃本组照片（=重新拍照），点「重拍」可不清场退回。
struct CameraCaptureView: View {
    /// 点「开始签到」时回调：整组照片（含 EXIF 的原始数据 + 拍摄时刻）
    var onFinish: ([(data: Data, takenAt: Date?)]) -> Void

    @StateObject private var model = CameraCaptureModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CapturePreviewView(model: model).ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶栏：返回（=放弃本组，重新拍照）｜已拍计数
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    Spacer()
                    if model.count > 0 {
                        Text("已拍 \(model.count) 张")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.black.opacity(0.35), in: Capsule())
                    }
                }
                .padding(.horizontal).padding(.top, 8)

                Spacer()

                if let note = model.note {
                    Text(note)
                        .font(.caption).foregroundStyle(.yellow)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 6)
                }

                // 已拍缩略图条（最右是最新一张）
                if !model.thumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, t in
                                Image(uiImage: t)
                                    .resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipped().cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white.opacity(0.6), lineWidth: 1))
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 64)
                    .padding(.bottom, 8)
                }

                // 底栏：重拍｜快门｜开始签到
                HStack {
                    Button {
                        model.clearAll()
                    } label: {
                        Text("重拍")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(model.count > 0 ? .white : .gray)
                            .frame(width: 64)
                    }
                    .disabled(model.count == 0)

                    Spacer()

                    Button { model.capture() } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                            Circle().fill(.white).frame(width: 58, height: 58)
                        }
                    }

                    Spacer()

                    Button {
                        let photos = model.photos
                        dismiss()
                        onFinish(photos)
                    } label: {
                        Text("开始签到")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(model.count > 0 ? .yellow : .gray)
                            .frame(width: 64)
                    }
                    .disabled(model.count == 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            if model.permissionDenied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("没有相机权限").font(.headline)
                    Text("请到 设置 → FaceAttendance 中允许访问相机")
                        .font(.caption).multilineTextAlignment(.center)
                    Button("返回") { dismiss() }
                        .padding(.top, 4)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
                .padding(32)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - 预览层

/// 纯预览（aspectFill），方向跟随界面；捏合变焦。
private struct CapturePreviewView: UIViewRepresentable {
    let model: CameraCaptureModel

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = model.session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onLayout = { [weak model] in model?.applyPreviewOrientation(v) }
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.onPinch(_:)))
        v.addGestureRecognizer(pinch)
        context.coordinator.view = v
        model.applyPreviewOrientation(v)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        model.applyPreviewOrientation(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject {
        weak var view: PreviewView?
        let model: CameraCaptureModel
        private var baseZoom: CGFloat = 1
        init(model: CameraCaptureModel) { self.model = model }

        @objc func onPinch(_ g: UIPinchGestureRecognizer) {
            guard let dev = model.device else { return }
            switch g.state {
            case .began: baseZoom = dev.videoZoomFactor
            case .changed:
                let z = min(max(baseZoom * g.scale, 1), min(dev.activeFormat.videoMaxZoomFactor, 8))
                try? dev.lockForConfiguration()
                dev.videoZoomFactor = z
                dev.unlockForConfiguration()
            default: break
            }
        }
    }
}

// MARK: - 采集模型

final class CameraCaptureModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.capture.session")
    private(set) var device: AVCaptureDevice?

    @Published private(set) var photos: [(data: Data, takenAt: Date?)] = []
    @Published private(set) var thumbnails: [UIImage] = []
    @Published var note: String?
    @Published var permissionDenied = false
    var count: Int { photos.count }

    /// 当前界面方向对应的缓冲转正角度（拍照时同步给照片连接，保证 EXIF 正确）
    private var interfaceAngle: CGFloat = 90

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.configure() }
                else { DispatchQueue.main.async { self.permissionDenied = true } }
            }
        default:
            DispatchQueue.main.async { self.permissionDenied = true }
        }
    }

    private func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: dev),
                  self.session.canAddInput(input),
                  self.session.canAddOutput(self.photoOutput) else {
                self.session.commitConfiguration()
                print("[拍照-v6.7.31] 相机配置失败")
                return
            }
            self.session.addInput(input)
            self.session.addOutput(self.photoOutput)
            self.device = dev
            // v6.7.17：commit 之后才能 startRunning——旧实现用 defer 把 commit
            // 推迟到函数返回，startRunning 落在 begin/commit 之间直接崩溃
            // （NSGenericException：startRunning may not be called between
            // calls to beginConfiguration and commitConfiguration）
            self.session.commitConfiguration()
            self.session.startRunning()
            print("[拍照-v6.7.31] 连拍相机已启动")
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 预览方向（与 CameraView 同一套界面方向映射）+ 记录角度供拍照连接使用
    func applyPreviewOrientation(_ view: UIView) {
        let angle = Self.currentInterfaceAngle(of: view)
        interfaceAngle = angle
        guard let conn = (view.layer as? AVCaptureVideoPreviewLayer)?.connection else { return }
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        } else {
            let vo: AVCaptureVideoOrientation =
                angle == 0 ? .landscapeRight : angle == 180 ? .landscapeLeft :
                angle == 270 ? .portraitUpsideDown : .portrait
            if conn.isVideoOrientationSupported { conn.videoOrientation = vo }
        }
    }

    private static func currentInterfaceAngle(of view: UIView) -> CGFloat {
        if let scene = view.window?.windowScene {
            let io: UIInterfaceOrientation
            if #available(iOS 26.0, *) {
                io = scene.effectiveGeometry.interfaceOrientation
            } else {
                io = scene.interfaceOrientation
            }
            switch io {
            case .portrait:           return 90
            case .portraitUpsideDown: return 270
            case .landscapeLeft:      return 0    // 界面 landscapeLeft = 设备 landscapeRight
            case .landscapeRight:     return 180
            default: break
            }
        }
        return 90
    }

    func capture() {
        // 拍照连接方向与预览一致——EXIF 方向标记才正确（相册显示与签到管线都靠它）
        if let conn = photoOutput.connection(with: .video) {
            let angle = interfaceAngle
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            } else {
                let vo: AVCaptureVideoOrientation =
                    angle == 0 ? .landscapeRight : angle == 180 ? .landscapeLeft :
                    angle == 270 ? .portraitUpsideDown : .portrait
                if conn.isVideoOrientationSupported { conn.videoOrientation = vo }
            }
        }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func clearAll() {
        photos.removeAll()
        thumbnails.removeAll()
        note = nil
    }

    // MARK: AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            print("[拍照-v6.7.31] 拍摄失败：\(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let takenAt = Date()
        // 缩略图条用小图，避免 12MP 原图直接进 SwiftUI 渲染管线
        var thumb: UIImage? = nil
        if let ui = UIImage(data: data) {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            thumb = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 112),
                                            format: fmt).image { _ in
                let s = max(112 / ui.size.width, 112 / ui.size.height)
                ui.draw(in: CGRect(x: (112 - ui.size.width * s) / 2,
                                   y: (112 - ui.size.height * s) / 2,
                                   width: ui.size.width * s, height: ui.size.height * s))
            }
        }
        DispatchQueue.main.async {
            self.photos.append((data, takenAt))
            if let thumb { self.thumbnails.append(thumb) }
        }
        // v6.7.31：不再写入系统相册（不污染照片库）；原图由照片签到管线
        // 存进本场次文件夹，历史记录中可随时导出/分享
    }
}
