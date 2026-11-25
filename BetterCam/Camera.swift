import AVFoundation
import os
import SwiftUI

/// ProRAW by default, with Bayer and HEIC paths according to device capability.
/// The viewfinder is the video feed run through the same Look engine as the photo, with the current filter.
final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoOutputReadinessCoordinatorDelegate {
    /// A native lens or a 2× view of the main sensor. Physical-input modes apply the crop during development.
    struct Stop: Identifiable, Equatable {
        let id: String
        let label: String
        let device: AVCaptureDevice
        let crop: Double
        var isFront: Bool { device.position == .front }
        static func == (a: Stop, b: Stop) -> Bool { a.id == b.id }
    }

    /// `exposure`: the viewfinder's exposure offset at the press (render-only, becomes the recipe's Exposure slider).
    /// The viewfinder snapshot is only used while the original's thumbnail develops.
    struct Shot {
        let ext: String; let crop: Double; let filter: String; let exposure: Double
        let captureID: Int64
        let delivered: TimeInterval
        let preview: CGImage?
        var diagnostic: Diagnostics.Capture? = nil
    }

    /// One filtered viewfinder frame, tagged with the lens/mode generation it was rendered for.
    struct PreviewSample {
        let rendered: CGImage
        let generation: Int
    }

    enum Mode: String, CaseIterable, Identifiable {
        case proRAW12 = "ProRAW 12MP", proRAW48 = "ProRAW 48MP", bayer = "Bayer RAW 12MP"
        var id: String { rawValue }
        var proRAW: Bool { self == .proRAW12 || self == .proRAW48 }
        /// What the app shoots unless the user picked a format (the chip menu, remembered).
        static let standard = Mode.proRAW12
    }

    let session = AVCaptureSession()
    @Published private(set) var stops: [Stop] = []      // back lenses
    @Published private(set) var front: Stop?
    @Published private(set) var current: Stop?
    @Published private(set) var selected: Stop?
    @Published private(set) var busy = true            // too many shots still processing: shutter waits
    @Published private(set) var flashAvailable = false
    @Published private(set) var format = ""             // what the next shot will be, e.g. "ProRAW 12"
    @Published private(set) var shutterCount = 0        // bumps at exposure: the UI blinks
    @Published private(set) var permissionDenied = false
    @Published var error: String?
    var onCapture: ((Shot, Data) async -> Void)?
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
            queue.async {
                self.lock.withLock { self._mode = newValue }
                guard let stop = self.active else { return }
                self.use(stop, formatChanged: true)
            }
        }
    }

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera", qos: .userInitiated)
    private lazy var readiness = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)
    private var writing: Set<Int64> = []
    private var sensorTimes: [Int64: TimeInterval] = [:]
    private var previewDrops = 0
    private var previewReport = ProcessInfo.processInfo.systemUptime
    private var previewPending = false
    private var latestPreview: (image: CGImage, filter: String, exposure: Double, time: TimeInterval)?
    private var shutterPreviews: [Int64: CGImage] = [:]
    private var diagnosticFrame: Diagnostics.Frame?             // lock-protected; only when Diagnostics.enabled
    private var diagnosticShutter: [Int64: [String: Any]] = [:] // lock-protected
    private var diagnosticFrames: [Int64: Diagnostics.Frame] = [:] // lock-protected
    private var selection = 0
    private var cropDeviceID: String?
    private var virtualRear: AVCaptureDevice?
    private var virtualZooms: [String: CGFloat] = [:]
    private var usesVirtualRear = false
    private var zoomStarted: TimeInterval?
    #if DEBUG
    private var saveReferenceFrame = ProcessInfo.processInfo.arguments.contains("-color-reference-frame")
    #endif
    private let video = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camera.video", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "camera.analysis", qos: .utility)
    private let lock = NSLock()
    // lock-protected
    private var _filter = Filter.all[0].id
    private var _exposure = 0.0
    private var _paused = false
    private var _crop = 1.0          // current stop's crop, read by the video queue
    private var _mode = Mode.standard
    private var _bias: Float = 0     // exposure target bias in effect; the viewfinder undoes it like decode does
    private var _analyzeExposure = false
    private var generation = 0
    private var pending: [Int64: Pending] = [:] // per shot, by settings.uniqueID: back-to-back shots can't swap filters
    // camera queue
    private var input: AVCaptureDeviceInput?
    private var active: Stop?
    private var dims12: CMVideoDimensions?
    private var dims48: CMVideoDimensions?
    private var proRAWActive = false
    private var biasVote = 0, biasStreak = 0
    // video queue
    private var frameCount = 0
    private var analyzing = false
    /// Viewfinder frame size, long side in pixels: about a phone screen's 3:4 area (1206–1320 pt wide × 3).
    private static let previewSide: CGFloat = 1600
    /// Standard captures allowed in flight at once.
    private static let maxInFlight = 3

    private struct Pending {
        let crop: Double, filter: String, exposure: Double, mode: Mode, proRAW: Bool, size48: Bool, label: String
        let pressed: TimeInterval; let requested: TimeInterval
        let request: String
        let generation: Int
        var device: [String: Any] = [:]   // capture device state at the request (diagnostics only)
    }

    func didDisplay(_ sample: PreviewSample) -> Bool {
        lock.withLock { previewPending = false; return sample.generation == generation }
    }

    func start(preferred: String, mode: Mode) {
        lock.withLock { _mode = mode }
        readiness.delegate = self
        DispatchQueue.global(qos: .utility).async { Self.log.notice("\(Look.rendererDescription, privacy: .public)") }
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

    func select(_ stop: Stop) {
        guard selected != stop else { return }
        selected = stop
        let tap = ProcessInfo.processInfo.systemUptime
        let request = lock.withLock {
            selection += 1
            return selection
        }
        queue.async {
            guard self.lock.withLock({ self.selection == request }) else { return }
            self.use(stop, request: request, tap: tap)
        }
    }

    /// Flip between the back camera (back to 1×) and the selfie camera.
    func flip() {
        guard let stop = selected ?? current else { return }
        if stop.isFront {
            if let wide = stops.first(where: { $0.label == "1×" }) ?? stops.first { select(wide) }
        } else if let front {
            select(front)
        }
    }

    /// `flash`: the LED, for After Hours-style shots (doc §5.3: flash is a capture feature, not a look).
    func capture(flash: Bool = false) {
        let pressed = ProcessInfo.processInfo.systemUptime
        let (filter, exposure) = lock.withLock { (_filter, _exposure) }
        queue.async {
            guard let stop = self.active, self.session.isRunning else { return }
            guard !self.lock.withLock({ self.captureBusy() }),
                  !self.wants48(stop) || self.lock.withLock({ self.pending.isEmpty && self.writing.isEmpty }) else { return }
            if let free = Self.freeSpaceMB(), free < 300 {
                return self.fail("Storage is almost full (\(free) MB free). Free some space to keep shooting.")
            }
            self.shoot(stop, flash: flash, pressed: pressed, filter: filter, exposure: exposure)
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

    private func shoot(_ stop: Stop, flash: Bool, pressed: TimeInterval, filter: String, exposure: Double) {
        let size48 = wants48(stop)
        let settings = makeSettings(stop, size48: size48)
        if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let conn = output.connection(with: .video) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = stop.isFront }
        }
        // the seed the viewfinder showed, so the photo's grain is the pattern composed with; a fresh one for the next shot
        let dimensions = settings.maxPhotoDimensions
        let request = "mode=\(mode.rawValue) requestedMax=\(dimensions.width)x\(dimensions.height) requestedFourCC=\(Self.fourCC(settings.rawPhotoPixelFormatType)) camera=\(stop.device.deviceType.rawValue)"
        let requested = ProcessInfo.processInfo.systemUptime
        let p = Pending(crop: usesVirtualRear ? 1 : stop.crop, filter: filter, exposure: exposure, mode: mode, proRAW: settingsAreProRAW(settings),
                        size48: size48, label: stop.label, pressed: pressed, requested: requested, request: request, generation: lock.withLock { generation })
        var request0 = p
        if Diagnostics.enabled, let d = input?.device {
            let wb = d.deviceWhiteBalanceGains
            let tt = d.temperatureAndTintValues(for: wb)
            request0.device = ["exposureDuration": d.exposureDuration.seconds, "iso": d.iso, "targetBias": d.exposureTargetBias,
                               "targetOffset": d.exposureTargetOffset, "wbGains": [wb.redGain, wb.greenGain, wb.blueGain],
                               "wbTemperature": tt.temperature, "wbTint": tt.tint, "lensPosition": d.lensPosition,
                               "device": d.deviceType.rawValue, "format": "\(d.activeFormat.formatDescription.dimensions)",
                               "requestUptime": requested]
        }
        lock.withLock { pending[settings.uniqueID] = request0 }
        readiness.startTrackingCaptureRequest(using: settings)
        Self.log.info("capture \(settings.uniqueID) tap to request \((requested - pressed) * 1000) ms")
        output.capturePhoto(with: settings, delegate: self)
        updateBusy()
    }

    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator,
                              captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        updateBusy()
    }

    private func updateBusy() {
        DispatchQueue.main.async {
            let state = self.readiness.captureReadiness
            let busy = state == .sessionNotRunning || state == .notReadyWaitingForCapture
                || self.lock.withLock { self.captureBusy() }
            if self.busy != busy { self.busy = busy }
        }
    }

    // Carry the bound through original persistence so repeated taps cannot queue unbounded DNG buffers.
    private func captureBusy() -> Bool {
        Set(pending.keys).union(writing).count >= Self.maxInFlight || pending.values.contains(where: \.size48)
            || (writing.count > 0 && _mode == .proRAW48)
    }

    private func settingsAreProRAW(_ s: AVCapturePhotoSettings) -> Bool { AVCapturePhotoOutput.isAppleProRAWPixelFormat(s.rawPhotoPixelFormatType) }

    /// ProRAW at 48 MP: when asked for, and for crop stops (a 2× crop of 12 MP would keep only 3 MP).
    private func wants48(_ stop: Stop) -> Bool { proRAWActive && dims48 != nil && (!usesVirtualRear && (mode == .proRAW48 || stop.crop > 1)) }

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
            if let dims12 { s.maxPhotoDimensions = dims12 }
            return s
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        if AVCapturePhotoOutput.isAppleProRAWPixelFormat(raw) {
            // Only ever ask for the output's own values (AVFoundation throws above them): its max priority (.quality:
            // multi-frame fusion) and one of the sizes configureRaw found in the format's list.
            settings.photoQualityPrioritization = size48 ? output.maxPhotoQualityPrioritization : .balanced
        } else {
            settings.photoQualityPrioritization = .speed // Required for Bayer by AVCapturePhotoOutput.
        }
        if let d = size48 ? dims48 : dims12 { settings.maxPhotoDimensions = d }
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

        cropDeviceID = stops.first { $0.crop > 1 }?.device.uniqueID
        virtualRear = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
        if let virtualRear {
            let native = Dictionary(uniqueKeysWithValues: zip(virtualRear.constituentDevices.map(\.uniqueID),
                [1] + virtualRear.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }))
            for stop in stops {
                if let factor = native[stop.device.uniqueID] {
                    virtualZooms[stop.id] = factor * stop.crop
                }
            }
        }
        let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        let front = frontDevice.map { Stop(id: $0.uniqueID, label: "1×", device: $0, crop: 1) }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(output) { session.addOutput(output) }
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(video) { session.addOutput(video) }
        session.commitConfiguration()

        DispatchQueue.main.async { self.stops = stops; self.front = front }
        use((stops + [front].compactMap { $0 }).first { $0.id == preferred } ?? stops.first { $0.label == "1×" }!)
        session.startRunning()
    }

    private func use(_ stop: Stop, formatChanged: Bool = false, request: Int? = nil, tap: TimeInterval? = nil) {
        guard active != stop || formatChanged else { return }
        defer {
            DispatchQueue.main.async {
                if let request {
                    guard self.lock.withLock({ self.selection == request }) else { return }
                } else if self.selected != nil {
                    return
                }
                self.selected = self.current
            }
        }
        let zoom = mode == .proRAW12 ? virtualZooms[stop.id] : nil
        let device = zoom.flatMap { _ in virtualRear } ?? stop.device
        let switchingDevice = input?.device != device
        if switchingDevice || formatChanged {
            let new = switchingDevice ? try? AVCaptureDeviceInput(device: device) : input
            guard let new else { return fail("Couldn't open that camera.") }
            session.beginConfiguration()
            if switchingDevice {
                if let input { session.removeInput(input) }
                guard session.canAddInput(new) else {
                    if let input, session.canAddInput(input) { session.addInput(input) }
                    session.commitConfiguration()
                    return fail("Couldn't open that camera.")
                }
                session.addInput(new)
                input = new
            }
            // The main lens also supplies 2×. Keep its detailed feed configured across both stops.
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = zoom != nil || stop.device.uniqueID != cropDeviceID
            let format = video.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            configureRaw(device, virtual: zoom != nil)
            session.commitConfiguration()
            if zoom != nil, !proRAWActive {
                virtualRear = nil
                virtualZooms.removeAll()
                return use(stop, formatChanged: true, request: request, tap: tap)
            }
            // after commit, on the connection that actually runs: upright, and mirrored like a mirror for selfies.
            // (Set inside the configuration, the selfie camera's frames arrived unrotated.)
            if let c = video.connection(with: .video) {
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = stop.isFront }
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            }
            let d = device
            if (try? d.lockForConfiguration()) != nil {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            }
        }
        if let zoom, (try? device.lockForConfiguration()) != nil {
            let target = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        }
        active = stop
        usesVirtualRear = zoom != nil
        lock.withLock {
            _crop = usesVirtualRear ? 1 : stop.crop
            zoomStarted = tap
            generation += 1
            latestPreview = nil
            _analyzeExposure = shootsBayer
        }
        if switchingDevice || formatChanged {
            setBias(device, initialBias())
            prepareSettings(stop)
        }
        publishFormat(stop)
        let flash = output.supportedFlashModes.contains(.on)
        DispatchQueue.main.async { self.current = stop; self.flashAvailable = flash }
    }

    private func prepareSettings(_ stop: Stop) {
        let bothSizes = !usesVirtualRear && mode != .proRAW48 && proRAWActive && dims48 != nil && stop.device.uniqueID == cropDeviceID
        let list = bothSizes ? [makeSettings(stop, size48: false), makeSettings(stop, size48: true)]
            : [makeSettings(stop, size48: wants48(stop))]
        output.setPreparedPhotoSettingsArray(list) { ok, err in
            if !ok { Self.log.error("prepare failed: \(err?.localizedDescription ?? "?", privacy: .public)") }
        }
    }

    private func publishFormat(_ stop: Stop) {
        let label = formatLabel(stop)
        DispatchQueue.main.async { self.format = label }
    }

    /// The chip: what the next shot actually delivers, in genuine pixels after any center crop. Megapixels are truncated
    /// (8064×6048 = 48.8 MP is "48", the name everyone uses; rounding showed "ProRAW 49"). A crop or a missing size says so.
    private func formatLabel(_ stop: Stop) -> String {
        let hasBayer = output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let size = proRAWActive ? (wants48(stop) ? dims48 : dims12) : dims12
        let crop = usesVirtualRear ? 1 : stop.crop
        let mp = size.map { Int(Double($0.width) * Double($0.height) / (crop * crop) / 1_000_000) }
        let name = proRAWActive ? "ProRAW" : (hasBayer ? "RAW" : "HEIC")
        var label = mp.map { "\(name) \($0)" } ?? name
        if crop > 1 { label += " · crop" }
        if mode == .proRAW48, proRAWActive, dims48 == nil { label += " · no 48 here" }
        if mode.proRAW, !proRAWActive { label += " · no ProRAW here" }
        return label
    }

    /// ProRAW unless the mode asks for Bayer or this camera has no ProRAW; then Bayer; HEIC only if neither exists.
    /// All of it inside the session configuration, before startRunning (Apple: else a reconfiguration at first capture).
    private func configureRaw(_ d: AVCaptureDevice, virtual: Bool) {
        let mode = self.mode
        let hasBayer = output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
        let enableProRAW = output.isAppleProRAWSupported && (mode.proRAW || !hasBayer)
        if output.isAppleProRAWEnabled != enableProRAW { output.isAppleProRAWEnabled = enableProRAW }
        proRAWActive = output.isAppleProRAWEnabled
            && output.availableRawPhotoPixelFormatTypes.contains(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
        let dims = d.activeFormat.supportedMaxPhotoDimensions
        func mp(_ x: CMVideoDimensions) -> Int { Int(x.width) * Int(x.height) }
        dims12 = dims.filter { mp($0) <= 14_000_000 }.max { mp($0) < mp($1) }
            ?? dims.min { mp($0) < mp($1) }
        dims48 = proRAWActive && !virtual ? dims.filter { mp($0) >= 40_000_000 }.max { mp($0) < mp($1) } : nil
        if let maximum = dims48 ?? dims12, (output.maxPhotoDimensions.width != maximum.width || output.maxPhotoDimensions.height != maximum.height) {
            output.maxPhotoDimensions = maximum
        }
        let priority: AVCapturePhotoOutput.QualityPrioritization = dims48 != nil ? .quality : .balanced
        if output.maxPhotoQualityPrioritization != priority { output.maxPhotoQualityPrioritization = priority }
        // overlapping captures (press again while the last one is processing), same quality; off where unsupported
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported, output.isFastCapturePrioritizationEnabled != virtual {
            output.isFastCapturePrioritizationEnabled = virtual
        }
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
    /// Bayer by choice or as the ProRAW fallback.
    private var adaptiveBias: Bool { shootsBayer }

    /// Bayer only, from the running viewfinder analysis (never at the press: zero shutter lag). The 8-bit video clips
    /// 1.2–2.3 stops before the RAW does (research/11 §5, Look.analyze), so video statistics are a conservative proxy:
    /// - > 2% of the frame at video white for ~1 s → ⅓ stop more protection (down to −1.33: windows, snow, sky)
    /// - < 0.2% there and the brightest 0.1% below 80% of video white for ~1 s → ⅓ stop more light (up to 0: indoor
    ///   shadows, flat daylight, low light), never brighter in the rendered photo, only cleaner.
    /// The gap between the two thresholds is the hysteresis: a steady scene never oscillates.
    private func updateBias(highlightShare: Double, peak: Double) {
        guard adaptiveBias, let d = active?.device else { return }
        let vote = highlightShare > 0.02 ? -1 : (highlightShare < 0.002 && peak < 0.8 ? 1 : 0)
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

    fileprivate static let log = Logger(subsystem: "bettercam", category: "capture")

    private static func zoom(_ d: AVCaptureDevice, relativeTo wide: AVCaptureDevice) -> Double {
        func halfTan(_ x: AVCaptureDevice) -> Double { tan(Double(x.activeFormat.videoFieldOfView) * .pi / 360) }
        return halfTan(wide) / halfTan(d)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        lock.withLock {
            let id = resolvedSettings.uniqueID
            if !resolvedSettings.isFlashEnabled, let request = pending[id], let preview = latestPreview,
               request.generation == generation, request.filter == preview.filter, request.exposure == preview.exposure,
               ProcessInfo.processInfo.systemUptime - preview.time < 0.25 {
                shutterPreviews[id] = preview.image
            }
            if Diagnostics.enabled, let frame = diagnosticFrame { diagnosticFrames[id] = frame }
        }
        DispatchQueue.main.async { self.shutterCount += 1 }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let now = ProcessInfo.processInfo.systemUptime
        let id = resolvedSettings.uniqueID
        if let request = lock.withLock({ sensorTimes[id] = now; return pending[id] }) {
            Self.log.info("capture \(id) request to sensor callback \((now - request.requested) * 1000) ms")
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let callback = ProcessInfo.processInfo.systemUptime
        let (request, sensor, preview, frame) = lock.withLock {
            (pending[id], sensorTimes[id], shutterPreviews.removeValue(forKey: id), diagnosticFrames.removeValue(forKey: id))
        }
        guard let p = request else { return }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return fail("The photo couldn't be captured: \(error?.localizedDescription ?? "no image data"). Try again.")
        }
        let delivered = ProcessInfo.processInfo.systemUptime
        if let sensor {
            Self.log.info("capture \(id) sensor callback to processing callback \((callback - sensor) * 1000) ms, DNG serialization \((delivered - callback) * 1000) ms")
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
            "capture", p.request, p.label, "lens=" + s(exif?[kCGImagePropertyExifLensModel as String]),
            "raw=\(photo.isRawPhoto)", "proRAW=\(isProRAW)", "fourCC=\(format.map(Self.fourCC) ?? "?")",
            "resolved=\(dims.width)x\(dims.height)", "crop=\(p.crop)", "photoPTS=\(photo.timestamp.seconds)",
            String(format: "%.1fMP", mp / (p.crop * p.crop)),
            "ISO=" + s(exif?[kCGImagePropertyExifISOSpeedRatings as String]), "t=" + s(exif?[kCGImagePropertyExifExposureTime as String]),
            "bias=" + s(exif?[kCGImagePropertyExifExposureBiasValue as String]), "baseline=" + s(dng?["BaselineExposure"]),
            "neutral=" + s(dng?["AsShotNeutral"]), "analogBalance=" + s(dng?["AnalogBalance"]),
            "orientation=" + s(photo.metadata[kCGImagePropertyOrientation as String]),
            "bytes=\(data.count)", String(format: "latency=%.2fs", (delivered - p.pressed)),
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
        guard let onCapture else { return }
        var shot = Shot(ext: photo.isRawPhoto ? "dng" : "heic", crop: p.crop, filter: p.filter,
                        exposure: p.exposure, captureID: id, delivered: delivered, preview: preview)
        if Diagnostics.enabled {
            // Comparability evidence: frame age, both exposures and WB; never assume the preview matches the still.
            var info: [String: Any] = ["captureID": id, "request": p.request, "stop": p.label, "crop": p.crop,
                "mode": p.mode.rawValue, "filter": p.filter, "userEV": p.exposure, "proRAWRequested": p.proRAW,
                "size48Requested": p.size48, "deliveredProRAW": isProRAW, "delivered": "\(dims.width)x\(dims.height)",
                "photoPTS": photo.timestamp.seconds, "orientation": Diagnostics.plain(photo.metadata[kCGImagePropertyOrientation as String]),
                "stillExif": Diagnostics.plain(exif), "stillDNG": Diagnostics.plain(dng?.filter { !["ProfileHueSatMapData1", "ProfileHueSatMapData2", "ProfileLookTableData", "ProfileToneCurve", "DNGPrivateData"].contains($0.key) }),
                "deviceAtRequest": Diagnostics.plain(p.device),
                "timings": ["pressed": p.pressed, "requested": p.requested, "sensor": sensor ?? -1, "processed": callback, "delivered": delivered]]
            if let frame {
                info["preview"] = Diagnostics.plain(frame.info)
                info["previewPTS"] = frame.pts
                info["previewAgeSeconds"] = photo.timestamp.seconds - frame.pts
            }
            shot.diagnostic = Diagnostics.Capture(ungraded: frame?.ungraded, graded: frame?.graded, info: info)
        }
        lock.withLock { _ = writing.insert(id) }
        Task {
            await onCapture(shot, data)
            lock.withLock { _ = writing.remove(id) }
            updateBusy()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { fail("The photo couldn't be captured: \(error.localizedDescription). Try again.") }
        lock.withLock {
            pending[resolvedSettings.uniqueID] = nil
            sensorTimes[resolvedSettings.uniqueID] = nil
            shutterPreviews[resolvedSettings.uniqueID] = nil
            diagnosticFrames[resolvedSettings.uniqueID] = nil
        }
        updateBusy()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !paused { previewDrops += 1 }
    }

    // MARK: - Live filtered viewfinder

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let onFrame, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - previewReport >= 5 {
            Self.log.debug("preview drops \(self.previewDrops) in \(now - self.previewReport) s, footprint \(Look.footprintMB()) MB")
            previewReport = now
            previewDrops = 0
        }
        guard lock.withLock({ !previewPending }) else { previewDrops += 1; return }
        var img = CIImage(cvPixelBuffer: pb)
        // the UI is portrait, so a landscape frame means the connection didn't rotate it: turn it upright here
        if img.extent.width > img.extent.height {
            img = img.oriented(.right)
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        // 2× stop: crop the full-resolution frame first, so the crop keeps real detail (scaling a small frame up didn't)
        let (k, bias, ev, filter, generation, analyzeExposure) = lock.withLock {
            (_crop, Double(_bias), _exposure, _filter, self.generation, _analyzeExposure)
        }
        if k > 1 {
            let e = img.extent, w = e.width / k, h = e.height / k
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
        }
        // ISP-processed video is the reference for this frame's RAW development.
        let s = min(1, Self.previewSide / max(img.extent.width, img.extent.height))
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        frameCount += 1
        if analyzeExposure, !analyzing, frameCount % 12 == 0 {
            analyzeAsync(img, generation: generation)
        }
        var recipe = Recipe(filter: filter)
        recipe.exposure = ev - bias
        guard let out = Look.apply(recipe, to: Look.adaptPreview(img)) else { return }
        if let cg = Look.previewContext.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: Look.outputSpace) {
            guard lock.withLock({
                guard self.generation == generation else { return false }
                if let tap = zoomStarted {
                    Self.log.notice("zoom tap to first filtered frame \(Int((ProcessInfo.processInfo.systemUptime - tap) * 1000)) ms")
                    zoomStarted = nil
                }
                latestPreview = (cg, filter, ev, now)
                previewPending = true
                return true
            }) else { return }
            if Diagnostics.enabled, frameCount % 4 == 0, let ungraded = Look.previewContext.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: Look.outputSpace) {
                let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: sb, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any]
                let frame = Diagnostics.Frame(ungraded: ungraded, graded: cg, pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds, uptime: now,
                    info: ["exif": Diagnostics.plain(attachments?[kCGImagePropertyExifDictionary as String]), "filter": filter,
                           "renderEV": ev - bias, "userEV": ev, "targetBias": bias, "crop": k, "size": "\(Int(img.extent.width))x\(Int(img.extent.height))",
                           "pixelFormat": Self.fourCC(CVPixelBufferGetPixelFormatType(pb)), "domain": "ISP video, display-referred",
                           "lookVersion": Look.version, "gradeRevision": Grade.revision])
                lock.withLock { diagnosticFrame = frame }
            }
            #if DEBUG
            if saveReferenceFrame, frameCount >= 24 {
                saveReferenceFrame = false
                let reference = CIImage(cgImage: cg)
                let destination = URL.cachesDirectory.appending(path: "bettercam-color-reference.jpg")
                analysisQueue.async {
                    do {
                        guard let data = Look.jpeg(reference, quality: 0.98) else { return }
                        try data.write(to: destination, options: .atomic)
                        Self.log.notice("Saved one preview reference for \(filter, privacy: .public), render revision \(Look.version)")
                    } catch {
                        Self.log.error("Failed to save preview reference: \(error.localizedDescription)")
                    }
                }
            }
            #endif
            onFrame(PreviewSample(rendered: cg, generation: generation))
        }
    }

    private func analyzeAsync(_ img: CIImage, generation: Int) {
        analyzing = true
        analysisQueue.async {
            let guide = Look.fit(img, 96)
            let bounds = guide.extent.integral
            let width = Int(bounds.width), height = Int(bounds.height)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            Look.context.render(guide, toBitmap: &pixels, rowBytes: width * 16, bounds: bounds,
                                format: .RGBAf, colorSpace: Look.workingSpace)
            let maxima = stride(from: 0, to: pixels.count, by: 4)
                .map { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.sorted()
            self.videoQueue.async {
                self.analyzing = false
                guard !maxima.isEmpty else { return }
                let peak = Double(maxima[Int(0.999 * Double(maxima.count))])
                let clipped = maxima.count - (maxima.firstIndex { $0 >= 0.97 } ?? maxima.count)
                let highlightShare = Double(clipped) / Double(maxima.count)
                self.queue.async {
                    guard self.lock.withLock({ self.generation == generation }) else { return }
                    self.updateBias(highlightShare: highlightShare, peak: peak)
                }
            }
        }
    }
}

extension Camera.Shot {
    /// The look and adjustments at the press. Exposure is finalized from the saved original.
    var provisionalRecipe: Recipe {
        var r = Recipe(filter: filter, crop: crop)
        r.exposure = min(max(exposure, Recipe.exposureRange.lowerBound), Recipe.exposureRange.upperBound)
        if ext == "dng" {
            r.pendingCaptureExposure = true
        }
        return r
    }
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
                guard camera?.didDisplay(sample) == true, let v else { return }
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
