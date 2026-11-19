import AVFoundation
import os
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

    /// Phase 2 diagnostic capture source (research/11-phase2-capture.md). Release builds always use A.
    enum Mode: String, CaseIterable, Identifiable {
        case bayer = "A Bayer 12MP −1EV", bayer0 = "B Bayer 12MP 0EV", proRAW12 = "C ProRAW 12MP", proRAW48 = "D ProRAW 48MP"
        var id: String { rawValue }
        var bias: Float { self == .bayer ? -Float(Look.rawCompensation) : 0 }
        var proRAW: Bool { self == .proRAW12 || self == .proRAW48 }
    }

    let session = AVCaptureSession()
    @Published private(set) var stops: [Stop] = []      // back lenses
    @Published private(set) var front: Stop?
    @Published private(set) var current: Stop?
    @Published private(set) var busy = false
    @Published private(set) var flashAvailable = false
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
    private var _crop = 1.0 // current stop's crop, read by the video queue
    /// Viewfinder frame size, long side in pixels: about a phone screen's 3:4 area (1206–1320 pt wide × 3).
    /// Was 900, then upscaled ~2× to the screen (4× at the 2× stop), which read as out of focus on every lens but 4×.
    private static let previewSide: CGFloat = 1920
    private var _mode = Mode.bayer
    /// Applied to the output before the session starts (and on lens change). Changing it later reconfigures once.
    var mode: Mode {
        get { filterLock.withLock { _mode } }
        set {
            filterLock.withLock { _mode = newValue }
            queue.async {
                guard let stop = self.active else { return }
                self.session.beginConfiguration()
                self.configureRaw(stop.device)
                self.session.commitConfiguration()
                self.setBias(stop.device)
                self.output.setPreparedPhotoSettingsArray([self.makeSettings(stop)])
            }
        }
    }
    private var pressedAt = Date()
    private var active: Stop? // camera queue's copy of `current`
    private var defaultDims: CMVideoDimensions? // the output's size before any mode changed it
    /// Skip filtering viewfinder frames (gallery/editor open on top): it competed with the editor for the GPU.
    var paused: Bool {
        get { filterLock.withLock { _paused } }
        set { filterLock.withLock { _paused = newValue } }
    }
    private var frameCount = 0
    private var analysis: Look.Analysis?

    func start(preferred: String, mode: Mode = .bayer) {
        filterLock.withLock { _mode = mode }
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

    /// `flash`: the LED, for After Hours-style shots (doc §5.3: flash is a capture feature, not a look).
    func capture(flash: Bool = false) {
        queue.async {
            guard let stop = self.current else { return }
            DispatchQueue.main.async { self.busy = true }
            self.pressedAt = Date()
            self.shoot(stop, flash: flash)
        }
    }

    /// The device zoom is never changed: Bayer RAW must be shot at zoom 1.0 (a zoomed RAW decodes purple and crosshatched).
    /// The 2× stop is shot at 1× and center-cropped at develop.
    private func shoot(_ stop: Stop, flash: Bool) {
        let settings = makeSettings(stop)
        if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let conn = output.connection(with: .video) {
            if let angle = rotation?.videoRotationAngleForHorizonLevelCapture, conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = stop.isFront }
        }
        pendingCrop = stop.crop
        pendingFilter = filter
        output.capturePhoto(with: settings, delegate: self)
    }

    /// One RAW request for the current mode. Also used to pre-allocate the pipeline (setPreparedPhotoSettingsArray),
    /// so the first shot after a mode/lens change doesn't pay setup time (WWDC26 304).
    private func makeSettings(_ stop: Stop) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        let mode = self.mode
        let formats = output.availableRawPhotoPixelFormatTypes
        let bayer = formats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let proRAW = formats.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        if let raw = mode.proRAW ? (proRAW ?? bayer) : (bayer ?? proRAW) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(raw) {
                // AVFoundation throws on a request above what the output was configured for, so only ever ask for exactly
                // the output's own values: priority = its max (.quality in C/D: fusion; WWDC21 10160), and a size only in D,
                // where configureRaw set the output to a size this format lists. Everything else stays at defaults.
                if mode.proRAW {
                    settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
                    if mode == .proRAW48 { settings.maxPhotoDimensions = output.maxPhotoDimensions }
                }
            }
            if mode.proRAW != AVCapturePhotoOutput.isAppleProRAWPixelFormat(raw) {
                Self.log.error("fallback: \(mode.rawValue, privacy: .public) unavailable on \(stop.label, privacy: .public), capturing \(Self.fourCC(raw), privacy: .public)")
            } // Bayer: left at defaults (binned 12 MP), as before Phase 2
            Self.log.info("request \(mode.rawValue, privacy: .public) \(stop.label, privacy: .public) fmt=\(Self.fourCC(raw), privacy: .public) max=\(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height) prio=\(settings.photoQualityPrioritization.rawValue) bias=\(stop.device.exposureTargetBias)")
        } else { // ponytail: only phones with neither Bayer RAW nor ProRAW on this camera land here
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            settings.photoQualityPrioritization = .balanced
        }
        return settings
    }

    func focus(at point: CGPoint) {
        queue.async {
            guard let d = self.input?.device, (try? d.lockForConfiguration()) != nil else { return }
            // continuous at the tapped point: .autoFocus focused once and then stayed locked until a lens change,
            // so anything that moved afterwards was blurry
            // the 2× stop shows a center crop: map the tapped point from the crop back to the full sensor frame
            let k = self.filterLock.withLock { self._crop }
            let point = CGPoint(x: 0.5 + (point.x - 0.5) / k, y: 0.5 + (point.y - 0.5) / k)
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = point
                d.focusMode = d.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
            }
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
            configureRaw(stop.device)
            session.commitConfiguration()
            // after commit, on the connection that actually runs: upright, and mirrored like a mirror for selfies.
            // (Set inside the configuration, the selfie camera's frames arrived unrotated.)
            if let c = video.connection(with: .video) {
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = stop.isFront }
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            }
            analysis = nil

            let d = stop.device
            if (try? d.lockForConfiguration()) != nil {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            }
            setBias(d)
            rotation = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
        }
        // 2× blur: under the .photo preset the video output sends preview-sized frames (~screen size), and the 2× stop
        // center-crops them, leaving ~half the screen's pixels to upscale. Full-resolution frames only there (1×/4× don't crop).
        if video.deliversPreviewSizedOutputBuffers == (stop.crop > 1) {
            session.beginConfiguration()
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = stop.crop <= 1
            session.commitConfiguration()
            let vs = video.videoSettings ?? [:]
            Self.log.info("viewfinder frames \(String(describing: vs[kCVPixelBufferWidthKey as String] ?? "?"), privacy: .public)x\(String(describing: vs[kCVPixelBufferHeightKey as String] ?? "?"), privacy: .public) previewSized=\(self.video.deliversPreviewSizedOutputBuffers)")
        }
        active = stop
        filterLock.withLock { _crop = stop.crop }
        output.setPreparedPhotoSettingsArray([makeSettings(stop)])
        let flash = output.supportedFlashModes.contains(.on)
        DispatchQueue.main.async { self.current = stop; self.flashAvailable = flash }
    }

    /// Bayer RAW is the default source. ProRAW is on only in the ProRAW diagnostic modes, or on cameras without Bayer
    /// (selfie). All of it must be set inside the session configuration, before startRunning (Apple: otherwise a
    /// lengthy pipeline reconfiguration on first capture).
    private func configureRaw(_ d: AVCaptureDevice) {
        let mode = self.mode
        output.isAppleProRAWEnabled = false
        let hasBayer = output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        if output.isAppleProRAWSupported, mode.proRAW || !hasBayer { output.isAppleProRAWEnabled = true }
        let dims = d.activeFormat.supportedMaxPhotoDimensions
        let big = dims.max { $0.width * $0.height < $1.width * $1.height }
        // Mode A must stay exactly the pre-Phase-2 path (untestable on device): size/priority change only in C/D, only
        // to values this format lists, and leaving D restores the output's own default size.
        let fallbackDims = defaultDims ?? output.maxPhotoDimensions
        defaultDims = fallbackDims
        if mode == .proRAW48, output.isAppleProRAWEnabled, let big { output.maxPhotoDimensions = big }
        else if output.maxPhotoDimensions.width != fallbackDims.width, dims.contains(where: { $0.width == fallbackDims.width && $0.height == fallbackDims.height }) {
            output.maxPhotoDimensions = fallbackDims
        }
        if mode.proRAW, output.isAppleProRAWEnabled { output.maxPhotoQualityPrioritization = .quality }
        if mode == .proRAW48, !output.isAppleProRAWEnabled || Int(output.maxPhotoDimensions.width) * Int(output.maxPhotoDimensions.height) < 40_000_000 {
            Self.log.error("fallback: \(mode.rawValue, privacy: .public) no 48 MP ProRAW on \(d.localizedName, privacy: .public), output \(self.output.maxPhotoDimensions.width)x\(self.output.maxPhotoDimensions.height)")
        }
        let f = d.activeFormat.formatDescription.dimensions
        let maxDims = dims.map { "\($0.width)x\($0.height)" }.joined(separator: ",")
        let raws = output.availableRawPhotoPixelFormatTypes.map(Self.fourCC).joined(separator: ",")
        Self.log.info("device \(d.localizedName, privacy: .public) type=\(d.deviceType.rawValue, privacy: .public) format=\(f.width)x\(f.height) maxDims=[\(maxDims, privacy: .public)] proRAWSupported=\(self.output.isAppleProRAWSupported) proRAWEnabled=\(self.output.isAppleProRAWEnabled) raw=[\(raws, privacy: .public)] maxPrio=\(self.output.maxPhotoQualityPrioritization.rawValue) outputMax=\(self.output.maxPhotoDimensions.width)x\(self.output.maxPhotoDimensions.height) mode=\(mode.rawValue, privacy: .public)")
    }

    /// −1 EV in mode A (highlight headroom), 0 otherwise. The viewfinder compensates by the same amount.
    private func setBias(_ d: AVCaptureDevice) {
        guard (try? d.lockForConfiguration()) != nil else { return }
        d.setExposureTargetBias(max(d.minExposureTargetBias, mode.bias))
        d.unlockForConfiguration()
    }

    private static func fourCC(_ t: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: t >> $0) }, encoding: .ascii) ?? "\(t)"
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.error = message; self.busy = false }
    }

    private static let log = Logger(subsystem: "bettercam", category: "capture")

    /// EV100 from a video frame's EXIF attachment (same formula as Look.sceneEV for files); nil if the frame has none.
    private static func sceneEV(_ sb: CMSampleBuffer) -> Double? {
        guard let x = CMGetAttachment(sb, key: kCGImagePropertyExifDictionary as CFString, attachmentModeOut: nil) as? [String: Any],
              let n = x[kCGImagePropertyExifFNumber as String] as? Double, let t = x[kCGImagePropertyExifExposureTime as String] as? Double,
              let iso = (x[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first, n > 0, t > 0, iso > 0 else { return nil }
        return log2(n * n / t) - log2(iso / 100)
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
        // what the sensor actually delivered (doc P0: verify Bayer size per lens; a 2x crop of ~12MP is ~3MP real pixels)
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let dng = photo.metadata[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let dims = photo.isRawPhoto ? photo.resolvedSettings.rawPhotoDimensions : photo.resolvedSettings.photoDimensions
        let mp = Double(dims.width) * Double(dims.height) / (pendingCrop * pendingCrop) / 1e6
        func s(_ v: Any?) -> String { v.map { String(describing: $0).filter { !$0.isWhitespace } } ?? "?" }
        let bias = (exif?[kCGImagePropertyExifExposureBiasValue as String] as? Double) ?? Double(mode.bias)
        let line = [
            "capture", mode.rawValue, current?.label ?? "?", "lens=" + s(exif?[kCGImagePropertyExifLensModel as String]),
            "raw=\(photo.isRawPhoto)", "proRAW=\(photo.isRawPhoto && dng?["CFAPlaneColor"] == nil)",
            "\(dims.width)x\(dims.height)", "crop=\(pendingCrop)", String(format: "%.1fMP", mp),
            "ISO=" + s(exif?[kCGImagePropertyExifISOSpeedRatings as String]), "t=" + s(exif?[kCGImagePropertyExifExposureTime as String]),
            "bias=\(bias)", "baseline=" + s(dng?["BaselineExposure"]), "neutral=" + s(dng?["AsShotNeutral"]),
            "white=" + s(dng?["WhiteLevel"]), "black=" + s(dng?["BlackLevel"]), "bytes=\(data.count)",
            String(format: "latency=%.2fs", Date().timeIntervalSince(pressedAt)), String(format: "mem=%.0fMB", Look.footprintMB()),
            "flash=\(photo.resolvedSettings.isFlashEnabled)",
        ].joined(separator: " ")
        Self.log.info("\(line, privacy: .public)")
        // Phase 4 device test: never let a fallback pass as the requested mode (research/14 §2)
        let isProRAW = photo.isRawPhoto && dng?["CFAPlaneColor"] == nil, raw = Double(dims.width) * Double(dims.height) / 1e6
        var mismatch: String?
        if mode.proRAW, !isProRAW { mismatch = "\(mode.rawValue) requested, got \(photo.isRawPhoto ? "Bayer RAW" : "HEIC") \(dims.width)x\(dims.height)" }
        else if mode == .proRAW48, raw < 40 { mismatch = "\(mode.rawValue) requested, got \(String(format: "%.1f", raw)) MP ProRAW (\(dims.width)x\(dims.height))" }
        else if mode == .proRAW12, raw > 14 { mismatch = "\(mode.rawValue) requested, got \(String(format: "%.1f", raw)) MP" }
        if let mismatch {
            Self.log.error("MISMATCH \(mismatch, privacy: .public)")
            #if DEBUG
            DispatchQueue.main.async { self.error = "Capture mismatch: \(mismatch). Photo saved as captured." }
            #endif
        }
        onCapture?(Shot(data: data, ext: photo.isRawPhoto ? "dng" : "heic", crop: pendingCrop, filter: pendingFilter))
    }

    /// Shutter lag: press → sensor exposure (what the user feels; processing latency is logged at didFinishProcessing).
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        Self.log.info("shutter lag \(Date().timeIntervalSince(self.pressedAt) * 1000, format: .fixed(precision: 0))ms")
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        DispatchQueue.main.async { self.busy = false }
    }

    // MARK: - Live filtered viewfinder

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let onFrame, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var img = CIImage(cvPixelBuffer: pb)
        // the UI is portrait, so a landscape frame means the connection didn't rotate it: turn it upright here
        // (90° clockwise; the selfie camera showed up 90° counterclockwise)
        if img.extent.width > img.extent.height {
            img = img.oriented(.right)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        // 2× stop: crop the full-resolution frame first, so the crop keeps real detail (scaling a small frame up didn't)
        let k = filterLock.withLock { _crop }
        if k > 1 {
            let e = img.extent, w = e.width / k, h = e.height / k
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
        }
        // ponytail: video frames carry Apple's video processing, so the preview is a close approximation of the RAW photo
        let s = min(1, Self.previewSide / max(img.extent.width, img.extent.height))
        var props: [String: Any] = [Look.clipKey: pow(2, -Double(mode.bias))] // 8-bit video white, after the bias gain below
        props[Look.evKey] = Self.sceneEV(sb) // same EV100 the saved photo's EXIF gives: light-dependent looks match the final
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            // frames are underexposed by the RAW bias, like the DNG before decode: restore the same way
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -Double(mode.bias)])
            .settingProperties(props)
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
            // the tap → sensor-point conversion goes through this layer's connection, which was never rotated to portrait,
            // so taps focused on the wrong part of the frame. Portrait like the filtered frames on top (same aspect fill).
            if let c = preview.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            onTap?(preview.captureDevicePointConverted(fromLayerPoint: g.location(in: self)))
        }
    }
}
