import AVFoundation
import os
import SwiftUI

/// Bayer by default, with ProRAW options where supported and HEIC on cameras without RAW.
/// The viewfinder is the video feed run through the same Look engine as the photo, with the current filter.
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// One zoom button. 2× is the main lens with a center crop applied when developing (Bayer RAW requires zoom 1.0 at
    /// capture; ProRAW shoots that stop at 48 MP so the crop keeps 12 MP).
    struct Stop: Identifiable, Equatable {
        let id: String
        let label: String
        let device: AVCaptureDevice
        let crop: Double
        var isFront: Bool { device.position == .front }
        static func == (a: Stop, b: Stop) -> Bool { a.id == b.id }
    }

    /// `exposure`: the viewfinder's exposure offset at the press (render-only, becomes the recipe's Exposure slider).
    struct Shot {
        let data: Data; let ext: String; let crop: Double; let filter: String; let exposure: Double
        let preview: PreviewSample?
        let metadata: String
        let canMatch: Bool
        let previewDelay: Double
    }

    struct PreviewSample {
        let input: CIImage?
        let analysis: Look.Analysis
        let pts: Double
        let received: Date
        let generation: Int
        let filter: String
        let exposure: Double
        let metadata: String
        let rendered: CGImage
        var grainSeed: UInt32? = nil
    }

    enum Mode: String, CaseIterable, Identifiable {
        case proRAW12 = "ProRAW 12MP", proRAW48 = "ProRAW 48MP"
        case bayer = "Bayer RAW 12MP", bayerFixed = "Bayer RAW 12MP fixed −1EV"
        var id: String { rawValue }
        var proRAW: Bool { self == .proRAW12 || self == .proRAW48 }
        /// What the app shoots unless the user picked a format (the chip menu, remembered). Bayer: the only source validated
        /// in BetterCam on the phone so far. Becomes .proRAW12 once the device self-test passes (research/15-bettercam-final.md).
        static let standard = Mode.bayer
    }

    let session = AVCaptureSession()
    @Published private(set) var stops: [Stop] = []      // back lenses
    @Published private(set) var front: Stop?
    @Published private(set) var current: Stop?
    @Published private(set) var busy = false            // too many shots still processing: shutter waits
    @Published private(set) var flashAvailable = false
    @Published private(set) var format = ""             // what the next shot will be, e.g. "ProRAW 12"
    @Published private(set) var shutterCount = 0        // bumps at exposure: the UI blinks
    @Published private(set) var permissionDenied = false
    @Published var error: String?
    var onCapture: ((Shot) -> Void)?
    /// Filtered viewfinder frames (called on the video queue).
    var onFrame: ((PreviewSample) -> Void)?
    /// Filter id for the live preview and the next capture. Set from the main thread, read on the video queue.
    var filter: String {
        get { lock.withLock { _filter } }
        set { lock.withLock { _filter = newValue } }
    }
    /// Render exposure offset (EV), shown live and stored in the shot's recipe. Capture exposure is not changed by it.
    var exposure: Double {
        get { lock.withLock { _exposure } }
        set { lock.withLock { _exposure = newValue } }
    }
    /// Skip filtering viewfinder frames (gallery/editor open on top): it competed with the editor for the GPU.
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    var mode: Mode {
        get { lock.withLock { _mode } }
        set {
            lock.withLock { _mode = newValue }
            queue.async {
                guard let stop = self.active else { return }
                self.session.beginConfiguration()
                self.configureRaw(stop.device)
                self.session.commitConfiguration()
                self.prepare(stop)
            }
        }
    }

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera")
    private let video = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "camera.analysis", qos: .utility)
    private let lock = NSLock()
    // lock-protected
    private var _filter = Filter.all[0].id
    private var _exposure = 0.0
    private var _paused = false
    private var grainSeed = UInt32.random(in: .min ... .max)
    private var _crop = 1.0          // current stop's crop, read by the video queue
    private var _mode = Mode.standard
    private var _bias: Float = 0     // exposure target bias in effect; the viewfinder undoes it like decode does
    private var _analysis: Look.Analysis?
    private var generation = 0
    private var shownPreview: PreviewSample?
    private var previewDevice: AVCaptureDevice?
    private var pending: [Int64: Pending] = [:] // per shot, by settings.uniqueID: back-to-back shots can't swap filters
    // camera queue
    private var input: AVCaptureDeviceInput?
    private var active: Stop?
    private var defaultDims: CMVideoDimensions? // the output's size before any mode changed it (Bayer keeps it)
    private var dims12: CMVideoDimensions?      // ProRAW sizes on this lens (nil: not available)
    private var dims48: CMVideoDimensions?
    private var proRAWActive = false
    private var biasVote = 0, biasStreak = 0
    // video queue
    private var frameCount = 0
    private var analyzing = false
    private var trustGeneration = -1
    private var trust = 0.0                  // viewfinder portrait pass strength, ramped (no pop when a person appears)
    private var lastTrusted: Look.Analysis?  // keeps the pass alive through a few uncertain frames instead of flickering

    /// Viewfinder frame size, long side in pixels: about a phone screen's 3:4 area (1206–1320 pt wide × 3).
    private static let previewSide: CGFloat = 1920
    /// Standard captures allowed in flight at once.
    private static let maxInFlight = 3

    private struct Pending {
        let crop: Double, filter: String, exposure: Double, mode: Mode, proRAW: Bool, size48: Bool, label: String
        let pressed: Date
        let preview: PreviewSample?
    }

    func didDisplay(_ sample: PreviewSample) -> Bool {
        lock.withLock {
            guard sample.generation == generation else { return false }
            shownPreview = sample
            return true
        }
    }

    private func resetPreview() {
        lock.withLock {
            generation += 1
            shownPreview = nil
            _analysis = nil
        }
    }

    static let parityDiagnostics = {
        #if DEBUG
        CommandLine.arguments.contains("-preview-parity") || CommandLine.arguments.contains("-selftest")
        #else
        false
        #endif
    }()

    static func videoMetadata(_ buffer: CVPixelBuffer, sb: CMSampleBuffer, device: AVCaptureDevice?, bias: Double) -> String {
        let tags = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
            .map { CVBufferCopyAttachment(buffer, $0, nil).map(String.init(describing:)) ?? "?" }
        let exif = CMGetAttachment(sb, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil)
        let wb = device.map { $0.temperatureAndTintValues(for: $0.deviceWhiteBalanceGains) }
        let gains = device?.deviceWhiteBalanceGains
        return "videoPTS=\(sb.presentationTimeStamp.seconds) \(fourCC(CVPixelBufferGetPixelFormatType(buffer))) " +
            "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) colorTags=\(tags) " +
            "bias=\(bias) deviceISO=\(device?.iso ?? 0) deviceShutter=\(device?.exposureDuration.seconds ?? 0) " +
            "wb=\(String(describing: wb)) gains=\(String(describing: gains)) exif=\(String(describing: exif))"
    }

    func start(preferred: String, mode: Mode) {
        lock.withLock { _mode = mode }
        observeSession()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return self.fail("Camera access is off. Turn it on in Settings › bettercam.")
            }
            self.queue.async { self.configure(preferred) }
        }
    }

    /// Back from the background or an interruption: restart if the system stopped the session.
    func resume() {
        queue.async { if self.input != nil, !self.session.isRunning { self.session.startRunning() } }
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
        let pressed = Date()
        let (shown, filter, exposure) = lock.withLock { (shownPreview, _filter, _exposure) }
        queue.async {
            guard let stop = self.active, self.session.isRunning else { return }
            guard !self.lock.withLock({ self.captureBusy() }),
                  !self.wants48(stop) || self.lock.withLock({ self.pending.isEmpty }) else { return }
            if let free = Self.freeSpaceMB(), free < 300 {
                return self.fail("Storage is almost full (\(free) MB free). Free some space to keep shooting.")
            }
            self.shoot(stop, flash: flash, pressed: pressed, shown: shown, filter: filter, exposure: exposure)
        }
    }

    func focus(at point: CGPoint) {
        queue.async {
            guard let d = self.input?.device, (try? d.lockForConfiguration()) != nil else { return }
            // continuous at the tapped point: .autoFocus focused once and then stayed locked until a lens change
            // the 2× stop shows a center crop: map the tapped point from the crop back to the full sensor frame
            let k = self.lock.withLock { self._crop }
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

    private func shoot(_ stop: Stop, flash: Bool, pressed: Date, shown: PreviewSample?, filter: String, exposure: Double) {
        let size48 = wants48(stop)
        let settings = makeSettings(stop, size48: size48)
        if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = stop.isFront }
        }
        let generation = lock.withLock { self.generation }
        let preview = settings.flashMode == .off && shown?.generation == generation ? shown : nil
        if (preview?.filter ?? filter) == Filter.leicaM6.id {
            lock.withLock { grainSeed = UInt32.random(in: .min ... .max) }
        }
        let p = Pending(crop: stop.crop, filter: preview?.filter ?? filter, exposure: preview?.exposure ?? exposure,
                        mode: mode, proRAW: settingsAreProRAW(settings),
                        size48: size48, label: stop.label, pressed: pressed, preview: preview)
        let busy = lock.withLock { pending[settings.uniqueID] = p; return captureBusy() }
        DispatchQueue.main.async { self.busy = busy }
        output.capturePhoto(with: settings, delegate: self)
    }

    // A single 48 MP ProRAW capture can use more than 1 GB inside the camera pipeline.
    private func captureBusy() -> Bool {
        pending.count >= Self.maxInFlight || pending.values.contains(where: \.size48)
    }

    private func settingsAreProRAW(_ s: AVCapturePhotoSettings) -> Bool { AVCapturePhotoOutput.isAppleProRAWPixelFormat(s.rawPhotoPixelFormatType) }

    /// ProRAW at 48 MP: when asked for, and for crop stops (a 2× crop of 12 MP would keep only 3 MP).
    private func wants48(_ stop: Stop) -> Bool { proRAWActive && dims48 != nil && (mode == .proRAW48 || stop.crop > 1) }

    /// One RAW request. Also used to pre-allocate the pipeline (setPreparedPhotoSettingsArray), so the first shot after
    /// a mode/lens change doesn't pay setup time.
    private func makeSettings(_ stop: Stop, size48: Bool) -> AVCapturePhotoSettings {
        let formats = output.availableRawPhotoPixelFormatTypes
        let bayer = formats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let proRAW = formats.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        guard let raw = proRAWActive ? (proRAW ?? bayer) : (bayer ?? proRAW) else {
            // ponytail: only cameras with neither Bayer RAW nor ProRAW land here
            let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            s.photoQualityPrioritization = .balanced
            return s
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        if AVCapturePhotoOutput.isAppleProRAWPixelFormat(raw) {
            // Only ever ask for the output's own values (AVFoundation throws above them): its max priority (.quality:
            // multi-frame fusion) and one of the sizes configureRaw found in the format's list.
            settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
            if let d = size48 ? dims48 : dims12 { settings.maxPhotoDimensions = d }
        } else {
            settings.photoQualityPrioritization = .speed // Required for Bayer by AVCapturePhotoOutput.
        }
        Self.log.info("request \(self.mode.rawValue, privacy: .public) \(stop.label, privacy: .public) fmt=\(Self.fourCC(raw), privacy: .public) max=\(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height) prio=\(settings.photoQualityPrioritization.rawValue) bias=\(stop.device.exposureTargetBias)")
        return settings
    }

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
            let d = stop.device
            if (try? d.lockForConfiguration()) != nil {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            }
        }
        // 2× blur: under the .photo preset the video output sends preview-sized frames (~screen size), and the 2× stop
        // center-crops them, leaving ~half the screen's pixels to upscale. Full-resolution frames only there.
        if video.deliversPreviewSizedOutputBuffers == (stop.crop > 1) {
            session.beginConfiguration()
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = stop.crop <= 1
            session.commitConfiguration()
        }
        active = stop
        lock.withLock { _crop = stop.crop }
        prepare(stop)
        let flash = output.supportedFlashModes.contains(.on)
        DispatchQueue.main.async { self.current = stop; self.flashAvailable = flash }
    }

    /// After any lens/mode change: bias, prepared settings, and the format label.
    private func prepare(_ stop: Stop) {
        setBias(stop.device, initialBias())
        lock.withLock { previewDevice = stop.device }
        resetPreview()
        var list = [makeSettings(stop, size48: wants48(stop))]
        if proRAWActive, dims48 != nil, !wants48(stop) { list.append(makeSettings(stop, size48: true)) }
        output.setPreparedPhotoSettingsArray(list) { ok, err in
            if !ok { Self.log.error("prepare failed: \(err?.localizedDescription ?? "?", privacy: .public)") }
        }
        let hasBayer = output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let label = proRAWActive ? (wants48(stop) ? "ProRAW 48" : "ProRAW 12") : hasBayer ? "RAW" : "HEIC"
        DispatchQueue.main.async { self.format = label }
    }

    /// ProRAW unless the mode asks for Bayer or this camera has no ProRAW; then Bayer; HEIC only if neither exists.
    /// All of it inside the session configuration, before startRunning (Apple: else a reconfiguration at first capture).
    private func configureRaw(_ d: AVCaptureDevice) {
        let mode = self.mode
        output.isAppleProRAWEnabled = false
        let hasBayer = output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        if output.isAppleProRAWSupported, mode.proRAW || !hasBayer { output.isAppleProRAWEnabled = true }
        proRAWActive = output.isAppleProRAWEnabled
            && output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        let dims = d.activeFormat.supportedMaxPhotoDimensions
        func mp(_ x: CMVideoDimensions) -> Int { Int(x.width) * Int(x.height) }
        let fallbackDims = defaultDims ?? output.maxPhotoDimensions
        defaultDims = fallbackDims
        dims12 = nil; dims48 = nil
        if proRAWActive {
            dims12 = dims.filter { mp($0) <= 14_000_000 }.max { mp($0) < mp($1) }
            dims48 = dims.filter { mp($0) >= 40_000_000 }.max { mp($0) < mp($1) }
            if let big = dims48 ?? dims12 ?? dims.max(by: { mp($0) < mp($1) }) { output.maxPhotoDimensions = big }
            output.maxPhotoQualityPrioritization = .quality
        } else if output.maxPhotoDimensions.width != fallbackDims.width,
                  dims.contains(where: { $0.width == fallbackDims.width && $0.height == fallbackDims.height }) {
            output.maxPhotoDimensions = fallbackDims // Bayer: exactly the validated pre-ProRAW path
        }
        // overlapping captures (press again while the last one is processing), same quality; off where unsupported
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
        output.isResponsiveCaptureEnabled = output.isResponsiveCaptureSupported
        if mode.proRAW, !proRAWActive {
            Self.log.error("fallback: no ProRAW on \(d.localizedName, privacy: .public), shooting \(hasBayer ? "Bayer RAW" : "HEIC", privacy: .public)")
        }
        let raws = output.availableRawPhotoPixelFormatTypes.map(Self.fourCC).joined(separator: ",")
        Self.log.info("device \(d.localizedName, privacy: .public) maxDims=[\(dims.map { "\($0.width)x\($0.height)" }.joined(separator: ","), privacy: .public)] proRAW=\(self.proRAWActive) raw=[\(raws, privacy: .public)] responsive=\(self.output.isResponsiveCaptureEnabled) outputMax=\(self.output.maxPhotoDimensions.width)x\(self.output.maxPhotoDimensions.height) mode=\(mode.rawValue, privacy: .public)")
    }

    // MARK: - Exposure

    /// ProRAW: 0. Apple's multi-frame capture protects highlights itself, and decode recovers Apple's metering
    /// (Look.proRAWExposure). Bayer: starts at the validated −1 EV and then adapts (`updateBias`).
    /// Rendering never depends on the bias: decode + Recipe.baseExposure undo the actual EXIF bias of each file.
    private func initialBias() -> Float {
        biasVote = 0; biasStreak = 0
        return shootsBayer ? -Float(Look.rawCompensation) : 0 // HEIC (no RAW at all): decode adds no compensation, so 0
    }

    private var shootsBayer: Bool {
        !proRAWActive && output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
    }
    /// Bayer by choice or as the ProRAW fallback; `.bayerFixed` keeps the old fixed −1 EV for comparison.
    private var adaptiveBias: Bool { shootsBayer && mode != .bayerFixed }

    /// Bayer only, from the running viewfinder analysis (never at the press: zero shutter lag). The 8-bit video clips
    /// 1.2–2.3 stops before the RAW does (research/11 §5, Look.analyze), so video statistics are a conservative proxy:
    /// - > 2% of the frame at video white for ~1 s → ⅓ stop more protection (down to −1.33: windows, snow, sky)
    /// - < 0.2% there and the brightest 0.1% below 80% of video white for ~1 s → ⅓ stop more light (up to 0: indoor
    ///   shadows, flat daylight, low light), never brighter in the rendered photo, only cleaner.
    /// The gap between the two thresholds is the hysteresis: a steady scene never oscillates.
    private func updateBias(_ a: Look.Analysis) {
        guard adaptiveBias, let d = active?.device else { return }
        let vote = a.highlightShare > 0.02 ? -1 : (a.highlightShare < 0.002 && a.peak < 0.8 ? 1 : 0)
        biasStreak = vote == biasVote ? biasStreak + 1 : 1
        biasVote = vote
        guard vote != 0, biasStreak >= 4 else { return }
        let now = lock.withLock { _bias }
        let next = min(0, max(-4 / 3, now + Float(vote) / 3))
        guard abs(next - now) > 0.01 else { return }
        biasStreak = 0
        setBias(d, next)
    }

    private func setBias(_ d: AVCaptureDevice, _ bias: Float) {
        guard (try? d.lockForConfiguration()) != nil else { return }
        let b = min(max(d.minExposureTargetBias, bias), d.maxExposureTargetBias)
        d.setExposureTargetBias(b)
        d.unlockForConfiguration()
        lock.withLock { _bias = b }
    }

    // MARK: - Session health

    private var observers: [NSObjectProtocol] = []
    private func observeSession() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Self.log.error("session runtime error \(err?.localizedDescription ?? "?", privacy: .public)")
            self?.queue.asyncAfter(deadline: .now() + 0.5) { self?.session.startRunning() } // media services reset etc.
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.resume()
        })
    }

    private static func freeSpaceMB() -> Int? {
        let v = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { Int($0 / 1_048_576) }
    }

    private static func fourCC(_ t: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: t >> $0) }, encoding: .ascii) ?? "\(t)"
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.error = message }
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

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async { self.shutterCount += 1 }
        if let p = lock.withLock({ pending[resolvedSettings.uniqueID] }) {
            Self.log.info("shutter lag \(Date().timeIntervalSince(p.pressed) * 1000, format: .fixed(precision: 0))ms")
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let p = lock.withLock({ pending[photo.resolvedSettings.uniqueID] }) else { return }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return fail("The photo couldn't be captured: \(error?.localizedDescription ?? "no image data"). Try again.")
        }
        // what the sensor actually delivered, never what was requested
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let dng = photo.metadata[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let dims = photo.isRawPhoto ? photo.resolvedSettings.rawPhotoDimensions : photo.resolvedSettings.photoDimensions
        let mp = Double(dims.width) * Double(dims.height) / 1e6
        let format = photo.pixelBuffer.map(CVPixelBufferGetPixelFormatType)
        let isProRAW = photo.isRawPhoto && (format.map(AVCapturePhotoOutput.isAppleProRAWPixelFormat)
            ?? (dng.map { $0["CFAPlaneColor"] == nil } ?? p.proRAW))
        func s(_ v: Any?) -> String { v.map { String(describing: $0).filter { !$0.isWhitespace } } ?? "?" }
        let line = [
            "capture", p.mode.rawValue, p.label, "lens=" + s(exif?[kCGImagePropertyExifLensModel as String]),
            "raw=\(photo.isRawPhoto)", "proRAW=\(isProRAW)", "fourCC=\(format.map(Self.fourCC) ?? "?")",
            "\(dims.width)x\(dims.height)", "crop=\(p.crop)", "photoPTS=\(photo.timestamp.seconds)",
            String(format: "%.1fMP", mp / (p.crop * p.crop)),
            "ISO=" + s(exif?[kCGImagePropertyExifISOSpeedRatings as String]), "t=" + s(exif?[kCGImagePropertyExifExposureTime as String]),
            "bias=" + s(exif?[kCGImagePropertyExifExposureBiasValue as String]), "baseline=" + s(dng?["BaselineExposure"]),
            "neutral=" + s(dng?["AsShotNeutral"]), "analogBalance=" + s(dng?["AnalogBalance"]),
            "orientation=" + s(photo.metadata[kCGImagePropertyOrientation as String]),
            "bytes=\(data.count)", String(format: "latency=%.2fs", Date().timeIntervalSince(p.pressed)),
            String(format: "mem=%.0fMB", Look.footprintMB()), "flash=\(photo.resolvedSettings.isFlashEnabled)",
        ].joined(separator: " ")
        Self.log.info("\(line, privacy: .public)")
        // never let a fallback pass as the requested format: it's saved (nothing is lost) and the user is told
        var mismatch: String?
        if p.proRAW, !isProRAW { mismatch = "ProRAW was requested but the camera delivered \(photo.isRawPhoto ? "Bayer RAW" : "HEIC")" }
        else if p.proRAW, p.size48, mp < 40 { mismatch = "48 MP ProRAW was requested but the camera delivered \(String(format: "%.0f", mp)) MP" }
        else if p.proRAW, !p.size48, mp > 14 { mismatch = "12 MP ProRAW was requested but the camera delivered \(String(format: "%.0f", mp)) MP" }
        if let mismatch {
            Self.log.error("MISMATCH \(mismatch, privacy: .public)")
            fail("\(mismatch). The photo was saved as delivered.")
        }
        let delta = p.preview.map { photo.timestamp.seconds - $0.pts } ?? .infinity
        // Preserve the displayed frame across ordinary still startup lag. Slower stills require closer spatial agreement.
        let match = abs(delta) <= 0.5
            && p.preview.map { abs(p.pressed.timeIntervalSince($0.received)) <= 0.25 } == true
        let shot = Shot(data: data, ext: photo.isRawPhoto ? "dng" : "heic", crop: p.crop, filter: p.filter,
                        exposure: p.exposure, preview: p.preview,
                        metadata: line + " delta=\(delta)", canMatch: match, previewDelay: abs(delta))
        #if DEBUG
        if Self.selfTestEnabled { return selfTestShot(shot) }
        #endif
        onCapture?(shot)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { fail("The photo couldn't be captured: \(error.localizedDescription). Try again.") }
        let busy = lock.withLock { pending[resolvedSettings.uniqueID] = nil; return captureBusy() }
        DispatchQueue.main.async { self.busy = busy }
    }

    // MARK: - Live filtered viewfinder

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let onFrame, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let received = Date()
        #if DEBUG
        let t0 = Date()
        #endif
        var img = CIImage(cvPixelBuffer: pb)
        // the UI is portrait, so a landscape frame means the connection didn't rotate it: turn it upright here
        if img.extent.width > img.extent.height {
            img = img.oriented(.right)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        // 2× stop: crop the full-resolution frame first, so the crop keeps real detail (scaling a small frame up didn't)
        let (k, bias, ev, filter, generation, device) = lock.withLock {
            (_crop, Double(_bias), _exposure, _filter, self.generation, previewDevice)
        }
        if trustGeneration != generation {
            trustGeneration = generation
            trust = 0
            lastTrusted = nil
        }
        if k > 1 {
            let e = img.extent, w = e.width / k, h = e.height / k
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
        }
        // ISP-processed video is the reference for this frame's RAW development.
        let s = min(1, Self.previewSide / max(img.extent.width, img.extent.height))
        var props: [String: Any] = [Look.clipKey: pow(2, -bias)] // 8-bit video white, after the bias gain below
        props[Look.evKey] = Self.sceneEV(sb) // same EV100 the saved photo's EXIF gives: light-dependent looks match the final
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            // frames are underexposed by the capture bias, like the DNG before decode: restore the same way
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -bias])
            .settingProperties(props)
        frameCount += 1
        let current = lock.withLock { _analysis }
        let analysis = current ?? Look.analyze(img)
        if current == nil {
            lock.withLock { if self.generation == generation { _analysis = analysis } }
        }
        if !analyzing, frameCount % 4 == 0 { analyzeAsync(img, generation: generation) }
        var r = Recipe(filter: filter)
        r.exposure = ev
        if filter == Filter.leicaM6.id { r.grainSeed = lock.withLock { grainSeed } }
        let out = Look.apply(r, to: img, analysis: analysis)
        if let cg = Look.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Look.outputSpace) {
            let s = 192 / max(img.extent.width, img.extent.height)
            let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s)).settingProperties(props)
            let sample = PreviewSample(input: Look.materialize(small), analysis: analysis, pts: sb.presentationTimeStamp.seconds,
                              received: received, generation: generation, filter: filter, exposure: ev,
                              metadata: Self.parityDiagnostics ? Self.videoMetadata(pb, sb: sb, device: device, bias: bias) : "",
                              rendered: cg, grainSeed: r.grainSeed)
            guard lock.withLock({ self.generation == generation }) else { return }
            onFrame(sample)
        }
        #if DEBUG
        if Self.selfTestEnabled { selfTestFrame(ms: Date().timeIntervalSince(t0) * 1000) }
        #endif
    }

    /// The viewfinder's analysis, off the video queue (~7×/s): white balance, highlight statistics and, unless the phone is
    /// hot, the Vision person mask + faces, so face lift, background tone and skin chroma show live like in the saved photo.
    /// The portrait pass ramps in over ~0.5 s and survives a few uncertain frames, so it neither pops nor flickers.
    private func analyzeAsync(_ img: CIImage, generation: Int) {
        analyzing = true
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        analysisQueue.async {
            var a = Look.analyze(img, subject: !hot)
            self.videoQueue.async {
                self.analyzing = false
                guard self.lock.withLock({ self.generation == generation }) else { return }
                if a.maskTrusted {
                    self.lastTrusted = a
                    self.trust = min(1, self.trust + 0.25)
                } else if let t = self.lastTrusted, self.trust > 0 {
                    self.trust = max(0, self.trust - 0.2)
                    a.subjectMask = t.subjectMask; a.faces = t.faces; a.maskTrusted = true
                    a.subjectGap = t.subjectGap; a.faceGap = t.faceGap; a.skinTarget = t.skinTarget
                } else {
                    self.lastTrusted = nil
                }
                a.selectiveStrength = self.trust
                self.lock.withLock { if self.generation == generation { self._analysis = a } }
                self.queue.async {
                    guard self.lock.withLock({ self.generation == generation }) else { return }
                    self.updateBias(a)
                }
            }
        }
    }

    // MARK: - Device self-test (Debug, launch argument -selftest)

    #if DEBUG
    /// Exercises the real capture pipeline sequentially with small renders and no gallery writes.
    private static let selfTestEnabled = CommandLine.arguments.contains("-selftest")
    private var selfTest: [(Mode, String)] = [
        (.bayer, "1×"), (.bayer, "1×"), (.proRAW12, "1×"), (.proRAW48, "1×"), (.proRAW12, "2×")
    ]
    private var frameTimes: [Double] = []

    static func say(_ s: String) {
        FileHandle.standardError.write(Data(("SELFTEST " + s + "\n").utf8))
        log.info("SELFTEST \(s, privacy: .public)")
    }

    private func selfTestFrame(ms: Double) {
        frameTimes.append(ms)
        if frameTimes.count == 90 {
            let t = frameTimes.sorted()
            Self.say(String(format: "viewfinder frame cost median %.1fms p95 %.1fms (90 frames) portrait=%.2f mem=%.0fMB",
                            t[45], t[85], trust, Look.footprintMB()))
            frameTimes = []
        }
        if frameCount == 120 { queue.async { self.selfTestNext() } }
    }

    private func selfTestNext() {
        guard !selfTest.isEmpty else { return Self.say("DONE") }
        let (m, label) = selfTest.removeFirst()
        mode = m // reconfigures on this queue
        DispatchQueue.main.async {
            guard let stop = self.stops.first(where: { $0.label == label }) else {
                self.queue.async { self.selfTestNext() }
                return
            }
            if self.current != stop { self.select(stop) }
            self.queue.asyncAfter(deadline: .now() + 2.5) {
                Self.say("shoot \(m.rawValue) \(label) format=\(self.proRAWActive ? "ProRAW" : "Bayer") bias=\(self.lock.withLock { self._bias })")
                self.capture()
            }
        }
    }

    private func selfTestShot(_ shot: Shot) {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory.appending(path: "selftest.\(shot.ext)")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: Look.shutterURL(for: url))
                self.queue.asyncAfter(deadline: .now() + 1) { self.selfTestNext() }
            }
            guard (try? shot.data.write(to: url)) != nil else { return Self.say("FAIL write") }
            _ = autoreleasepool { shot.recipe(for: url, diagnosticID: UUID().uuidString) }
        }
    }
    #endif
}

