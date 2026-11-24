import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Every edit is a recipe applied to the untouched original, so editing is non-destructive.
/// A recipe = a look + four small finishing sliders (research/newFilters_11_18.md §8: the look does 90% of the work).
struct Recipe: Codable, Equatable {
    static let current = 10 // bump when slider units change; older recipes keep look + crop, sliders reset
    /// Rendering engine. 2 (2026-11-21): every look, the gallery, the editor and every export develop the original RAW
    /// through one pipeline (research/19-photographic-engine.md). Engine 1 recipes routed through a shutter PNG or a
    /// fitted preview match; Library.load migrates them (the old JSON is kept beside the original as `.engine1.json`).
    /// Engine 3 (2026-11-23, research/23): revision 2 develops ProRAW from scene light; migration stores each ProRAW's
    /// exposure normalization (Library.load). Rendering of revision ≤ 1 recipes is unchanged.
    static let engine = 3

    static let exposureRange = -0.7...0.7     // EV on top of the look's render exposure (not capture bias)
    static let contrastRange = -0.08...0.08   // added to the look's curve slope
    static let warmthRange = -0.25...0.25     // added to temperature (±5% R/B). Doc said ±0.04 = ±0.8%: invisible
    static let saturationRange = 0.88...1.12  // × the look's saturation

    var version = Recipe.current
    var engine = Recipe.engine
    var filter = Filter.all[0].id
    var lookRevision = Filter.revision
    var exposure = 0.0
    var contrast = 0.0
    var warmth = 0.0
    var saturation = 1.0
    var crop = 1.0          // zoom crop set at capture (2× = center crop of the main lens)
    var baseExposure = 0.0  // not a slider: the file's own exposure normalization (Look.startingExposure)
    var grainSeed: UInt32?
    /// Engine 1 recipe whose exposure lived in a preview match: Library.load recomputes `baseExposure`. Never saved.
    var needsExposure = false
    var pendingCaptureExposure: Bool?

    enum CodingKeys: String, CodingKey {
        case version, engine, filter, lookRevision, exposure, contrast, warmth, saturation, crop, baseExposure, grainSeed, pendingCaptureExposure
    }
    private enum LegacyKeys: String, CodingKey { case previewMatch }

    func grainSeed(for url: URL) -> UInt32 {
        grainSeed ?? url.lastPathComponent.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    init() {}
    init(filter: String, crop: Double = 1) { self.filter = filter; self.crop = crop }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        crop = try c.decodeIfPresent(Double.self, forKey: .crop) ?? 1
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? filter
        baseExposure = try c.decodeIfPresent(Double.self, forKey: .baseExposure) ?? 0
        lookRevision = try c.decodeIfPresent(Int.self, forKey: .lookRevision) ?? 0
        grainSeed = try? c.decodeIfPresent(UInt32.self, forKey: .grainSeed)
        pendingCaptureExposure = try c.decodeIfPresent(Bool.self, forKey: .pendingCaptureExposure)
        engine = try c.decodeIfPresent(Int.self, forKey: .engine) ?? 1
        if engine < 2, let legacy = try? d.container(keyedBy: LegacyKeys.self), legacy.contains(.previewMatch) {
            needsExposure = true
        }
        guard try c.decodeIfPresent(Int.self, forKey: .version) == Recipe.current else {
            // ponytail: pre-v10 imports stored their −1 compensation in the exposure slider; carry exactly that over
            if let old = try c.decodeIfPresent(Double.self, forKey: .exposure), abs(old + Look.rawCompensation) < 1e-6 {
                baseExposure = old
            }
            return
        }
        exposure = try c.decode(Double.self, forKey: .exposure)
        contrast = try c.decode(Double.self, forKey: .contrast)
        warmth = try c.decode(Double.self, forKey: .warmth)
        saturation = try c.decode(Double.self, forKey: .saturation)
    }

    mutating func resetSliders() { exposure = 0; contrast = 0; warmth = 0; saturation = 1 }

    var selectedFilter: Filter { Filter.named(filter, revision: lookRevision) }

    /// The grade this recipe renders: the look's absolute values, then the slider offsets.
    var grade: Grade {
        var g = selectedFilter.grade
        g.exposure += exposure + baseExposure
        g.contrast += contrast
        if !g.monochrome {
            g.temperature += warmth
            g.saturation *= saturation
        }
        return g
    }
}

/// Rendering = scene-linear RAW light → a film-like *display transform* → the filter's grade.
/// Display transform: AgX structure (Troy Sobotka; Blender's default): inset matrix → per-channel sigmoid in log space →
/// outset, which gives film's natural path to white. White is anchored at a fixed level (`whiteStops`), not fitted to
/// each photo's brightest pixel, so one lamp or glint can't shift the whole tone curve between near-identical frames.
/// Per-channel curves are blended with a hue-preserving (ratio) curve so saturated highlights don't skew red→yellow.
/// The filter's grade (white balance, split tone, hue/sat, black level) is baked into the same 3D LUT.
enum Look {
    // Core Image converts tagged video and RAW into this extended linear working space.
    // The creative grade receives display-linear light and its white anchor from each input.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: workingSpace])
    static let previewContext = CIContext(options: [.workingColorSpace: workingSpace, .cacheIntermediates: false])
    private static let exportContext = CIContext(options: [.workingColorSpace: workingSpace, .cacheIntermediates: false])
    private static let exportLock = NSLock()
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// We underexpose RAW captures by this much (see Camera) to protect highlights, and restore it at decode.
    static let rawCompensation = 1.0
    /// Bump when rendering changes without recipe units changing: gallery thumbnails re-render, edits are kept.
    static let version = 29
    /// Every photo is analyzed (white balance, faces, local tone development) on one decode of this size, whatever size it
    /// is then rendered at, so the thumbnail, the editor, the zoomed detail and the export agree. It's also the editor's image.
    static let guideSide: CGFloat = 1200
    /// Legacy curve only (`legacyCurve`): fixed display white, in stops above mid grey. It assumed RAW clips at ~+4;
    /// the old SDR-clipped decode actually stopped at +2.9…+3.2, so highlights never passed ~0.89.
    /// The calibrated curve instead puts white at each photo's own clip level (`Analysis.clip`).
    static let whiteStops = 4.5
    /// Scales `Grade.saturation` so 1.0 ≈ colorimetric chroma on a ColorChecker (AgX inset/outset alone mutes color).
    /// Measured by checks/main.swift; re-measure if the curve, inset or Grade.hueHold default changes.
    static let chromaNorm = 0.93

    // MARK: - Decode

