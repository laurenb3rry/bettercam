import AVFoundation
import SwiftUI

/// RAW capture: Bayer RAW where the camera has it (no Apple processing), ProRAW otherwise (selfie camera).
/// The viewfinder is the video feed run through the same Look engine as the photo, with the current filter.
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// One zoom button. 2× is the main lens with a center crop applied when developing,
    /// because Bayer RAW requires zoom = 1.0 at capture.
    struct Stop: Identifiable, Equatable {
        let id: String
        let label: String
        let device: AVCaptureDevice
        let crop: Double
        var isFront: Bool { device.position == .front }
        static func == (a: Stop, b: Stop) -> Bool { a.id == b.id }
    }

    struct Shot { let data: Data; let ext: String; let crop: Double; let filter: String }

    let session = AVCaptureSession()
    @Published private(set) var stops: [Stop] = []      // back lenses
    @Published private(set) var front: Stop?
    @Published private(set) var current: Stop?
    @Published private(set) var busy = false
    @Published var error: String?
    var onCapture: ((Shot) -> Void)?
    /// Filtered viewfinder frames (called on the video queue).
    var onFrame: ((CGImage) -> Void)?
    /// Filter id for the live preview and the next capture. Set from the main thread, read on the video queue.
    var filter: String {
        get { filterLock.withLock { _filter } }
        set { filterLock.withLock { _filter = newValue } }
    }

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera")
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var pendingCrop = 1.0
    private var pendingFilter = Filter.all[0].id
    private let video = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let filterLock = NSLock()
    private var _filter = Filter.all[0].id
    private var _paused = false
    /// Skip filtering viewfinder frames (gallery/editor open on top): it competed with the editor for the GPU.
    var paused: Bool {
        get { filterLock.withLock { _paused } }
        set { filterLock.withLock { _paused = newValue } }
    }
    private var frameCount = 0
    private var analysis: Look.Analysis?

    func start(preferred: String) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return self.fail("Camera access is off. Turn it on in Settings › bettercam.") }
            self.queue.async { self.configure(preferred) }
        }
    }

    func select(_ stop: Stop) { queue.async { self.use(stop) } }

    /// Flip between the back camera (back to 1×) and the selfie camera.
    func flip() {
        guard let current else { return }
        if current.isFront {
            if let wide = stops.first(where: { $0.label == "1×" }) ?? stops.first { select(wide) }
        } else if let front {
            select(front)
        }
    }

    func capture() {
        queue.async {
            guard let stop = self.current else { return }
            let settings: AVCapturePhotoSettings
            let formats = self.output.availableRawPhotoPixelFormatTypes
            if let raw = formats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
                ?? formats.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            } else { // ponytail: only phones with neither Bayer RAW nor ProRAW on this camera land here
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                settings.photoQualityPrioritization = .balanced
            }
            if let conn = self.output.connection(with: .video) {
                if let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture, conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
                if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = stop.isFront }
            }
            self.pendingCrop = stop.crop
            self.pendingFilter = self.filter
            DispatchQueue.main.async { self.busy = true }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func focus(at point: CGPoint) {
        queue.async {
            guard let d = self.input?.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = point; d.focusMode = .autoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = point; d.exposureMode = .continuousAutoExposure }
            d.unlockForConfiguration()
        }
    }

    // MARK: - Private (camera queue)

    private func configure(_ preferred: String) {
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back
        ).devices
        guard let wide = back.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return fail("No camera found.") }

        var stops: [Stop] = []
        if let uw = back.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
            stops.append(Stop(id: uw.uniqueID, label: "0.5×", device: uw, crop: 1))
        }
        stops.append(Stop(id: wide.uniqueID, label: "1×", device: wide, crop: 1))
        let tele = back.first { $0.deviceType == .builtInTelephotoCamera }
        let teleZoom = tele.map { Self.zoom($0, relativeTo: wide) } ?? 0
        if teleZoom == 0 || teleZoom > 2.5 { // a 2× tele (iPhone 12 Pro) makes the crop stop pointless
            stops.append(Stop(id: wide.uniqueID + "@2", label: "2×", device: wide, crop: 2))
        }
        if let tele { stops.append(Stop(id: tele.uniqueID, label: "\(Int(teleZoom.rounded()))×", device: tele, crop: 1)) }

        let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        let front = frontDevice.map { Stop(id: $0.uniqueID, label: "1×", device: $0, crop: 1) }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(output) { session.addOutput(output) }
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(video) { session.addOutput(video) }
        session.commitConfiguration()

        DispatchQueue.main.async { self.stops = stops; self.front = front }
        use((stops + [front].compactMap { $0 }).first { $0.id == preferred } ?? stops.first { $0.label == "1×" }!)
        session.startRunning()
    }

    private func use(_ stop: Stop) {
        if input?.device != stop.device {
            guard let new = try? AVCaptureDeviceInput(device: stop.device) else { return fail("Couldn't open that camera.") }
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(new) { session.addInput(new); input = new } else if let input { session.addInput(input) }
            // Bayer RAW is the cleanest source. Cameras without it (the selfie camera) fall back to ProRAW:
            // still a RAW DNG, and the look switches off its tone mapping at decode.
            output.isAppleProRAWEnabled = false
            if !output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat),
               output.isAppleProRAWSupported {
                output.isAppleProRAWEnabled = true
            }
            if let c = video.connection(with: .video) { // upright, and mirrored like a mirror for selfies
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = stop.isFront }
            }
            session.commitConfiguration()
            analysis = nil

            let d = stop.device
            if (try? d.lockForConfiguration()) != nil {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                // RAW: underexpose so highlights survive; the look restores brightness under a soft shoulder.
                let bias = -Float(Look.rawCompensation)
                d.setExposureTargetBias(max(d.minExposureTargetBias, bias))
                d.unlockForConfiguration()
            }
            rotation = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
        }
        DispatchQueue.main.async { self.current = stop }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.error = message; self.busy = false }
    }

    private static func zoom(_ d: AVCaptureDevice, relativeTo wide: AVCaptureDevice) -> Double {
        func halfTan(_ x: AVCaptureDevice) -> Double { tan(Double(x.activeFormat.videoFieldOfView) * .pi / 360) }
        return halfTan(wide) / halfTan(d)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return fail(error?.localizedDescription ?? "Capture failed.")
        }
        onCapture?(Shot(data: data, ext: photo.isRawPhoto ? "dng" : "heic", crop: pendingCrop, filter: pendingFilter))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async { self.busy = false }
    }

    // MARK: - Live filtered viewfinder

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let onFrame, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var img = CIImage(cvPixelBuffer: pb)
        // ponytail: video frames carry Apple's video processing, so the preview is a close approximation of the RAW photo
        let s = 900 / max(img.extent.width, img.extent.height)
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            // frames are underexposed by the RAW bias, like the DNG before decode: restore the same way
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: Look.rawCompensation])
        frameCount += 1
        if analysis == nil || frameCount % 15 == 0 { analysis = Look.analyze(img) } // white point + WB, ~2×/s
        let seed = CGPoint(x: .random(in: 0..<4096), y: .random(in: 0..<4096)) // grain must not sit still on screen
        let out = Look.apply(Recipe(filter: filter), to: img, analysis: analysis, grainSeed: seed)
        if let cg = Look.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Look.outputSpace) {
            onFrame(cg)
        }
    }
}

struct PreviewView: UIViewRepresentable {
    let camera: Camera
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.preview.session = camera.session
        v.preview.videoGravity = .resizeAspectFill
        camera.onFrame = { [weak v] cg in
            DispatchQueue.main.async { v?.filtered.image = UIImage(cgImage: cg) }
        }
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) { v.onTap = onTap }

    /// The system preview layer underneath (instant, and does tap-to-focus coordinate math);
    /// the filtered frames on top cover it as soon as they arrive.
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        let filtered = UIImageView()
        var onTap: ((CGPoint) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            filtered.contentMode = .scaleAspectFill
            filtered.clipsToBounds = true
            addSubview(filtered)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            filtered.frame = bounds
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            onTap?(preview.captureDevicePointConverted(fromLayerPoint: g.location(in: self)))
        }
    }
}