extension Camera.Shot {
    func recipe(for url: URL, diagnosticID: String) -> Recipe {
        var r = Recipe(filter: filter, crop: crop)
        r.exposure = min(max(exposure, Recipe.exposureRange.lowerBound), Recipe.exposureRange.upperBound)
        if filter == Filter.leicaM6.id { r.grainSeed = preview?.grainSeed ?? UInt32.random(in: .min ... .max) }
        if let preview, (try? Look.saveShutterFrame(preview.rendered, for: url)) != nil {
            r.shutterLook = Recipe.ShutterLook(filter: r.filter, exposure: r.exposure)
        }
        if canMatch, let preview, let input = preview.input,
           let raw = Look.decode(url, crop: crop, maxSide: 600, normalizeForPreview: true, unsharpened: r.filter == Filter.leicaM6.id),
           var match = Look.PreviewMatch(raw: raw, video: input, analysis: preview.analysis,
                                         minimumCorrelation: previewDelay > 0.25 ? 0.85 : 0.65) {
            let base = match.apply(to: raw)
            let still = Look.apply(r, to: base, analysis: match.analysis(for: base))
            match.matchDisplay(still: still, preview: CIImage(cgImage: preview.rendered))
            r.previewMatch = match
        }
        if r.previewMatch == nil { r.baseExposure = Look.startingExposure(url, captured: true) }
        #if DEBUG
        if Camera.parityDiagnostics { diagnose(url, recipe: r, id: diagnosticID) }
        #endif
        return r
    }

