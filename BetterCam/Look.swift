import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Every edit is a recipe applied to the untouched original, so editing is non-destructive.
/// A recipe = a look + four small finishing sliders (research/newFilters_11_18.md §8: the look does 90% of the work).
struct Recipe: Codable, Equatable {
    static let current = 10 // bump when slider units change; older recipes keep look + crop, sliders reset

    static let exposureRange = -0.7...0.7     // EV on top of the look's render exposure (not capture bias)
    static let contrastRange = -0.08...0.08   // added to the look's curve slope
    static let warmthRange = -0.25...0.25     // added to temperature (±5% R/B). Doc said ±0.04 = ±0.8%: invisible
    static let saturationRange = 0.88...1.12  // × the look's saturation

    var version = Recipe.current
    var filter = Filter.all[0].id
    var exposure = 0.0
    var contrast = 0.0
    var warmth = 0.0
    var saturation = 1.0
    var crop = 1.0          // zoom crop set at capture (2× = center crop of the main lens)
    var baseExposure = 0.0  // not a slider: −1 for imported RAWs, which weren't shot 1 stop under like ours

    init() {}
    init(filter: String, crop: Double = 1) { self.filter = filter; self.crop = crop }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        crop = try c.decodeIfPresent(Double.self, forKey: .crop) ?? 1
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? filter
        baseExposure = try c.decodeIfPresent(Double.self, forKey: .baseExposure) ?? 0
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