    /// Diagnostics only (checks/compare): the pre-2026-11-18 decode and tone curve, for before/after renders.
    /// ponytail: delete both flags and their branches once Phase 1 is signed off.
    nonisolated(unsafe) static var legacyDecode = false
    nonisolated(unsafe) static var legacyCurve = false
    /// Diagnostics only (checks/phase2 variant B): the first Phase 2 ProRAW path (Bayer anchor formula; see `proRAWCeiling`).
    nonisolated(unsafe) static var legacyProRAW = false
    /// EXPERIMENTAL, diagnostics only (research/11c §2.6, 12 §5): run the whole look on linear Display P3 numbers with P3 luma
    /// weights, so its clamps sit at the P3 gamut instead of sRGB. Off in the app.
    nonisolated(unsafe) static var workingP3 = false
    /// Luminance weights of the working primaries (Rec.709/sRGB, or Display P3 when `workingP3`).
    static var lumaWeights: (Double, Double, Double) { workingP3 ? (0.2289746, 0.6917385, 0.0792869) : (0.2126, 0.7152, 0.0722) }
    static let sRGBToP3: [[Double]] = [[0.822462, 0.177538, 0], [0.033194, 0.966806, 0], [0.017083, 0.072397, 0.910520]]
    static let p3ToSRGB: [[Double]] = [[1.224940, -0.224940, 0], [-0.042057, 1.042057, 0], [-0.019638, -0.078636, 1.098274]]
    /// Working-space linear RGB ↔ linear sRGB (identity unless `workingP3`). Used by the OkLab print transform.
    static func workingToSRGB(_ r: Double, _ g: Double, _ b: Double, wideGamut: Bool = false) -> (Double, Double, Double) {
        guard workingP3 || wideGamut else { return (r, g, b) }
        let m = p3ToSRGB
        return (m[0][0] * r + m[0][1] * g + m[0][2] * b, m[1][0] * r + m[1][1] * g + m[1][2] * b, m[2][0] * r + m[2][1] * g + m[2][2] * b)
    }
    static func sRGBToWorking(_ c: (Double, Double, Double), wideGamut: Bool = false) -> (Double, Double, Double) {
        guard workingP3 || wideGamut else { return c }
        let m = sRGBToP3, (r, g, b) = c
        return (m[0][0] * r + m[0][1] * g + m[0][2] * b, m[1][0] * r + m[1][1] * g + m[1][2] * b, m[2][0] * r + m[2][1] * g + m[2][2] * b)
    }
    static func transformed(_ img: CIImage, _ m: [[Double]]) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
            "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
            "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
        ])
    }

    /// CIImage property: the decoded image's clip level (scene-linear) = where the tone curve puts display white.
    static let clipKey = "bettercam.clip"
    /// CIImage property: scene brightness EV100 from the file's EXIF (Phase 3B light-mood gate), when present.
    static let evKey = "bettercam.ev"
    /// CIImage property: EXIF ISO (RAW only), so local development knows how much shadow noise a lift would expose.
    private static let profileDevelopedKey = "bettercam.profileDeveloped"
    static let proRAWKey = "BetterCam.ProRAW"
    static let isoKey = "bettercam.iso"

    /// EV100 = log2(N²/t) − log2(ISO/100): how bright the scene really was. Tungsten interiors ≈ 5–8, daylight ≈ 12–15.
    static func sceneEV(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let x = p[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let n = x[kCGImagePropertyExifFNumber as String] as? Double, let t = x[kCGImagePropertyExifExposureTime as String] as? Double,
              let iso = (x[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first, n > 0, t > 0, iso > 0 else { return nil }
        return log2(n * n / t) - log2(iso / 100)
    }
    /// Fallback only, for DNGs without AsShotNeutral. See `neutralClip`.
    static let sensorClip = 2.4

    /// Where a neutral highlight clips in the decode at baselineExposure 0: max/min of the DNG's AsShotNeutral
    /// (= 1/min(R, B) with green = 1). Highlight recovery rebuilds neutrals until the channel with the largest
    /// white-balance gain saturates. Measured within 0.6% on 11 sensor-clipped 17 Pro Bayer DNGs, main and tele,
    /// clips 1.90–3.00 (research/11-phase2-capture.md). ProRAW: same DNG math (WhiteLevel ÷ neutral), but only
    /// verified by checks/phase2 once ProRAW samples exist.
    static func neutralClip(_ url: URL) -> Double {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let n = (p[kCGImagePropertyDNGDictionary as String] as? [String: Any])?["AsShotNeutral"] as? [Double],
              n.count == 3, let lo = n.min(), lo > 0 else { return sensorClip }
        return n.max()! / lo
    }

    /// Neutral ceiling of an Apple ProRAW decode at baselineExposure 0, EDR ≥ 2 (research/11b-proraw-validation.md).
    /// Measured 2.500 on 6 iPhone 17 Pro ProRAWs, 12 and 48 MP (2.489 on one), independent of AnalogBalance; EDR 2 ≡ 4 ≡ 8.
    /// It's the largest neutral the file can represent, touched by ≤ 0.04% of pixels: not a Bayer-style clip plateau
    /// (fusion keeps lamps below it). The Bayer formula can't apply: ProRAW's AsShotNeutral is [1, 1, 1] (white balance
    /// is baked in through AnalogBalance), so it gave 1.0 and clamped the top 1.3 stops (up to 0.9% of the frame) to white.
    static let proRAWCeiling = 2.5

    /// ProRAW only: Apple's net mid-tone exposure minus BaselineExposure, in stops. Goes into `Recipe.baseExposure` once
    /// per photo (Library), not into decode: it costs two decodes (~3 s for 48 MP on a Mac).
    /// Why: Apple splits a ProRAW's exposure between BaselineExposure and the ProfileGainTableMap. We drop the map
    /// (localToneMapAmount 0: it's Apple's local tone mapping), but it also carries a large *global* gain, so BaselineExposure
    /// alone is no consistent exposure: measured 0.26–1.89 stops short of Apple's own, and 12 MP vs 48 MP of the same scene
    /// ended 1.55 stops apart. This takes Apple's net gain at the median pixel (BE + map, no tone curve, no boost) as one
    /// global exposure: Apple's metering decision, not its curve, local contrast or color. 12/48 MP pairs then agree within 0.4 stop.
    static func proRAWExposure(_ url: URL) -> Double {
        func greens(apple: Bool) -> [Float] {
            guard let r = CIRAWFilter(imageURL: url) else { return [] }
            r.scaleFactor = Float(min(1, 256 / max(r.nativeSize.width, r.nativeSize.height)))
            r.boostAmount = 0; r.boostShadowAmount = 0; r.shadowBias = 0; r.isGamutMappingEnabled = false
            r.extendedDynamicRangeAmount = 2
            r.localToneMapAmount = apple ? 1 : 0
            if !apple { r.baselineExposure = 0 }
            guard let img = r.outputImage else { return [] }
            let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
            var p = [Float](repeating: 0, count: w * h * 4)
            context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: context.workingColorSpace)
            return stride(from: 1, to: p.count, by: 4).map { p[$0] }
        }
        let a = greens(apple: true), l = greens(apple: false)
        var lr: [Double] = []
        for (x, y) in zip(a, l) where y > 0.002 && x > 0 { lr.append(log2(Double(x / y))) }
        guard !lr.isEmpty, let be = CIRAWFilter(imageURL: url)?.baselineExposure else { return 0 }
        lr.sort()
        return lr[lr.count / 2] - Double(be)
    }

    static func captureBias(_ url: URL) -> Double {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return 0 }
        return exif[kCGImagePropertyExifExposureBiasValue as String] as? Double ?? 0
    }

    /// The exposure a new photo's recipe starts from (`Recipe.baseExposure`): decode restores a fixed `rawCompensation`,
    /// so this carries what the camera actually did (EXIF bias; imports: the photographer's bias is kept, net 0),
    /// plus the ProRAW correction above.
    static func startingExposure(_ url: URL, captured: Bool) -> Double {
        guard url.pathExtension.lowercased() == "dng" else { return 0 }
        let e = -rawCompensation - (captured ? captureBias(url) : 0)
        return isProRAW(url) ? e + proRAWExposure(url) : e
    }

    /// ProRAW is a demosaiced LinearRaw DNG; Bayer carries a CFA pattern.
    static func isProRAW(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let dng = p[kCGImagePropertyDNGDictionary as String] as? [String: Any] else { return false }
        return dng["CFAPlaneColor"] == nil
    }

    /// Scene-linear decode, center-cropped by `crop`. Look-independent: every look starts from these exact pixels.
    /// RAW: Apple's tone curve, local tone mapping (HDR flattening) and sharpening are all off. What's left is
    /// demosaic + the sensor's color matrix + light noise reduction, which any RAW developer has to do. BetterCam's own
    /// tone development (`localDevelopment`, then the base curve in `develop`) replaces what was switched off; the look
    /// then grades display light, as it does on the viewfinder's video frames.
    /// Measured on the 17 Pro (research/10-phase1-pipeline.md): with EDR 0 Core Image rolls off above ~0.6 and clips
    /// at 1.0; with baseline exposure applied inside the filter EDR 1 still caps at 3.0. So decode at EDR 2 with
    /// baseline 0 and exposure 0 (EDR 1 soft-compresses the last ~0.05 below 3.0; EDR 2 ≡ EDR 4 bit for bit, measured),
    /// then apply the gain as a plain float multiply, where nothing can clip.
    /// Two separate things are in that gain:
    /// - BaselineExposure: Apple's per-file *rendering* offset (0–1.36 stops measured; larger on tele). It says how bright
    ///   the camera maker wants the linear data shown. It is not light we withheld and not recoverable sensor exposure.
    /// - `rawCompensation`: a fixed +1 EV. The file's actual capture bias (and, for ProRAW, Apple's metering share of the
    ///   gain table) is carried by `Recipe.baseExposure` (startingExposure), applied once in the grade. Nothing else
    ///   adds exposure, so neither is applied twice.
    /// ProRAW (Apple's linear recipe, WWDC21 10160): boost 0 removes its default tone curve, localToneMapAmount 0 its
    /// gain-table local tone map, baselineExposure 0 its brightness offset. What's left is Apple's fused, demosaiced,
    /// scene-referred linear data in the DNG's own color profile.
    static func decode(_ url: URL, crop: Double = 1, maxSide: CGFloat? = nil, useProRAWProfile: Bool = false) -> CIImage? {
        var img: CIImage?
        var clip = 1.0 // display-referred input (HEIC): already tone-mapped to SDR white
        var iso: Double?
        var proRAW = false
        var profileDeveloped = false
        if url.pathExtension.lowercased() == "dng" {
            guard let raw = CIRAWFilter(imageURL: url) else { return nil }
            if let maxSide {
                let side = max(raw.nativeSize.width, raw.nativeSize.height) / crop
                raw.scaleFactor = Float(min(1, maxSide / side))
            }
            let exif = raw.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first
            proRAW = isProRAW(url)
            profileDeveloped = proRAW && useProRAWProfile
            if profileDeveloped {
                // The DNG's baseline, gain map, and SDR curve supply display light in one decode.
                img = raw.outputImage
            } else {
                raw.boostAmount = 0
                raw.boostShadowAmount = 0
                raw.localToneMapAmount = 0
                raw.sharpnessAmount *= 0.6 // mild, like a good camera; Apple's full amount halos
                if proRAW { // rest of Apple's linear ProRAW recipe (WWDC21 10160). Bayer: both measured as no-ops (Phase 1)
                    raw.shadowBias = 0
                    raw.isGamutMappingEnabled = false
                }
                if legacyDecode {
                    raw.exposure = Float(rawCompensation)
                    img = raw.outputImage
                    clip = 0.18 * pow(2, whiteStops)
                } else {
                    let gain = pow(2, Double(raw.baselineExposure) + rawCompensation)
                    raw.baselineExposure = 0
                    raw.extendedDynamicRangeAmount = 2
                    img = raw.outputImage.map { scaled($0, gain) }
                    clip = (proRAW && !legacyProRAW ? proRAWCeiling : neutralClip(url)) * gain
                }
            }
        } else { // processed HEIC fallback (cameras without RAW)
            img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]).map { im in
                guard let maxSide else { return im }
                let s = min(1, maxSide * crop / max(im.extent.width, im.extent.height))
                return im.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
        }
        guard let img else { return nil }
        let cropped = centerCrop(img, crop)
        var props: [String: Any] = [clipKey: clip]
        props[evKey] = sceneEV(url)
        props[isoKey] = iso
        props[proRAWKey] = proRAW
        props[profileDevelopedKey] = profileDeveloped
        return cropped.settingProperties(props)
    }

    private static func centerCrop(_ img: CIImage, _ crop: Double) -> CIImage {
        guard crop > 1 else { return img }
        let e = img.extent
        let w = (e.width / crop).rounded(), h = (e.height / crop).rounded()
        let x = (e.midX - w / 2).rounded(), y = (e.midY - h / 2).rounded()
        return img.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    static func scaled(_ img: CIImage, _ k: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
    }

    /// Render once to memory (half float: unclipped, ~0.1% precision) so slider changes only re-run the look.
    static func materialize(_ img: CIImage) -> CIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: workingSpace)
            .map { CIImage(cgImage: $0).settingProperties(img.properties) }
    }

    // MARK: - Look

    /// AgX "inset": pulls colors slightly toward the achromatic axis before the curve so they desaturate toward white naturally.
    static let inset: [[Double]] = [
        [0.842479062253094, 0.0784335999999992, 0.0792237451477643],
        [0.0423282422610123, 0.878468636469772, 0.0791661274605434],
        [0.0423756549057051, 0.0784336, 0.879142973793104],
    ]
    static let outset: [[Double]] = [
        [1.19687900512017, -0.0980208811401368, -0.0990297440797205],
        [-0.0528968517574562, 1.15190312990417, -0.0989611768448433],
        [-0.0529716355144438, -0.0980434501171241, 1.15107367264116],
    ]

    /// What the look needs to know about a photo's light. Measure once per photo, reuse while editing.
    struct Analysis {
        var wb: (Double, Double, Double)  // scene-aware white-balance gains (green = 1)
        var subjectMask: CIImage? = nil   // Vision person mask (stills only), any size; scaled at apply time
        var subjectGap = 0.0              // stops the subject sits below the background; 0 unless trusted (subjectGap())
        var clip = 1.0                    // scene-linear level the source clips at (decode's `clipKey`); 1 = SDR input
        // Phase 3B
        var illuminant = (T: 0.0, G: 0.0, confidence: 0.0) // residual cast left by as-shot WB (log units, see wbGains)
        var faces: [CGRect] = []          // Vision face boxes, normalized, origin bottom-left (same as Core Image)
        var maskTrusted = false           // person mask passed subjectGap's coverage/decisiveness test
        var faceGap = 0.0                 // stops the face sits below the background (negative: brighter)
        var sceneEV: Double? = nil        // EXIF scene brightness (EV100), nil for files without it
        // Phase 5
        var skinTarget: (L: Double, a: Double, b: Double)? = nil // median OkLab of the faces' inner boxes (skinRegion's target)
        var selectiveStrength = 1.0       // scales the selective lift/background moves; the viewfinder ramps it so nothing pops
        var highlightShare = 0.0          // share of the 96 px copy at ≥ 97% of `clip`: exposure policy input (viewfinder)
        var peak = 0.0                    // 99.9th percentile of the max channel ÷ the source's clip property
        // Engine 2: local tone development (stills only, see localDevelopment)
        var localGain: CIImage? = nil     // small grid of log2 gain, encoded (stops + 2) / 4; nil = none (flat scene, video, HEIC)
        var localRange = 0.0              // scene dynamic range the development measured, in stops (p2…p98 luminance)
        var raw = false                   // stills from a RAW: `develop` renders them to display light before the look
    }

    /// Scene light, as an interpretable label for reports and debugging. Every rendering decision uses the continuous
    /// T/G/confidence numbers instead, so nothing jumps between adjacent viewfinder frames.
    static func lightMood(_ a: Analysis, meanY: Double? = nil) -> String {
        let (T, G, c) = a.illuminant
        if c < 0.3 { return "colored/mixed light (low confidence: left as shot)" }
        let ev = a.sceneEV.map { String(format: " EV %.1f", $0) } ?? " no EXIF"
        if T > 0.12, let e = a.sceneEV, e > 10.5 { return "warm but bright\(ev): golden hour or warm materials (kept)" }
        if T > 0.35 { return "tungsten / warm bulb\(ev)" }
        if T > 0.12 { return "warm interior light\(ev)" }
        if T < -0.1 { return "cool (shade/overcast)" }
        return abs(G) > 0.08 ? "neutral, tinted (fluorescent/LED)" : "neutral"
    }

    /// Selective (local) finishing plan for one photo: masks plus the measured EV moves. nil = global-only fallback
    /// (no person, untrusted mask, viewfinder, or a look without local controls).
    struct Selective { let person: CIImage; let face: CIImage?; let lift: Double; let background: Double; var skin: CIImage? = nil }

    /// Masks refined to the full image: Vision's 512 px mask is upsampled by CIEdgePreserveUpsampleFilter, guided by the
    /// photo's own edges, so hair and straps follow the picture rather than a blurry blob; then lightly feathered.
    static func selectivePlan(_ gr: Grade, _ a: Analysis, guide: CIImage) -> Selective? {
        guard gr.faceLift > 0 || gr.backgroundTone > 0 || gr.skinChromaLocal != 1, a.maskTrusted, let m = a.subjectMask else { return nil }
        let e = guide.extent
        let grey = CIVector(x: 1, y: 0, z: 0, w: 0) // Vision's one-component mask → the same value in R, G and B
        let small = m.applyingFilter("CIColorMatrix", parameters: ["inputRVector": grey, "inputGVector": grey, "inputBVector": grey])
        let g = guide.applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let refined = g.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": small, "inputSpatialSigma": 3, "inputLumaSigma": 0.15,
        ])
        .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        .clampedToExtent().applyingGaussianBlur(sigma: max(e.width, e.height) * 0.0012)
        .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        .cropped(to: e)
        // face: soft ellipse per detected face (box grown to forehead/jaw), only where the person mask agrees
        var face: CIImage?
        for f in a.faces {
            let w = f.width * e.width, h = f.height * e.height * 1.25
            let cx = e.minX + f.midX * e.width, cy = e.minY + (f.midY + f.height * 0.05) * e.height
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 0.55, "inputRadius1": 1.0,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!
            let ellipse = disc.transformed(by: CGAffineTransform(scaleX: w * 0.62, y: h * 0.62).concatenating(CGAffineTransform(translationX: cx, y: cy)))
                .cropped(to: e)
            face = face.map { ellipse.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? ellipse
        }
        face = face?.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: refined]).cropped(to: e)
        // measured, bounded moves: a face darker than its surroundings gets up to `faceLift`; a face already brighter gets none
        let lift = (face == nil ? 0 : min(gr.faceLift, max(0, 0.15 + 0.5 * a.faceGap))) * a.selectiveStrength
        let bg = min(gr.backgroundTone, max(0, 0.5 * a.subjectGap + (a.faceGap > 0 ? 0.5 * a.faceGap : 0))) * a.selectiveStrength
        let skin = gr.skinRegion ? face.flatMap { f in a.skinTarget.flatMap { skinRegion(guide: g, target: $0, person: refined, face: f, extent: e) } } : nil
        return Selective(person: refined, face: face, lift: lift, background: bg, skin: skin)
    }

    /// Phase 4: this person's exposed skin, not just the face ellipse. The face's own skin color (median OkLab of the inner face
    /// box, `skinTarget`) defines the target, so every complexion is matched to itself rather than to one "skin" hue; a 3D LUT turns each
    /// pixel's distance from it into a weight (tight in a/b, loose in L for shading), multiplied by the person mask so
    /// a same-colored wall can't qualify, then unioned with the face ellipse.
    /// `guide` is the display-encoded photo at the origin (as in selectivePlan); returns a mask on extent `e`.
    static func skinRegion(guide: CIImage, target: (L: Double, a: Double, b: Double), person: CIImage, face: CIImage, extent e: CGRect) -> CIImage? {
        let ge = guide.extent
        let f = CIFilter.colorCube()
        f.inputImage = guide; f.cubeDimension = Float(skinCubeSize)
        f.cubeData = skinCube(target)
        guard let w = f.outputImage else { return nil }
        let skin = w.transformed(by: CGAffineTransform(translationX: e.minX - ge.minX, y: e.minY - ge.minY))
            .clampedToExtent().applyingGaussianBlur(sigma: max(e.width, e.height) * 0.0015).cropped(to: e) // no pixel speckle
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: person])
        return face.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: skin]).cropped(to: e)
    }

    /// Median OkLab of every face's inner box (cheeks/forehead/nose, avoiding hair, eyes-heavy edges and background), from
    /// the display-encoded photo. nil when fewer than 12 usable samples. Measured once in `analyze`, not per render.
    static func skinTarget(guide: CIImage, faces: [CGRect]) -> (L: Double, a: Double, b: Double)? {
        let ge = guide.extent
        var labs: [(Double, Double, Double)] = []
        for f in faces {
            let box = CGRect(x: ge.minX + (f.minX + f.width * 0.25) * ge.width, y: ge.minY + (f.minY + f.height * 0.2) * ge.height,
                             width: f.width * 0.5 * ge.width, height: f.height * 0.55 * ge.height).integral
            guard box.width >= 4, box.height >= 4 else { continue }
            let k = 24 / max(box.width, box.height)
            let small = guide.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": k])
            let se = small.extent.integral, w = Int(se.width), h = Int(se.height)
            guard w > 0, h > 0 else { continue }
            var px = [Float](repeating: 0, count: w * h * 4)
            context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: se, format: .RGBAf, colorSpace: nil)
            for i in stride(from: 0, to: px.count, by: 4) {
                let lab = OkLab.from((toLinear(Double(px[i])), toLinear(Double(px[i + 1])), toLinear(Double(px[i + 2]))))
                if lab.0 > 0.25 && lab.0 < 0.95 && hypot(lab.1, lab.2) > 0.015 { labs.append(lab) } // not shadow/specular/grey
            }
        }
        guard labs.count >= 12 else { return nil }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        // ponytail: one color per photo (median of all faces); two people with very different skin get a looser match for both
        return (med(labs.map(\.0)), med(labs.map(\.1)), med(labs.map(\.2)))
    }

    private static var skinCubeCache: (key: [Double], data: Data)?
    private static let skinCubeSize = 25
    private static let skinCubeColors: [(Double, Double, Double)] = {
        let levels = (0..<skinCubeSize).map { toLinear(Double($0) / Double(skinCubeSize - 1)) }
        var colors: [(Double, Double, Double)] = []
        for b in levels { for g in levels { for r in levels {
            colors.append(OkLab.from((r, g, b)))
        }}}
        return colors
    }()
    /// The skin-weight cube for one target. The viewfinder re-renders the same target ~30×/s: cached (one entry).
    static func skinCube(_ t: (L: Double, a: Double, b: Double)) -> Data {
        let key = [t.L, t.a, t.b]
        if let c = lutLock.withLock({ skinCubeCache }), c.key == key { return c.data }
        let L0 = t.L, a0 = t.a, b0 = t.b
        var cube = [Float](repeating: 1, count: skinCubeColors.count * 4)
        for (index, lab) in skinCubeColors.enumerated() {
            let i = index * 4
            let dab = hypot(lab.1 - a0, lab.2 - b0), dL = lab.0 - L0
            // full weight within 0.025 in a/b (≈ 2.5 ΔE) of the face, gone by 0.055; lightness may vary −0.3…+0.15 (shade vs lit)
            let wC = 1 - Grade.smooth(0.025, 0.055, dab)
            let wL = Grade.smooth(-0.32, -0.2, dL) * (1 - Grade.smooth(0.12, 0.22, dL))
            let v = Float(wC * wL)
            cube[i] = v; cube[i + 1] = v; cube[i + 2] = v
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        lutLock.withLock { skinCubeCache = (key, data) }
        return data
    }

    /// Scene-linear gain map from the plan: background × 2^−bg, face × 2^lift. Exposure only, so texture and the
    /// face's own directional shadows keep their ratios; the tone curve then renders them like any other light.
    static func gainMap(_ s: Selective, extent e: CGRect) -> CIImage {
        let kb = pow(2, -s.background), kf = pow(2, s.lift) - 1
        var gain = s.person.applyingFilter("CIColorMatrix", parameters: [ // kb + (1 − kb)·person
            "inputRVector": CIVector(x: 1 - kb, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1 - kb, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1 - kb, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: kb, y: kb, z: kb, w: 1),
        ])
        if let f = s.face, kf > 0 {
            let fg = f.applyingFilter("CIColorMatrix", parameters: [ // 1 + kf·face
                "inputRVector": CIVector(x: kf, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: kf, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: kf, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            gain = fg.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain])
        }
        return gain.cropped(to: e)
    }

    /// The one development every view of a photo shares: the scene-linear decode at `maxSide` (nil = native resolution
    /// after the recipe's crop) plus the analysis, always measured on the `guideSide` decode so it doesn't depend on output
    /// size. Look-independent: no recipe field but the crop reaches the decode or the analysis.
    /// Revision 2 (research/23): every RAW, ProRAW included, is developed from scene-linear data by BetterCam alone.
    /// Revision ≤ 1 ProRAW keeps Apple's profile rendering (boost curve, gain-table local tone map), so saved photos
    /// render exactly as before until the user picks the current rendering.
    static func sceneReferred(_ r: Recipe) -> Bool { r.lookRevision >= 2 }

    static func photo(_ url: URL, recipe: Recipe, maxSide: CGFloat? = nil) -> (CIImage, Analysis)? {
        guard let decoded = decode(url, crop: recipe.crop, maxSide: guideSide, useProRAWProfile: true),
              let guide = materialize(decoded) else { return nil }
        let analysis = photoAnalysis(guide, exposure: recipe.baseExposure, scene: sceneReferred(recipe))
        if let maxSide, maxSide <= guideSide { return (fit(guide, maxSide), analysis) }
        return decode(url, crop: recipe.crop, maxSide: maxSide, useProRAWProfile: true).map { ($0, analysis) }
    }

    static func captureDevelopment(_ url: URL, recipe: Recipe) -> (Recipe, CIImage, Analysis)? {
        guard let decoded = decode(url, crop: recipe.crop, maxSide: guideSide, useProRAWProfile: true),
              let guide = materialize(decoded) else { return nil }
        var normalized = recipe
        if recipe.pendingCaptureExposure == true {
            normalized.baseExposure = guide.properties[profileDevelopedKey] as? Bool == true ? 0 : startingExposure(url, captured: true)
            normalized.pendingCaptureExposure = nil
        }
        return (normalized, guide, photoAnalysis(guide, exposure: normalized.baseExposure, scene: sceneReferred(recipe)))
    }

    private static func photoAnalysis(_ guide: CIImage, exposure: Double, scene sceneReferred: Bool = false) -> Analysis {
        var analysis: Analysis
        if (guide.properties[clipKey] as? Double ?? 1) > 1 { // RAW: measure the look's inputs on the developed light, like the viewfinder
            let scene = analyze(guide, develop: true, highlights: sceneReferred ? sceneHighlights : (1, 0.42, 0))
            var dev = scene; dev.raw = true
            let developed = sceneReferred ? sceneDevelop(guide, dev, exposure: exposure) : develop(guide, dev, exposure: exposure)
            analysis = analyze(developed, subject: true)
            if sceneReferred { // one stop of shoulder above the brightest content (never past the file's ceiling): sky keeps tone
                analysis.clip = min(developed.properties[clipKey] as? Double ?? analysis.clip, analysis.clip * sceneHeadroom)
            }
            analysis.raw = true; analysis.localGain = scene.localGain; analysis.localRange = scene.localRange
        } else {
            analysis = analyze(guide, subject: true)
        }
        return analysis
    }

    /// Downscale (never up) so the long side is at most `side`. Scene-linear in, scene-linear out.
    static func fit(_ img: CIImage, _ side: CGFloat) -> CIImage {
        let k = side / max(img.extent.width, img.extent.height)
        guard k < 1 else { return img }
        return img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": k]).settingProperties(img.properties)
    }

    static func apply(_ r: Recipe, to base: CIImage, analysis: Analysis? = nil, source: URL? = nil) -> CIImage {
        var grade = r.grade, input = base, analysis = analysis
        if base.properties[profileDevelopedKey] as? Bool == true {
            grade.exposure -= r.baseExposure // the profile already supplies the file's baseline exposure
        } else if let analysis, analysis.raw {
            grade.exposure -= r.baseExposure
            input = sceneReferred(r) ? sceneDevelop(base, analysis, exposure: r.baseExposure) : develop(base, analysis, exposure: r.baseExposure)
        }
        if sceneReferred(r), analysis?.raw != true, (base.properties[clipKey] as? Double ?? 1) <= 1.01 {
            // ProRAW's Apple profile, the viewfinder and HEIC all enter the same look from SDR display light.
            input = sceneFromDisplay(base)
            analysis?.clip *= 0.18 * pow(2, displayWhiteStops)
        }
        let graded = apply(grade, to: input, analysis: analysis)
        guard grade.grain > 0 else { return graded }
        return grain(graded, amount: grade.grain, cells: r.filter == Filter.leicaM6.id ? 920 : 2250,
                     seed: source.map { r.grainSeed(for: $0) } ?? r.grainSeed ?? 0)
    }

    /// Engine 1 sidecars (viewfinder PNG, ISP TIFF). No longer written or read; Library.delete still removes them.
    static func shutterURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("png")
    }

    static func previewURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("isp.tiff")
    }

    static func renderPhoto(_ url: URL, recipe: Recipe, maxSide: CGFloat? = nil) -> CIImage? {
        photo(url, recipe: recipe, maxSide: maxSide).map { apply(recipe, to: $0.0, analysis: $0.1, source: url) }
    }

    /// The finished photograph at native resolution (after the recipe's crop): Save to Photos and Share both use it.
    /// `analysis`: the editor's, so the export is the very rendering on screen; nil measures it the same way.
    static func exportJPEG(_ url: URL, recipe: Recipe, analysis: Analysis? = nil) -> Data? {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        guard writeJPEG(url, recipe: recipe, analysis: analysis, to: destination) else { return nil }
        return try? Data(contentsOf: destination)
    }

    static func writeJPEG(_ url: URL, recipe: Recipe, analysis: Analysis?, to destination: URL) -> Bool {
        exportLock.withLock {
            autoreleasepool {
                guard let a = analysis ?? photo(url, recipe: recipe, maxSide: guideSide)?.1,
                      let base = decode(url, crop: recipe.crop, useProRAWProfile: true) else { return false }
                let image = apply(recipe, to: base, analysis: a, source: url)
                let metadata = exportProperties(source: url, recipe: recipe, renderedFrom: url.pathExtension.lowercased())
                defer { exportContext.clearCaches() }
                if image.extent.width * image.extent.height > 8_000_000 {
                    return tiledJPEG(image, metadata: metadata, to: destination)
                }
                do {
                    try exportContext.writeJPEGRepresentation(of: image.settingProperties(metadata), to: destination,
                        colorSpace: outputSpace,
                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
                    return true
                } catch { return false }
            }
        }
    }

    /// Native-resolution pixels of one region, for the zoomed editor: the export's rendering, cropped (`rect` in output
    /// pixels, origin bottom-left) and scaled to `scale`. Core Image only develops the requested region.
    static func renderDetail(_ url: URL, recipe: Recipe, analysis: Analysis, rect: CGRect, scale: CGFloat) -> CGImage? {
        exportLock.withLock { autoreleasepool { () -> CGImage? in
        guard let base = decode(url, crop: recipe.crop, useProRAWProfile: true) else { return nil }
        let r = rect.intersection(base.extent).integral
        guard !r.isEmpty else { return nil }
        let img = apply(recipe, to: base, analysis: analysis, source: url).cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": min(1, scale)])
        defer { exportContext.clearCaches() }
        return exportContext.createCGImage(img, from: img.extent.integral, format: .RGBA8, colorSpace: outputSpace)
        }}
    }
    private static let detailLock = NSLock() // one zoomed region at a time

    /// Native output size after the crop, without decoding pixels.
    static func outputSize(_ url: URL, crop: Double) -> CGSize? {
        decode(url, crop: crop)?.extent.size
    }

    private static func tiledJPEG(_ image: CIImage, metadata: [String: Any], to url: URL) -> Bool {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard let raster = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: outputSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        // One final 8-bit raster. Keep wide, high-precision filter intermediates local to each strip.
        for row in stride(from: 0, to: height, by: 1024) {
            let rows = min(1024, height - row)
            let bounds = CGRect(x: extent.minX, y: extent.minY + CGFloat(row),
                                width: CGFloat(width), height: CGFloat(rows))
            let ok = autoreleasepool {
                guard let tile = exportContext.createCGImage(image, from: bounds, format: .RGBA8,
                                                             colorSpace: outputSpace) else { return false }
                raster.draw(tile, in: CGRect(x: 0, y: row, width: width, height: rows))
                return true
            }
            guard ok else { return false }
        }
        guard let final = raster.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImage(destination, final, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func apply(_ gr: Grade, to source: CIImage, analysis: Analysis? = nil) -> CIImage {
        let a = analysis ?? analyze(source, subject: !gr.print.wideGamut)
        let gr = gr.resolved(sceneEV: a.sceneEV) // Phase 4 night deltas; identity for looks without them
        let inP3 = workingP3 || gr.print.wideGamut
        let base = inP3 ? transformed(source, sRGBToP3) : source
        // 1. exposure + white balance + AgX inset, as one linear matrix
        let g = pow(2, gr.exposure)
        let auto = [pow(a.wb.0, gr.autoWB), 1.0, pow(a.wb.2, gr.autoWB)]
        var wb = [auto[0] * (1 + 0.2 * gr.temperature), auto[1] * (1 - 0.12 * gr.tint), auto[2] * (1 - 0.2 * gr.temperature)]
        // Phase 3B: bounded share of a *measured* residual cast, only warm side (cool light is left alone), confidence-gated
        if gr.warmAdapt > 0 || gr.tintAdapt > 0 {
            // a warm residual in a bright scene is warm *material* (brick, sand) or golden-hour light: leave it. Only dim,
            // interior-level scenes (EV ≲ 9) count as artificial warm light. No EXIF: half weight.
            let c = a.illuminant.confidence * (a.sceneEV.map { 1 - Grade.smooth(8.5, 10.5, $0) } ?? 0.5)
            let T = min(max(a.illuminant.T, 0), 0.6) * c, G = min(max(a.illuminant.G, -0.2), 0.2) * c
            let dr = -gr.warmAdapt * T - gr.tintAdapt * G, db = gr.warmAdapt * T - gr.tintAdapt * G
            wb[0] *= exp(dr); wb[2] *= exp(db)
        }
        func row(_ i: Int) -> CIVector {
            if gr.monochrome {
                // Positive, unit-sum panchromatic mix in linear light, before the print curve.
                let m = gr.monoMix
                return CIVector(x: m[0] * g, y: m[1] * g, z: m[2] * g, w: 0)
            }
            return CIVector(x: inset[i][0] * g * wb[0], y: inset[i][1] * g * wb[1], z: inset[i][2] * g * wb[2], w: 0)
        }
        // 2. white anchor: the photo's clip level after this grade's exposure. Exposure metadata, not image content,
        // so a single specular can't move the curve; grey and midtone slope don't depend on it (see photographic()).
        let white = legacyCurve ? whiteStops : ((log2(a.clip / 0.18) + gr.exposure) * 20).rounded() / 20
        let top = lutCeiling(white: white, wideGamut: gr.print.wideGamut)
        let s = 1 / top
        let diffused = gr.print.wideGamut ? highlightDiffusion(base, clip: a.clip, amount: gr.bloom) : bloom(base, amount: gr.bloom)
        var exposed = diffused
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2)])
        // 1b. a dark, clearly segmented person gets a small lift (doc §7.6: ≤ +0.15 EV, never a fake key light)
        let lift = subjectLift(gap: a.subjectGap, maxEV: gr.subjectLift)
        if lift > 0.001, let m = a.subjectMask {
            let e = exposed.extent, k = pow(2, lift)
            let mask = m.transformed(by: CGAffineTransform(scaleX: e.width / m.extent.width, y: e.height / m.extent.height))
                .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
                .clampedToExtent().applyingGaussianBlur(sigma: max(e.width, e.height) * 0.006).cropped(to: e) // feathered
            let lifted = exposed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
            exposed = lifted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: exposed, kCIInputMaskImageKey: mask,
            ])
        }
        // 1c. Phase 3B selective pass (stills only: needs a trusted Vision mask), see selectivePlan()
        let plan = selectivePlan(gr, a, guide: source.applyingFilter("CILinearToSRGBToneCurve"))
        if let plan, plan.lift > 0.001 || plan.background > 0.001 {
            exposed = gainMap(plan, extent: exposed.extent)
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: exposed]).cropped(to: exposed.extent)
        }
        let shaped = exposed
            // into 0…1 for the LUT: clamp, normalize, cube-root shaper (keeps precision in the shadows)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: top, y: top, z: top, w: 1),
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.0 / 3.0])
        // 3. display transform + grade
        let cube = CIFilter.colorCube()
        cube.inputImage = shaped
        cube.cubeDimension = Float(lutSize)
        cube.cubeData = cachedLUT(gr, white: white)
        var graded = cube.outputImage
        // skin chroma on the face only: a second LUT (same grade, skin gate × skinChromaLocal) blended by the face mask
        // (face ellipse ∩ person). Not the person mask: that includes clothing and hair, e.g. a mustard hoodie at skin hue.
        // ponytail: necks/arms/hands outside the face ellipse get the global skin gate only; add a skin-colour region grow if that shows.
        if let plan, let faceMask = plan.skin ?? plan.face, gr.skinChromaLocal != 1, let g0 = graded {
            var gs = gr; gs.print.on = true; gs.print.skinChroma *= gr.skinChromaLocal
            let c2 = CIFilter.colorCube()
            c2.inputImage = shaped; c2.cubeDimension = Float(lutSize); c2.cubeData = cachedLUT(gs, white: white)
            graded = c2.outputImage?.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: g0, kCIInputMaskImageKey: faceMask,
            ]).cropped(to: g0.extent)
        }
        // The cube holds display-encoded values: Core Image stores cube data at ~8-bit precision, which in linear light
        // posterizes the shadows (only a few levels below 1%). Encoded, the steps are perceptually even.
        var display = graded.map { localContrast(microcontrast($0, amount: gr.microcontrast), amount: gr.localContrast) }?
            .applyingFilter("CISRGBToneCurveToLinear") ?? base
        if inP3 { display = transformed(display, p3ToSRGB) } // P3 numbers back to the working space Core Image expects
        return display.cropped(to: source.extent)
    }

    /// Reads a 96px copy on the CPU. The camera's as-shot WB is the prior; this corrects what it got wrong.
    /// Apple's as-shot WB under warm bulbs can be far off (measured: white paper under ~2700K decoded as R×1.7, B×0.46),
    /// so we can't look only for surfaces that are *already* near-grey. Instead, a candidate white is any surface that
    /// sits on the warm↔cool line light sources fall on (small green/magenta), within a plausible range. White paper
    /// under a bulb qualifies; yellow signs, wood, foliage and sky don't. The estimate is the brightness-weighted median,
    /// so a small bright window into a daylight room can't outvote the room you're standing in.
    /// The cast is then corrected per axis (research §7): temperature mostly (a little warmth is kept), tint almost fully.
    /// Both fade out when few candidates exist (neon, stage light): then the light's color is the point.
    /// `subject`: also run Vision person segmentation (stills; too slow to be worth it per viewfinder frame).
    static func analyze(_ img: CIImage, subject: Bool = false, develop: Bool = false, highlights: (start: Float, slope: Float, sky: Float) = (1, 0.42, 0)) -> Analysis {
        let e = img.extent
        let n = 96
        let scale = Double(n) / max(e.width, e.height)
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        let clip = (img.properties[clipKey] as? Double) ?? 1
        guard w > 0, h > 0 else { return Analysis(wb: (1, 1, 1), clip: clip) }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: small.extent, format: .RGBAf, colorSpace: nil)

        // Stills: local tone development first, so white balance, the white anchor and face/background gaps below are
        // all measured on the light the curve will actually receive.
        var local: (gain: CIImage, range: Double)?
        if develop, clip > 1 {
            let iso = img.properties[isoKey] as? Double ?? 100
            local = localDevelopment(&px, w: w, h: h, iso: iso, highlights: highlights)
        }
        var white = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { white = max(white, Double(max(px[i], px[i + 1], px[i + 2]))) }

        // candidate whites: well-exposed, unclipped, on the illuminant line (T = warm↔cool, G = green↔magenta, log units)
        var cands: [(T: Double, G: Double, w: Double)] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let y = 0.25 * r + 0.5 * g + 0.25 * b
            guard y > 0.03, min(r, g, b) > 1e-4, max(r, g, b) < white * 0.95 else { continue } // not noise, not clipped
            let lr = log(g / r), lb = log(g / b)
            let T = (lb - lr) / 2, G = -(lr + lb) / 2
            // ponytail: fixed window. Cool side is tight (Apple's AWB handles daylight; sky must not count),
            // warm side wide (tungsten). Warm-colored materials (skin, sand) can still count; tune with real captures.
            guard (-0.25...0.85).contains(T), (-0.15...0.3).contains(G) else { continue }
            cands.append((T, G, y))
        }
        // White anchor = the photo's brightest real content, not the file's clip. A RAW's clip sits 1.2–2.3 stops above the
        // viewfinder's video white (2^rawCompensation); anchoring there reserved shoulder for highlights most scenes don't have,
        // so saved photos came out grey and flat next to the viewfinder. 99.5th percentile of the max channel (a lamp or
        // specular can't move it), never below the viewfinder's white, never above the clip. Video/HEIC: unchanged.
        var peaks = stride(from: 0, to: px.count, by: 4).map { Double(max(px[$0], px[$0 + 1], px[$0 + 2])) }
        peaks.sort()
        let p995 = peaks.isEmpty ? clip : peaks[min(peaks.count - 1, Int(0.995 * Double(peaks.count)))]
        let floorWhite = min(clip, pow(2, rawCompensation))
        var result = Analysis(wb: (1, 1, 1), clip: min(clip, max(floorWhite, p995)))
        result.sceneEV = img.properties[evKey] as? Double
        result.localGain = local?.gain
        result.localRange = local?.range ?? 0
        if !peaks.isEmpty, clip > 0 { // exposure policy inputs (Camera.updateBias); no effect on rendering
            result.peak = peaks[min(peaks.count - 1, Int(0.999 * Double(peaks.count)))] / clip
            result.highlightShare = Double(peaks.count - (peaks.firstIndex { $0 >= 0.97 * clip } ?? peaks.count)) / Double(peaks.count)
        }
        if !cands.isEmpty {
            func median(_ v: [(Double, Double)]) -> Double { // weighted median of (value, weight)
                let sorted = v.sorted { $0.0 < $1.0 }, half = sorted.reduce(0) { $0 + $1.1 } / 2
                var acc = 0.0
                for (x, wt) in sorted { acc += wt; if acc >= half { return x } }
                return sorted.last!.0
            }
            let T = median(cands.map { ($0.T, $0.w) }), G = median(cands.map { ($0.G, $0.w) })
            let coverage = Double(cands.count) / Double(w * h)
            result.wb = wbGains(T: T, G: G, coverage: coverage)
            result.illuminant = (T, G, min(coverage / 0.08, 1)) // Phase 3B: residual cast after as-shot WB
        }
        if subject, let (mask, faces) = personMask(img) {
            result.faces = faces
            if !faces.isEmpty { // same guide selectivePlan builds: display-encoded, clamped to 1
                let guide = img.applyingFilter("CILinearToSRGBToneCurve")
                    .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                result.skinTarget = skinTarget(guide: guide, faces: faces)
            }
            // subject vs background brightness, measured on the same 96px copy
            let m = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / mask.extent.width, y: CGFloat(h) / mask.extent.height))
            var mp = [Float](repeating: 0, count: w * h * 4)
            context.render(m, toBitmap: &mp, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
            var sY = 0.0, sW = 0.0, bY = 0.0, bW = 0.0, decisive = 0.0
            for i in stride(from: 0, to: px.count, by: 4) {
                let y = 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
                let k = Double(min(max(mp[i], 0), 1))
                sY += k * y; sW += k; bY += (1 - k) * y; bW += 1 - k
                if k < 0.1 || k > 0.9 { decisive += 1 }
            }
            let n = Double(w * h)
            result.subjectMask = mask
            result.subjectGap = subjectGap(subjectY: sY / max(sW, 1e-9), backgroundY: bY / max(bW, 1e-9),
                                           coverage: sW / n, decisiveness: decisive / n)
            result.maskTrusted = (0.03...0.8).contains(sW / n) && decisive / n >= 0.8
            // face luminance (median of the face box) vs the background mean, in stops
            var fy: [Double] = []
            for f in faces {
                let x0 = Int(f.minX * Double(w)), x1 = Int(f.maxX * Double(w)), y0 = Int(f.minY * Double(h)), y1 = Int(f.maxY * Double(h))
                for yy in max(0, y0)..<min(h, max(y0 + 1, y1)) { for xx in max(0, x0)..<min(w, max(x0 + 1, x1)) {
                    let i = ((h - 1 - yy) * w + xx) * 4 // bitmap rows are top-down; boxes are bottom-up
                    fy.append(0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2]))
                }}
            }
            if !fy.isEmpty, bW > 0 {
                fy.sort()
                result.faceGap = log2(max(bY / bW, 1e-6) / max(fy[fy.count / 2], 1e-6))
            }
        }
        return result
    }

    // MARK: - Local tone development (engine 2)

    /// Scene-dependent local exposure, the part of photographic development a single curve can't do: a bright sky,
    /// a shaded street and dark clothing in one frame each get their own exposure, while texture *inside* each region
    /// keeps its full contrast (only the smooth base layer is adapted, never the detail).
    /// - Base layer: log luminance on the analysis copy (~96 px), smoothed by a cross-bilateral filter (σ ≈ 4.5% of the
    ///   frame, 1 stop in range), so the base follows real light boundaries instead of blurring across them.
    /// - Curve on the base, in stops from 18% grey: regions above +1 are compressed (sky, windows: −0.42 stop per stop,
    ///   soft knee), regions below −2 are lifted (+0.25 per stop, less at high ISO, where a lift shows noise), midtones and
    ///   faces are untouched (subject exposure is the look's measured face pass). Bounded to −1.6…+1.0 stop.
    /// - Strength fades in with the scene's dynamic range (p2…p98 luminance, 3 → 7 stops): a flat or overcast scene gets
    ///   none, so nothing turns into "HDR". Global brightness (metering) is not this function's job.
    /// - Applied at full resolution by `localGain(_:_:)`: the grid is upsampled guided by the photo's own edges
    ///   (CIEdgePreserveUpsampleFilter), so the gain stops at a skyline instead of haloing past it.
    /// Updates `px` (RGBA float, w×h) to the developed light. Returns nil for a flat scene.
    /// ponytail: luminance-only local exposure from one bilateral scale; a second (finer) scale if large-print detail ever needs it.
    static func localDevelopment(_ px: inout [Float], w: Int, h: Int, iso: Double, highlights: (start: Float, slope: Float, sky: Float) = (1, 0.42, 0)) -> (gain: CIImage, range: Double)? {
        let n = w * h
        guard n > 16 else { return nil }
        let (kr, kg, kb) = (Float(0.2126), Float(0.7152), Float(0.0722))
        var L = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let y = kr * px[4 * i] + kg * px[4 * i + 1] + kb * px[4 * i + 2]
            L[i] = log2(max(y, 1e-5) / 0.18)
        }
        let sorted = L.sorted()
        let range = Double(sorted[n * 98 / 100] - sorted[n * 2 / 100])
        let strength = Float(Grade.smooth(3, 7, range))
        guard strength > 0.01 else { return nil }
        // cross-bilateral base layer
        let radius = max(2, Int((Double(max(w, h)) * 0.08).rounded()))
        let sigmaS = Float(radius) / 1.8, sigmaR: Float = 1.0
        var spatial = [Float](repeating: 0, count: (2 * radius + 1) * (2 * radius + 1))
        for dy in -radius...radius { for dx in -radius...radius {
            spatial[(dy + radius) * (2 * radius + 1) + dx + radius] = exp(-Float(dx * dx + dy * dy) / (2 * sigmaS * sigmaS))
        }}
        var base = [Float](repeating: 0, count: n)
        L.withUnsafeBufferPointer { l in spatial.withUnsafeBufferPointer { sp in
            for y in 0..<h { for x in 0..<w {
                let c = l[y * w + x]
                var acc: Float = 0, wsum: Float = 0
                for dy in max(-radius, -y)...min(radius, h - 1 - y) {
                    let row = (y + dy) * w, srow = (dy + radius) * (2 * radius + 1) + radius
                    for dx in max(-radius, -x)...min(radius, w - 1 - x) {
                        let v = l[row + x + dx], d = v - c
                        let wt = sp[srow + dx] * exp(-d * d / (2 * sigmaR * sigmaR))
                        acc += wt * v; wsum += wt
                    }
                }
                base[y * w + x] = acc / wsum
            }}
        }}
        func softplus(_ x: Float) -> Float { let k: Float = 0.6; return x > 8 ? x : k * log(1 + exp(x / k)) }
        let lift = 0.25 * Float(1 - 0.5 * Grade.smooth(400, 3200, iso))
        var grid = [Float](repeating: 1, count: n * 4)
        for i in 0..<n {
            let b = base[i]
            // revision 2 sky burn: a bright region that is also clearly blue (sky, not sunlit stone, skin or white walls)
            // gets up to `sky` stops more, like burning in a print's sky. Blue share of the cell's scene RGB.
            var sky: Float = 0
            if highlights.sky > 0 {
                let r = px[4 * i], g = px[4 * i + 1], bl = px[4 * i + 2], sum = max(r + g + bl, 1e-5)
                let blue = (bl - r) / sum
                sky = highlights.sky * Float(Grade.smooth(0.08, 0.28, Double(blue)) * Grade.smooth(0.8, 2.2, Double(b)))
            }
            let stops = min(max(strength * (-highlights.slope * softplus(b - highlights.start) - sky + lift * softplus(-2 - b)), -2.4), 1.0)
            let enc = (stops + 2) / 4
            // same row order as `px` (render(toBitmap:) and CIImage(bitmapData:) are both top row first)
            grid[4 * i] = enc; grid[4 * i + 1] = enc; grid[4 * i + 2] = enc
            let g = exp2(stops)
            px[4 * i] *= g; px[4 * i + 1] *= g; px[4 * i + 2] *= g
        }
        let image = CIImage(bitmapData: grid.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return (image, range)
    }

    private static let gainKernel = CIColorKernel(source: """
        kernel vec4 applyLocalGain(__sample pixel, __sample gain) {
            return vec4(pixel.rgb * exp2(4.0 * gain.r - 2.0), pixel.a);
        }
        """)

    /// The development's gain grid at full resolution, edge-guided by the photo itself, multiplied into scene-linear light.
    /// Uniform across R, G, B, so hue and saturation of every pixel are untouched (exposure only).
    static func localGain(_ source: CIImage, _ grid: CIImage) -> CIImage {
        let e = source.extent
        let clip = source.properties[clipKey] as? Double ?? 1
        // guide: the photo in a display-like encoding with its whole range (÷ clip), so sky and shade stay distinct
        let guide = scaled(source, 1 / clip).applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        // (a CIColorClamp with an alpha floor here made the upsample's extent empty, silently disabling the development)
        let up = guide.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
            "inputSmallImage": grid, "inputSpatialSigma": 3, "inputLumaSigma": 0.12,
        ]).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).cropped(to: e)
        return gainKernel?.apply(extent: e, arguments: [source, up])?.settingProperties(source.properties) ?? source
    }

    // MARK: - Base development (engine 2, revision 2: research/20)

    /// Log-log slope of the base curve through shadows and midtones. Measured (research/20): Apple's rendering on top of
    /// BetterCam's own metering and local development holds 1.35–1.45 from −4 to +1 stops, on ProRAW and Bayer alike.
    static let baseSlope = 1.4
    /// Scene stops above grey where the base curve reaches display white (Apple's measured: +2.5…+3). Brighter regions
    /// are the local development's job (it pulls them down first); what's still above this, like a bare lamp, clips softly.
    static let baseWhite = 5.5
    /// Share of the shoulder (above grey) taken by a hue/saturation-preserving luminance curve instead of per channel:
    /// a long per-channel shoulder alone bleached lit wood and skin (research/20: +2-stop chroma 0.020 vs the viewfinder's 0.028).
    static let baseHold = 0.5

    private static let baseKernel = CIColorKernel(source: """
        vec3 baseTone(vec3 v, float c, float white, float zw, float pw) {
            vec3 x = log2(max(v, vec3(0.000001)) / 0.18);
            vec3 t = clamp(x / white, 0.0, 1.0);
            vec3 hi = exp2(zw * (1.0 - pow(1.0 - t, vec3(pw))));
            return 0.18 * mix(exp2(c * x), hi, step(0.0, x));
        }
        kernel vec4 baseCurve(__sample p, float c, float white, float zw, float pw, float hold, float proRAW) {
            vec3 rgb = max(p.rgb, vec3(0.0));
            vec3 channel = baseTone(rgb, c, white, zw, pw);
            float y = max(dot(rgb, vec3(0.2289746, 0.6917385, 0.0792869)), 0.000001);
            float fy = baseTone(vec3(y), c, white, zw, pw).r;
            vec3 ratio = rgb * (fy / y);
            float peak = max(ratio.r, max(ratio.g, ratio.b));
            ratio = peak > 1.0 ? mix(vec3(fy), ratio, (1.0 - fy) / max(peak - fy, 0.000001)) : ratio; // fit under white
            float h = hold * smoothstep(0.0, 2.0, log2(y / 0.18));
            vec3 developed = mix(channel, ratio, h);
            // Open lower midtones and keep a steeper transition through diffuse whites.
            float stops = log2(y / 0.18);
            float density = 0.21 * smoothstep(-5.0, -2.8, stops) * (1.0 - smoothstep(-0.9, 0.25, stops));
            density += 0.12 * smoothstep(0.25, 1.8, stops) * (1.0 - smoothstep(2.1, 4.5, stops));

            // Separate colored materials while protecting neutrals and already saturated paint.
            float color = (max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b))) / y;
            float warm = smoothstep(0.0, 0.16, (rgb.r - rgb.b) / y)
                       * smoothstep(-0.02, 0.08, (rgb.g - rgb.b) / y)
                       * (1.0 - smoothstep(0.75, 1.5, color));
            float weight = smoothstep(-3.8, -1.5, stops) * (1.0 - smoothstep(2.4, 4.4, stops));
            density -= 0.24 * warm * smoothstep(0.8, 2.0, stops) * (1.0 - smoothstep(3.4, 5.5, stops));
            developed *= exp2(density * proRAW);
            float luma = dot(developed, vec3(0.2289746, 0.6917385, 0.0792869));
            vec3 delta = developed - vec3(luma);
            float cool = smoothstep(0.025, 0.23, (max(rgb.b, rgb.g) - rgb.r) / y);
            float red = smoothstep(0.10, 0.38, (rgb.r - rgb.g) / y)
                      * smoothstep(-0.14, 0.06, (rgb.b - rgb.g) / y);
            float colorGain = (0.21 * warm + 0.44 * cool + 0.37 * red)
                            * (1.0 - 0.50 * smoothstep(0.8, 1.65, color));
            developed += delta * (proRAW * weight * colorGain);
            float hiRoom = (1.0 - luma) / max(max(developed.r, max(developed.g, developed.b)) - luma, 0.000001);
            float loRoom = luma / max(luma - min(developed.r, min(developed.g, developed.b)), 0.000001);
            float room = clamp(min(hiRoom, loRoom), 0.0, 1.0);
            return vec4(clamp(mix(vec3(luma), developed, room), 0.0, 1.0), p.a);
        }
        """)

    /// RAW stills: scene light → display light, the job Apple's ISP does for the viewfinder's video frames. The looks were
    /// tuned on those frames (display-referred, white at 1), so this is what makes a look's still match its viewfinder.
    /// local gain → the file's exposure → `photographic` per channel in linear Display P3 (grey stays grey, slope
    /// `baseSlope`, white at `baseWhite`). Per channel, like a film or camera curve: that slope is also the midtone color
    /// density Apple's rendering adds (measured ×1.3–1.4 OkLab saturation), and highlights desaturate into white.
    /// Output: clip 1, like a video frame. Non-RAW sources pass through.
    static func develop(_ scene: CIImage, _ a: Analysis, exposure: Double) -> CIImage {
        guard a.raw else { return scene }
        let lit = scaled(a.localGain.map { localGain(scene, $0) } ?? scene, pow(2, exposure))
        let zw = log2(1 / 0.18), pw = max(1, baseSlope * baseWhite / zw)
        guard let curved = baseKernel?.apply(extent: lit.extent, arguments: [transformed(lit, sRGBToP3), baseSlope, baseWhite, zw, pw, baseHold, (scene.properties[proRAWKey] as? Bool == true ? 1.0 : 0.0)])
        else { return scene }
        var props = scene.properties
        props[clipKey] = 1.0
        return transformed(curved, p3ToSRGB).settingProperties(props)
    }

    static let sceneHeadroom = 1.0
    /// Revision 2 local development: large bright regions (sky, windows) compress from +1.3 stops at 0.62 stop per stop (sunlit
    /// diffuse surfaces at +1…+2 stay brilliant), so
    /// with the look's shoulder a +3-stop sky prints as blue rather than near-white. Detail inside each region keeps contrast.
    static let sceneHighlights: (start: Float, slope: Float, sky: Float) = (1.3, 0.62, 1.3)
    /// Revision 2 exposure offset from Apple's median metering (proRAWExposure). −0.25 measured 0.5–1 stop too dark at the median.
    static let sceneDensity = 0.0
    /// Revision 2: the RAW's own scene light, BetterCam's bounded local development and the file's exposure normalization.
    /// No base curve: the look's single scene-referred print transform is the only tone curve the photo receives.
    static func sceneDevelop(_ scene: CIImage, _ a: Analysis, exposure: Double) -> CIImage {
        let k = pow(2, exposure + sceneDensity)
        let lit = scaled(a.localGain.map { localGain(scene, $0) } ?? scene, k)
        var props = scene.properties
        props[clipKey] = (scene.properties[clipKey] as? Double ?? 1) * k
        return lit.settingProperties(props)
    }

    /// Inverse of a nominal Apple display rendering (log-log slope 1.4 below grey, white at +3 stops), so display-referred
    /// frames (viewfinder video, HEIC) enter a revision 2 grade as approximate scene light. An approximation, not a match:
    /// the ISP's local tone mapping stays in the frame.
    private static let displayInverse = CIColorKernel(source: """
        kernel vec4 sceneFromDisplay(__sample p, float slope, float white, float zw, float pw) {
            vec3 v = clamp(p.rgb, vec3(0.000001), vec3(1.0));
            vec3 y = log2(v / 0.18);
            vec3 lo = y / slope;
            vec3 hi = white * (1.0 - pow(max(1.0 - y / zw, vec3(0.0)), vec3(1.0 / pw)));
            return vec4(0.18 * exp2(mix(lo, hi, step(0.0, y))), p.a);
        }
        """)
    static let displayWhiteStops = 3.0
    static func sceneFromDisplay(_ img: CIImage) -> CIImage {
        let zw = log2(1 / 0.18), pw = max(1, baseSlope * displayWhiteStops / zw)
        guard let out = displayInverse?.apply(extent: img.extent, arguments: [img, baseSlope, displayWhiteStops, zw, pw]) else { return img }
        var props = img.properties
        props[clipKey] = 0.18 * pow(2, displayWhiteStops) * (img.properties[clipKey] as? Double ?? 1)
        return out.settingProperties(props)
    }

    /// Vision person segmentation (+ face boxes) on a display-ish copy (Vision expects a rendered photo, not scene-linear light).
    static func personMask(_ img: CIImage) -> (CIImage, [CGRect])? {
        let e = img.extent, s = 512 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .applyingFilter("CILinearToSRGBToneCurve")
        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced // unchanged: other looks' subjectLift uses this mask too; edges are refined at full size (selectivePlan)
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let faceReq = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req, faceReq])) != nil,
              let pb = req.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: pb)
        // ponytail: faces smaller than ~2% × 2% of the frame are skipped (too small to lift safely, and false positives live there)
        let faces = (faceReq.results ?? []).filter { $0.confidence > 0.6 && $0.boundingBox.width * $0.boundingBox.height > 0.0004 }
            .map(\.boundingBox)
        return (mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY)), faces)
    }

    /// How many stops darker a person is than their surroundings — 0 unless the mask is trustworthy:
    /// a real subject (3–80% of frame), a crisp mask (≥80% of pixels clearly in or out), and recoverable (not black).
    static func subjectGap(subjectY: Double, backgroundY: Double, coverage: Double, decisiveness: Double) -> Double {
        guard (0.03...0.8).contains(coverage), decisiveness >= 0.8, subjectY > 0.005, backgroundY > 0 else { return 0 }
        return max(0, log2(backgroundY / subjectY))
    }

    /// Gap → lift: nothing until the subject is ≥ ½ stop darker, then 0.1 EV per stop, capped by the look.
    static func subjectLift(gap: Double, maxEV: Double) -> Double { min(maxEV, max(0, 0.1 * (gap - 0.5))) }

    /// Average white-surface color → correction gains.
    static func wbGains(r: Double, g: Double, b: Double, coverage: Double) -> (Double, Double, Double) {
        let lr = log(g / r), lb = log(g / b)
        return wbGains(T: (lb - lr) / 2, G: -(lr + lb) / 2, coverage: coverage)
    }

    /// Cast in log space (lnR = −T − G, lnB = T − G; T > 0: light is warm, G > 0: light is green) → gains.
    static func wbGains(T: Double, G: Double, coverage: Double) -> (Double, Double, Double) {
        let confidence = min(coverage / 0.08, 1) // ≥8% of the frame are candidate whites = trust it fully
        // ambience priority: keep ~20% of warm light (tungsten, golden hour), ~30% of cool open shade/snow.
        // (Was 50% warm: the user found warm interiors far too yellow, 2026-11-18.)
        let sT = (T > 0 ? 0.9 - 0.1 * Grade.smooth(0, 0.3, T) : 0.9 - 0.2 * Grade.smooth(0, 0.3, -T)) * confidence
        let sG = 0.95 * confidence
        func clampGain(_ x: Double) -> Double { min(max(exp(x), 0.5), 2.0) } // at most one stop per channel
        return (clampGain(-sT * T - sG * G), 1, clampGain(sT * T - sG * G))
    }

    private static let lutSize = 33
    private static let lutCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let lutLock = NSLock()

    /// Slider drags and the live viewfinder re-render constantly; only rebuild the LUT when its inputs change.
    /// Built outside the lock so the viewfinder never waits behind an editor rebuild.
    static func cachedLUT(_ g: Grade, white: Double) -> Data {
        let key = g.lutKey + (g.monochrome ? ",mono" : "")
            + String(format: ",m%.3f,w%.2f,%d,%d", g.midtoneExposure, white, legacyCurve ? 1 : 0, workingP3 ? 1 : 0)
        let cacheKey = key as NSString
        if let hit = lutCache.object(forKey: cacheKey) { return hit as Data }
        let data = lut(g, white: white)
        lutCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    /// Memory warning: drop rebuildable caches (LUTs rebuild in milliseconds; Core Image's intermediates on demand).
    static func purge() {
        lutCache.removeAllObjects()
        lutLock.withLock { skinCubeCache = nil }
        context.clearCaches()
        previewContext.clearCaches()
    }

    /// Shaped scene value → display-encoded (sRGB curve) value.
    static func lut(_ gr: Grade, white: Double) -> Data {
        let n = lutSize
        let top = lutCeiling(white: white, wideGamut: gr.print.wideGamut)
        let (baseGrey, slope) = gr.toneSlope > 0 ? (gr.greyLevel, gr.toneSlope + 2.2 * (gr.contrast - 0.55)) : curveShape(gr.contrast)
        let grey = baseGrey * pow(2, gr.midtoneExposure)
        func tone(_ v: Double) -> Double {
            let x = log2(max(v, 1e-9) / 0.18)
            return legacyCurve ? filmic(x, hi: whiteStops, k: gr.contrast)
                : toEncoded(photographic(x, grey: grey, slope: slope, white: white, mid: gr.midContrast, toe: gr.toeWidth))
        }
        func encodeRatio(_ v: Double) -> Double {
            gr.print.wideGamut && v > 1 ? 1.055 * pow(v, 1 / 2.4) - 0.055 : toEncoded(v)
        }
        let (kr, kg, kb) = gr.print.wideGamut ? (0.2289746, 0.6917385, 0.0792869) : lumaWeights
        var scene = [Double](repeating: 0, count: n), curve = scene
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            scene[i] = x * x * x * top
            curve[i] = tone(scene[i])
        }
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let sat = gr.saturation * chromaNorm, h = gr.hueHold
        let o = outset
        let o00 = o[0][0], o01 = o[0][1], o02 = o[0][2], o10 = o[1][0], o11 = o[1][1], o12 = o[1][2]
        let o20 = o[2][0], o21 = o[2][1], o22 = o[2][2]
        // scalars only in this loop (no arrays/closures per entry): it runs n³ ≈ 36k times per slider change
        out.withUnsafeMutableBufferPointer { p in
            var i = 0
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                var cr = curve[r], cg = curve[g], cb = curve[b]
                if gr.monochrome {
                    let grey = Float(cr)
                    p[i] = grey; p[i + 1] = grey; p[i + 2] = grey; i += 4
                    continue
                }
                // hue-preserving blend: tone-map luminance once and keep the scene's channel ratios
                let vr = scene[r], vg = scene[g], vb = scene[b]
                let yS = kr * vr + kg * vg + kb * vb
                if yS > 1e-9 {
                    let k = toLinear(tone(yS)) / yS
                        var hueHold = h
                        if gr.print.wideGamut {
                            let peak = max(vr, vg, vb)
                            let color = (peak - min(vr, vg, vb)) / peak
                            hueHold += (1 - h) * 0.72 * Grade.smooth(0.22, 0.72, color) * Grade.smooth(0.35, 0.85, 1.5 * peak / top)
                        }
                        cr = (1 - hueHold) * cr + hueHold * encodeRatio(vr * k)
                        cg = (1 - hueHold) * cg + hueHold * encodeRatio(vg * k)
                        cb = (1 - hueHold) * cb + hueHold * encodeRatio(vb * k)
                }
                let y = kr * cr + kg * cg + kb * cb
                cr = y + sat * (cr - y); cg = y + sat * (cg - y); cb = y + sat * (cb - y)
                // outset, then hue/sat, density, split tone, black & white level (display-encoded, see apply())
                let f = gr.finish(o00 * cr + o01 * cg + o02 * cb, o10 * cr + o11 * cg + o12 * cb, o20 * cr + o21 * cg + o22 * cb)
                p[i] = Float(f.0); p[i + 1] = Float(f.1); p[i + 2] = Float(f.2)
                i += 4
            }}}
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func lutCeiling(white: Double, wideGamut: Bool) -> Double {
        0.18 * pow(2, white) * (wideGamut ? 1.5 : 1)
    }

    /// Calibrated tone curve: scene stops relative to 18% grey → display-linear.
    /// Below grey a pure power (log-log slope `slope`): no black clamp, no lift, shadows keep their ratios.
    /// Above grey a shoulder that bends smoothly from `slope` to flat exactly at `white` (the clip), so clipped
    /// highlights reach display white without an edge. Grey placement and midtone slope don't depend on `white`.
    /// `mid` (Phase 3): extra slope at grey only. Below grey the log-log curve is c·x + mid·toe·tanh(x/toe): slope c + mid at
    /// grey, easing back to c a few stops down, so deep shadows sit just mid·toe stops lower than the base curve instead of
    /// being crushed by a steeper power (the old looks' 1.33–1.64). Above grey the shoulder starts from slope c + mid and
    /// still flattens exactly at `white`. mid 0 = the previous curve, bit for bit.
    static func photographic(_ x: Double, grey: Double, slope c: Double, white: Double, mid: Double = 0, toe: Double = 1.5) -> Double {
        guard x > 0 else { return grey * pow(2, c * x + mid * toe * tanh(x / max(toe, 0.1))) }
        let c2 = c + mid
        let zw = log2(1 / grey), p = max(1, c2 * white / zw), t = min(x / white, 1)
        return grey * pow(2, zw * (1 - pow(1 - t, p)))
    }

    /// A look's `contrast` (the legacy logistic's steepness) → the grey level and midtone slope it rendered with,
    /// so looks keep their midtones exactly and only the shoulder is recalibrated.
    static func curveShape(_ k: Double) -> (grey: Double, slope: Double) {
        func y(_ x: Double) -> Double { log2(toLinear(filmic(x, hi: whiteStops, k: k))) }
        return (pow(2, y(0)), (y(0.25) - y(-0.25)) / 0.5)
    }

    /// Legacy filmic sigmoid in stops relative to mid grey → display-encoded 0…1.
    /// Logistic normalized so 7.5 stops under grey is black and `hi` is white.
    static func filmic(_ stops: Double, hi: Double, k: Double) -> Double {
        let lo = -7.5, p = 0.85
        func f(_ x: Double) -> Double { 1 / (1 + exp(-k * (x - p))) }
        let x = min(max(stops, lo), hi)
        return (f(x) - f(lo)) / (f(hi) - f(lo))
    }

    static func toEncoded(_ v: Double) -> Double {
        let v = min(max(v, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func toLinear(_ v: Double) -> Double {
        let v = min(max(v, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: - Optional texture (both off by default)

    // shortcut: source kernels keep the Xcode and Swift check paths shared, migrate to a Metal library if startup or SDK support warrants it.
    private static let highlightSource = CIColorKernel(source: """
        kernel vec4 highlightSource(__sample pixel, float clip) {
            vec3 rgb = max(pixel.rgb, 0.0) / clip;
            float peak = max(rgb.r, max(rgb.g, rgb.b));
            float y = dot(rgb, vec3(0.229, 0.692, 0.079));
            float source = smoothstep(0.81, 1.0, peak) * smoothstep(0.20, 0.60, y);
            return vec4(rgb * source / max(1.0, peak), 1.0);
        }
        """)

    private static let highlightEdge = CIColorKernel(source: """
        kernel vec4 highlightEdge(__sample base, __sample source, __sample blur, float clip, float amount) {
            float y = dot(base.rgb, vec3(0.229, 0.692, 0.079)) / clip;
            vec3 spread = max(blur.rgb - source.rgb, 0.0);
            float red = max(spread.r - max(spread.g, spread.b), 0.0);
            vec3 halo = spread + red * vec3(0.26, 0.06, 0.0);
            return vec4(base.rgb + halo * (amount * clip * (1.0 - smoothstep(0.32, 0.82, y))), base.a);
        }
        """)

    private static func highlightDiffusion(_ image: CIImage, clip: Double, amount: Double) -> CIImage {
        let e = image.extent
        guard amount > 0, let source = highlightSource?.apply(extent: e, arguments: [image, clip]) else { return image }
        let side = max(e.width, e.height)
        let scale = min(1, 800 / side)
        let blur = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent().applyingGaussianBlur(sigma: side * scale * 0.0018)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: e)
        return highlightEdge?.apply(extent: e, arguments: [image, source, blur, clip, amount]) ?? image
    }

    private static let grainKernel = CIColorKernel(source: """
        float grainCell(vec2 p) {
            vec3 q = fract(p.xyx * vec3(0.1031, 0.11369, 0.13787));
            q += dot(q, q.yzx + 19.19);
            return fract((q.x + q.y) * q.z);
        }

        kernel vec4 filmGrain(__sample pixel, vec2 center, float scale, vec2 seed, float amount) {
            vec3 rgb = pixel.rgb;
            float peak = max(rgb.r, max(rgb.g, rgb.b));
            float low = min(rgb.r, min(rgb.g, rgb.b));
            float y = clamp(dot(rgb, vec3(0.229, 0.692, 0.079)), 0.0, 1.0);
            // A fitted preview correction can move colors outside P3. Bring them back along the neutral axis.
            float gamut = min(1.0, min(y / max(y - low, 0.00001), (1.0 - y) / max(peak - y, 0.00001)));
            rgb = mix(vec3(y), rgb, gamut);
            vec2 p = (destCoord() - center) * scale + seed;
            vec2 cell = floor(p);
            vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(p));
            float noise = mix(mix(grainCell(cell), grainCell(cell + vec2(1.0, 0.0)), f.x),
                              mix(grainCell(cell + vec2(0.0, 1.0)), grainCell(cell + vec2(1.0, 1.0)), f.x), f.y) - 0.5;
            float envelope = smoothstep(0.002, 0.045, y) * (1.0 - smoothstep(0.45, 0.97, y));
            float warm = smoothstep(0.015, 0.10, rgb.r - rgb.g) * smoothstep(0.0, 0.08, rgb.g - rgb.b);
            float gain = amount * noise * envelope * mix(1.0, 0.7, warm) / sqrt(max(y, 0.035));
            float white = max(rgb.r, max(rgb.g, rgb.b));
            return vec4(rgb * min(1.0 + gain, 1.0 / max(white, 0.00001)), pixel.a);
        }
        """)

    private static func grain(_ image: CIImage, amount: Double, cells: CGFloat, seed: UInt32) -> CIImage {
        guard amount > 0 else { return image }
        let e = image.extent
        let scale = min(1.0, cells / min(e.height, e.width))
        let offset = CIVector(x: Double(seed & 0xffff) / 19, y: Double(seed >> 16) / 19)
        guard let grained = grainKernel?.apply(extent: e, arguments: [
            transformed(image, sRGBToP3), CIVector(x: e.midX, y: e.midY), scale, offset, amount,
        ]) else { return image }
        return transformed(grained, p3ToSRGB)
    }

    /// Halation-style glow: only the brightest parts, warm, wide and soft. Applied in scene light like on film.
    static func bloom(_ img: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return img }
        let t = 1.5 // scene-linear threshold, well above diffuse white
        let bright = img
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.35, w: 0),
                "inputBiasVector": CIVector(x: -t, y: -t * 0.6, z: -t * 0.35, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 8, y: 8, z: 8, w: 1),
            ])
        let k = 0.4 * amount
        let glow = bright.clampedToExtent()
            .applyingGaussianBlur(sigma: max(img.extent.width, img.extent.height) * 0.01)
            .cropped(to: img.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), // alpha 0: additive light only (alpha 2 halved the image)
            ])
        return glow.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img])
    }

    /// Local contrast (doc §7.7): adds a little of the image minus its blur, so texture reads without clarity halos.
    /// Core Image's unsharp mask (a hand-built negative-add got its negative half clamped away). Runs on display-encoded
    /// values; radius scales with the image so preview, thumbnail and export look alike.
    /// ponytail: RGB, not luma-only, and no skin/noise mask; at ≤ 0.03 that's ≤ 3%. Mask it if high-ISO noise shows.
    static func microcontrast(_ img: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return img }
        let e = img.extent
        return img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: max(e.width, e.height) * 0.002, kCIInputIntensityKey: amount,
        ]).cropped(to: e)
    }

    /// Print-scale contrast (revision 2): the image minus a wide blur (≈1% of the long side), on display-encoded values,
    /// like a darkroom's broad dodge and burn. Small amounts only: larger ones read as HDR "clarity" halos.
    static func localContrast(_ img: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return img }
        let e = img.extent
        return img.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: max(e.width, e.height) * 0.01, kCIInputIntensityKey: amount,
        ]).cropped(to: e)
    }

    // MARK: - Output

    #if canImport(UIKit)
    static func uiImage(_ img: CIImage) -> UIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: outputSpace).map(UIImage.init)
    }
    #endif

    /// Metadata for exported files: lens/exposure EXIF and GPS from the original, plus the look and its exact settings,
    /// so a photo can be re-rendered later. Orientation and pixel sizes are dropped (the render is already upright).
    static func exportProperties(source: URL, recipe: Recipe, renderedFrom: String) -> [String: Any] {
        let src = CGImageSourceCreateWithURL(source as CFURL, nil)
        let orig = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        var exif = orig[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = nil
        exif[kCGImagePropertyExifPixelYDimension as String] = nil
        exif[kCGImagePropertyExifColorSpace as String] = nil
        let origTIFF = orig[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = (try? encoder.encode(recipe)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var tiff: [String: Any] = [
            kCGImagePropertyTIFFSoftware as String: "bettercam render \(version)",
            kCGImagePropertyTIFFImageDescription as String: "look=\(recipe.filter) source=\(renderedFrom) \(settings)",
        ]
        for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime] {
            tiff[k as String] = origTIFF[k as String]
        }
        var props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif, kCGImagePropertyTIFFDictionary as String: tiff]
        props[kCGImagePropertyGPSDictionary as String] = orig[kCGImagePropertyGPSDictionary as String]
        return props
    }

    static func jpeg(_ img: CIImage, quality: Double = 0.85, renderer: CIContext = context) -> Data? {
        renderer.jpegRepresentation(of: img, colorSpace: outputSpace,
                                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

    static func heif(_ img: CIImage) -> Data? {
        context.heifRepresentation(of: img, format: .RGBA8, colorSpace: outputSpace, options: [:])
    }

    // MARK: - Diagnostics (research/11-phase2-capture.md §1: device validation of the decode)

    /// Process memory as Xcode's gauge shows it (phys_footprint), MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Decoded linear stats: size, max-channel max/p99/p99.9, % at the white anchor, % negative (out of sRGB).
    /// If iOS behaves like macOS, max > 1 on any shot with a bright window and the anchor % matches the scene's real clipping.
    static func decodeReport(_ img: CIImage) -> String {
        let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
        var p = [Float](repeating: 0, count: w * h * 4)
        context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: context.workingColorSpace)
        let clip = Float((img.properties[clipKey] as? Double) ?? 1)
        var m = [Float](), atClip = 0, neg = 0
        m.reserveCapacity(w * h)
        for i in stride(from: 0, to: p.count, by: 4) {
            m.append(max(p[i], p[i + 1], p[i + 2]))
            if p[i + 1] >= 0.99 * clip { atClip += 1 }
            if min(p[i], p[i + 1], p[i + 2]) < 0 { neg += 1 }
        }
        m.sort()
        let n = Float(m.count)
        func q(_ x: Float) -> Float { m[min(m.count - 1, Int(x * n))] }
        return String(format: "%dx%d max %.2f p99 %.2f p99.9 %.2f anchor %.2f atAnchor %.3f%% neg %.1f%%",
                      w, h, m.last ?? 0, q(0.99), q(0.999), clip, 100 * Float(atClip) / n, 100 * Float(neg) / n)
    }
}