    #if DEBUG
    private func diagnose(_ url: URL, recipe: Recipe, id: String) {
        let dir = URL.documentsDirectory.appending(path: "PreviewParity")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = dir.appending(path: "\(id).txt")
        let prior = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let saveFiles = prior.count < 12
        var lines = [metadata, "look=\(filter) exposureSlider=\(exposure) crop=\(crop) shutterFrame=\(recipe.shutterLook != nil) matched=\(recipe.previewMatch != nil) displayMatched=\(recipe.previewMatch?.displayEV != nil)",
                     preview?.metadata ?? "no fresh displayed frame", "output=SDR Display P3 8-bit JPEG"]
        if let raw = CIRAWFilter(imageURL: url) {
            lines += ["CIRAW baseline=\(raw.baselineExposure) exposure=\(raw.exposure) neutral=\(raw.neutralTemperature)K tint=\(raw.neutralTint)"]
        }
        var old = recipe
        old.previewMatch = nil
        old.baseExposure = Look.startingExposure(url, captured: true)
        lines += ["legacy recipe EV=\(old.baseExposure)"]
        if let match = recipe.previewMatch {
            lines += ["development gain at knots=\(match.curves.map { curve in stride(from: 2, to: curve.count, by: 2).map { log2(curve[$0+1] / curve[$0]) } })",
                      "preview clip=\(match.white) WB=\(match.wb) illuminant=\(match.illuminant) EV100=\(String(describing: match.sceneEV))",
                      "portrait strength=\(match.selectiveStrength) subject gap=\(match.subjectGap) face gap=\(match.faceGap)"]
        }
        if let (base, analysis) = Look.photo(url, recipe: recipe, maxSide: 600),
           let previous = Look.decode(url, crop: crop, maxSide: 600) {
            let final = Look.renderPhoto(url, recipe: recipe, maxSide: 600) ?? Look.apply(recipe, to: base, analysis: analysis)
            let before = Look.apply(old, to: previous)
            let a = analysis ?? Look.analyze(base, subject: true)
            let grade = recipe.grade.resolved(sceneEV: a.sceneEV)
            let plan = Look.selectivePlan(grade, a, guide: base.applyingFilter("CILinearToSRGBToneCurve"))
            lines += ["film exposure=\(grade.exposure) whiteStops=\(log2(a.clip / 0.18) + grade.exposure) contrast=\(grade.contrast) midContrast=\(grade.midContrast)",
                      "face lift=\(plan?.lift ?? 0) background reduction=\(plan?.background ?? 0) faces=\(a.faces)"]
            if saveFiles {
                for (label, image) in [("before", before), ("final", final)] {
                    try? Look.jpeg(image, quality: 0.9)?.write(to: dir.appending(path: "\(id)-\(label).jpg"), options: .atomic)
                }
            }
            if let cg = preview?.rendered {
                let scale = 600 / CGFloat(max(cg.width, cg.height))
                let ref = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if saveFiles {
                    try? Look.jpeg(ref, quality: 0.9)?.write(to: dir.appending(path: "\(id)-preview.jpg"), options: .atomic)
                }
                lines += ["regional EV and ΔE OK (after / before): \(Self.regionalDelta(final, before: before, reference: ref, faces: a.faces))"]
                if recipe.previewMatch?.displayEV != nil {
                    let preDisplay = Look.apply(recipe.grade, to: base, analysis: analysis)
                    lines += ["regional EV and ΔE OK (after / pre-display match): \(Self.regionalDelta(final, before: preDisplay, reference: ref, faces: a.faces))"]
                }
            }
        }
        let log = lines.joined(separator: "\n")
        if saveFiles { try? log.write(to: report, atomically: true, encoding: .utf8) }
        Camera.say(log)
    }