    /// The grade this recipe renders: the look's absolute values, then the slider offsets.
    var grade: Grade {
        var g = Filter.named(filter).grade
        g.exposure += exposure + baseExposure
        g.contrast += contrast
        g.temperature += warmth
        g.saturation *= saturation
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
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// We underexpose RAW captures by this much (see Camera) to protect highlights, and restore it at decode.
    static let rawCompensation = 1.0
    /// Bump when rendering changes without recipe units changing: gallery thumbnails re-render, edits are kept.
    static let version = 12
    /// Legacy curve only (`legacyCurve`): fixed display white, in stops above mid grey. It assumed RAW clips at ~+4;
    /// the old SDR-clipped decode actually stopped at +2.9…+3.2, so highlights never passed ~0.89.
    /// The calibrated curve instead puts white at each photo's own clip level (`Analysis.clip`).
    static let whiteStops = 4.5
    /// Share of the hue-preserving curve in the tone map (research §8.2 suggests testing 0.3–0.6).
    static let hueHold = 0.35
    /// Scales `Grade.saturation` so 1.0 ≈ colorimetric chroma on a ColorChecker (AgX inset/outset alone mutes color).
    /// Measured by checks/main.swift; re-measure if the curve, inset or hueHold changes.
    static let chromaNorm = 0.93

    // MARK: - Decode

    /// Diagnostics only (checks/compare): the pre-2026-11-18 decode and tone curve, for before/after renders.
    /// ponytail: delete both flags and their branches once Phase 1 is signed off.
    nonisolated(unsafe) static var legacyDecode = false
    nonisolated(unsafe) static var legacyCurve = false

    /// CIImage property: the decoded image's clip level (scene-linear) = where the tone curve puts display white.
    static let clipKey = "bettercam.clip"
    /// Sensor clip of an iPhone Bayer DNG decoded at baselineExposure 0 (highlight recovery on). Measured 1.92–2.42
    /// on the 17 Pro samples (research/10-phase1-pipeline.md). Erring high costs nothing: the shoulder is flat there.
    static let sensorClip = 2.4

    /// Scene-linear decode, center-cropped by `crop`.
    /// RAW: Apple's tone curve, local tone mapping (HDR flattening) and sharpening are all off. What's left is
    /// demosaic + the sensor's color matrix + light noise reduction, which any RAW developer has to do.
    /// Measured on the 17 Pro (research/10-phase1-pipeline.md): with EDR 0 Core Image rolls off above ~0.6 and clips
    /// at 1.0; with baseline exposure applied inside the filter EDR 1 still caps at 3.0. So decode at EDR 1 with
    /// baseline 0 and exposure 0 (exactly linear up to the sensor clip ≈ 2.4), then apply baseline + our −1 EV capture
    /// compensation as a plain float gain, where nothing can clip.
    static func decode(_ url: URL, crop: Double = 1, maxSide: CGFloat? = nil) -> CIImage? {
        var img: CIImage?
        var clip = 1.0 // display-referred input (HEIC): already tone-mapped to SDR white
        if url.pathExtension.lowercased() == "dng", let raw = CIRAWFilter(imageURL: url) {
            if let maxSide {
                let side = max(raw.nativeSize.width, raw.nativeSize.height) / crop
                raw.scaleFactor = Float(min(1, maxSide / side))
            }
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.localToneMapAmount = 0
            raw.sharpnessAmount *= 0.6 // mild, like a good camera; Apple's full amount halos
            if legacyDecode {
                raw.exposure = Float(rawCompensation)
                img = raw.outputImage
                clip = 0.18 * pow(2, whiteStops)
            } else {
                let gain = pow(2, Double(raw.baselineExposure) + rawCompensation) // per file: 0.005–1.36 stops measured
                raw.baselineExposure = 0
                raw.extendedDynamicRangeAmount = 1
                img = raw.outputImage.map { scaled($0, gain) }
                clip = sensorClip * gain
            }
        } else { // processed HEIC fallback (cameras without RAW)
            img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]).map { im in
                guard let maxSide else { return im }
                let s = min(1, maxSide * crop / max(im.extent.width, im.extent.height))
                return im.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
        }
        guard var img else { return nil }
        if crop > 1 {
            let e = img.extent
            let w = e.width / crop, h = e.height / crop
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
        }
        return img.settingProperties([clipKey: clip])
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
        context.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: context.workingColorSpace)
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
    }

    /// `grainSeed`: offset into the noise field. Stills use .zero (reproducible); the viewfinder varies it per frame.
    static func apply(_ r: Recipe, to base: CIImage, analysis: Analysis? = nil, grainSeed: CGPoint = .zero) -> CIImage {
        apply(r.grade, to: base, analysis: analysis, grainSeed: grainSeed)
    }

    static func apply(_ gr: Grade, to base: CIImage, analysis: Analysis? = nil, grainSeed: CGPoint = .zero) -> CIImage {
        let a = analysis ?? analyze(base, subject: true)
        // 1. exposure + white balance + AgX inset, as one linear matrix
        let g = pow(2, gr.exposure)
        let auto = [pow(a.wb.0, gr.autoWB), 1.0, pow(a.wb.2, gr.autoWB)]
        let wb = [auto[0] * (1 + 0.2 * gr.temperature), auto[1] * (1 - 0.12 * gr.tint), auto[2] * (1 - 0.2 * gr.temperature)]
        func row(_ i: Int) -> CIVector {
            CIVector(x: inset[i][0] * g * wb[0], y: inset[i][1] * g * wb[1], z: inset[i][2] * g * wb[2], w: 0)
        }
        // 2. white anchor: the photo's clip level after this grade's exposure. Exposure metadata, not image content,
        // so a single specular can't move the curve; grey and midtone slope don't depend on it (see photographic()).
        let white = legacyCurve ? whiteStops : ((log2(a.clip / 0.18) + gr.exposure) * 20).rounded() / 20
        let top = 0.18 * pow(2, white)
        let s = 1 / top
        var exposed = bloom(base, amount: gr.bloom)
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
        // The cube holds display-encoded values: Core Image stores cube data at ~8-bit precision, which in linear light
        // posterizes the shadows (only a few levels below 1%). Encoded, the steps are perceptually even.
        let display = cube.outputImage.map { microcontrast($0, amount: gr.microcontrast) }?
            .applyingFilter("CISRGBToneCurveToLinear") ?? base
        return grain(display, amount: gr.grain, seed: grainSeed).cropped(to: base.extent)
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
    static func analyze(_ img: CIImage, subject: Bool = false) -> Analysis {
        let e = img.extent
        let n = 96
        let scale = Double(n) / max(e.width, e.height)
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        let clip = (img.properties[clipKey] as? Double) ?? 1
        guard w > 0, h > 0 else { return Analysis(wb: (1, 1, 1), clip: clip) }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: small.extent, format: .RGBAf, colorSpace: nil)

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
        var result = Analysis(wb: (1, 1, 1), clip: clip)
        if !cands.isEmpty {
            func median(_ v: [(Double, Double)]) -> Double { // weighted median of (value, weight)
                let sorted = v.sorted { $0.0 < $1.0 }, half = sorted.reduce(0) { $0 + $1.1 } / 2
                var acc = 0.0
                for (x, wt) in sorted { acc += wt; if acc >= half { return x } }
                return sorted.last!.0
            }
            result.wb = wbGains(T: median(cands.map { ($0.T, $0.w) }), G: median(cands.map { ($0.G, $0.w) }),
                                coverage: Double(cands.count) / Double(w * h))
        }
        if subject, let mask = personMask(img) {
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
        }
        return result
    }

    /// Vision person segmentation on a display-ish copy (Vision expects a rendered photo, not scene-linear light).
    static func personMask(_ img: CIImage) -> CIImage? {
        let e = img.extent, s = 512 / max(e.width, e.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .applyingFilter("CILinearToSRGBToneCurve")
        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil,
              let pb = req.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: pb)
        return mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
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
    private static var lutCache: [String: Data] = [:]
    private static let lutLock = NSLock()

    /// Slider drags and the live viewfinder re-render constantly; only rebuild the LUT when its inputs change.
    /// Built outside the lock so the viewfinder never waits behind an editor rebuild.
    static func cachedLUT(_ g: Grade, white: Double) -> Data {
        let key = g.lutKey + String(format: ",w%.2f,%d", white, legacyCurve ? 1 : 0)
        if let d = lutLock.withLock({ lutCache[key] }) { return d }
        let d = lut(g, white: white)
        lutLock.withLock {
            if lutCache.count > 64 { lutCache.removeAll() } // ponytail: crude eviction; LRU if rebuilds show up in profiles
            lutCache[key] = d
        }
        return d
    }

    /// Shaped scene value → display-encoded (sRGB curve) value.
    static func lut(_ gr: Grade, white: Double) -> Data {
        let n = lutSize
        let top = 0.18 * pow(2, white)
        let (grey, slope) = curveShape(gr.contrast)
        func tone(_ v: Double) -> Double {
            let x = log2(max(v, 1e-9) / 0.18)
            return legacyCurve ? filmic(x, hi: whiteStops, k: gr.contrast)
                : toEncoded(photographic(x, grey: grey, slope: slope, white: white))
        }
        var scene = [Double](repeating: 0, count: n), curve = scene
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            scene[i] = x * x * x * top
            curve[i] = tone(scene[i])
        }
        var out = [Float](repeating: 1, count: n * n * n * 4)
        let sat = gr.saturation * chromaNorm, h = hueHold
        let o = outset
        let o00 = o[0][0], o01 = o[0][1], o02 = o[0][2], o10 = o[1][0], o11 = o[1][1], o12 = o[1][2]
        let o20 = o[2][0], o21 = o[2][1], o22 = o[2][2]
        // scalars only in this loop (no arrays/closures per entry): it runs n³ ≈ 36k times per slider change
        out.withUnsafeMutableBufferPointer { p in
            var i = 0
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                var cr = curve[r], cg = curve[g], cb = curve[b]
                // hue-preserving blend: tone-map luminance once and keep the scene's channel ratios
                let vr = scene[r], vg = scene[g], vb = scene[b]
                let yS = 0.2126 * vr + 0.7152 * vg + 0.0722 * vb
                if yS > 1e-9 {
                    let k = toLinear(tone(yS)) / yS
                    cr = (1 - h) * cr + h * toEncoded(vr * k)
                    cg = (1 - h) * cg + h * toEncoded(vg * k)
                    cb = (1 - h) * cb + h * toEncoded(vb * k)
                }
                let y = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
                cr = y + sat * (cr - y); cg = y + sat * (cg - y); cb = y + sat * (cb - y)
                // outset, then hue/sat, density, split tone, black & white level (display-encoded, see apply())
                let f = gr.finish(o00 * cr + o01 * cg + o02 * cb, o10 * cr + o11 * cg + o12 * cb, o20 * cr + o21 * cg + o22 * cb)
                p[i] = Float(f.0); p[i + 1] = Float(f.1); p[i + 2] = Float(f.2)
                i += 4
            }}}
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Calibrated tone curve: scene stops relative to 18% grey → display-linear.
    /// Below grey a pure power (log-log slope `slope`): no black clamp, no lift, shadows keep their ratios.
    /// Above grey a shoulder that bends smoothly from `slope` to flat exactly at `white` (the clip), so clipped
    /// highlights reach display white without an edge. Grey placement and midtone slope don't depend on `white`.
    static func photographic(_ x: Double, grey: Double, slope c: Double, white: Double) -> Double {
        guard x > 0 else { return grey * pow(2, c * x) }
        let zw = log2(1 / grey), p = max(1, c * white / zw), t = min(x / white, 1)
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

    /// Film grain: fine monochrome noise, multiplicative (scales with the light, like silver grains),
    /// clamped so there are never bright specks. amount 1 ≈ ±4% density variation.
    static func grain(_ img: CIImage, amount: Double, seed: CGPoint = .zero) -> CIImage {
        guard amount > 0 else { return img }
        let a = 0.08 * amount
        let size = max(1, max(img.extent.width, img.extent.height) / 2400)
        let mono = CIVector(x: a / 3, y: a / 3, z: a / 3, w: 0) // average R,G,B of the noise → smoother distribution
        let noise = CIFilter.randomGenerator().outputImage!
            .transformed(by: CGAffineTransform(translationX: seed.x, y: seed.y)) // new field per viewfinder frame
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": mono, "inputGVector": mono, "inputBVector": mono,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1 - a / 2, y: 1 - a / 2, z: 1 - a / 2, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 1 - a / 2, y: 1 - a / 2, z: 1 - a / 2, w: 1),
                "inputMaxComponents": CIVector(x: 1 + a / 2, y: 1 + a / 2, z: 1 + a / 2, w: 1),
            ])
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .applyingGaussianBlur(sigma: 0.6 * size)
            .cropped(to: img.extent)
        return noise.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: img])
    }

    // MARK: - Output

    #if canImport(UIKit)
    static func uiImage(_ img: CIImage) -> UIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: outputSpace).map(UIImage.init)
    }
    #endif

    /// Metadata for exported files: lens/exposure EXIF and GPS from the original, plus the look and its exact settings,
    /// so a photo can be re-rendered later. Orientation and pixel sizes are dropped (the render is already upright).
    static func exportProperties(source: URL, recipe: Recipe) -> [String: Any] {
        let src = CGImageSourceCreateWithURL(source as CFURL, nil)
        let orig = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        var exif = orig[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = nil
        exif[kCGImagePropertyExifPixelYDimension as String] = nil
        let origTIFF = orig[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let settings = (try? JSONEncoder().encode(recipe)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var tiff: [String: Any] = [
            kCGImagePropertyTIFFSoftware as String: "bettercam",
            kCGImagePropertyTIFFImageDescription as String: "look=\(recipe.filter) \(settings)",
        ]
        for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime] {
            tiff[k as String] = origTIFF[k as String]
        }
        var props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif, kCGImagePropertyTIFFDictionary as String: tiff]
        props[kCGImagePropertyGPSDictionary as String] = orig[kCGImagePropertyGPSDictionary as String]
        return props
    }

    static func jpeg(_ img: CIImage, quality: Double = 0.85) -> Data? {
        context.jpegRepresentation(of: img, colorSpace: outputSpace,
                                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

    static func heif(_ img: CIImage) -> Data? {
        context.heifRepresentation(of: img, format: .RGBA8, colorSpace: outputSpace, options: [:])
    }
}