    private static func regionalDelta(_ final: CIImage, before: CIImage, reference: CIImage, faces: [CGRect]) -> String {
        func tiles(_ image: CIImage) -> [(y: Double, lab: (Double, Double, Double))] {
            let p = Look.PreviewMatch.tiles(image)
            return stride(from: 0, to: p.count, by: 4).map { i in
                let rg = 0.2126 * p[i] + 0.7152 * p[i + 1]
                return (rg + 0.0722 * p[i + 2], OkLab.from((p[i], p[i + 1], p[i + 2])))
            }
        }
        let ref = tiles(reference), new = tiles(final), old = tiles(before)
        let sorted = ref.indices.sorted { ref[$0].y < ref[$1].y }
        let n = sorted.count
        let face = ref.indices.filter { i in
            let point = CGPoint(x: (Double(i % 24) + 0.5) / 24, y: 1 - (Double(i / 24) + 0.5) / 24)
            return faces.contains { $0.contains(point) }
        }
        return [("shadows", Array(sorted.prefix(n / 4))), ("midtones", Array(sorted[n*3/8..<n*5/8])),
                ("highlights", Array(sorted.suffix(n / 4))), ("face", face)].map { label, region in
            guard !region.isEmpty else { return "\(label)=n/a" }
            func delta(_ values: [(y: Double, lab: (Double, Double, Double))]) -> (Double, Double) {
                let ev = region.map { log2(max(0.001, values[$0].y) / max(0.001, ref[$0].y)) }.sorted()
                let de = region.map { i -> Double in
                    let (l, a, b) = values[i].lab, (rl, ra, rb) = ref[i].lab
                    return 100 * sqrt(pow(l - rl, 2) + pow(a - ra, 2) + pow(b - rb, 2))
                }.sorted()
                return (ev[region.count / 2], de[region.count / 2])
            }
            let (afterEV, afterColor) = delta(new), (beforeEV, beforeColor) = delta(old)
            return "\(label)=" + String(format: "%+.2f/%+.2f EV, %.1f/%.1f ΔE OK", afterEV, beforeEV, afterColor, beforeColor)
        }.joined(separator: " ")
    }
    #endif
}

struct PreviewView: UIViewRepresentable {
    let camera: Camera
    var onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.preview.session = camera.session
        v.preview.videoGravity = .resizeAspectFill
        camera.onFrame = { [weak v, weak camera] sample in
            DispatchQueue.main.async {
                guard let v, camera?.didDisplay(sample) == true else { return }
                v.filtered.image = UIImage(cgImage: sample.rendered)
            }
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
