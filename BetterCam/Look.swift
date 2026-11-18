import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Every edit is a recipe applied to the untouched original, so editing is non-destructive.
/// A recipe = a film filter at some strength, plus the user's slider offsets on top.
struct Recipe: Codable, Equatable {
    static let current = 9 // bump when the look changes; older recipes reset to the new defaults (crop is kept)

    var version = Recipe.current
    var filter = Filter.all[0].id
    var strength = 1.0     // 0 = Natural … 1 = the full film look
    var exposure = 0.0     // stops, on top of the filter
    var contrast = 1.0     // 0 soft … 2 hard
    var warmth = 0.0       // -1 cool … +1 warm
    var saturation = 1.0
    var bloom = 0.0        // added to the filter's halation
    var grain = 0.0        // added to the filter's grain
    var crop = 1.0         // zoom crop set at capture (2× = center crop of the main lens)

    init() {}
    init(filter: String, crop: Double = 1) { self.filter = filter; self.crop = crop }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        crop = try c.decodeIfPresent(Double.self, forKey: .crop) ?? 1
        guard try c.decodeIfPresent(Int.self, forKey: .version) == Recipe.current else { return }
        filter = try c.decode(String.self, forKey: .filter)
        strength = try c.decode(Double.self, forKey: .strength)
        exposure = try c.decode(Double.self, forKey: .exposure)
        contrast = try c.decode(Double.self, forKey: .contrast)
        warmth = try c.decode(Double.self, forKey: .warmth)
        saturation = try c.decode(Double.self, forKey: .saturation)
        bloom = try c.decode(Double.self, forKey: .bloom)
        grain = try c.decode(Double.self, forKey: .grain)
    }

    /// The grade this recipe renders: Natural → filter by strength, then the user's sliders.
    var grade: Grade {
        var g = Grade.natural.mixed(with: Filter.named(filter).grade, strength)
        g.exposure += exposure
        g.contrast *= pow(1.7, contrast - 1) // slider 0…2 → ×0.59…×1.7 curve steepness
        g.saturation *= saturation
        g.temperature += warmth
        g.bloom += bloom
        g.grain += grain
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
    /// Display white, in stops above mid grey at the curve input. Our RAW clips at ~+4 (−1 EV capture, +1 decode,
    /// +0.55 baseline exposure), so clipped highlights land at ~0.97 and only exposure pushes reach 1.0.
    static let whiteStops = 4.5
    /// Share of the hue-preserving curve in the tone map (research §8.2 suggests testing 0.3–0.6).
    static let hueHold = 0.35
    /// Scales `Grade.saturation` so 1.0 ≈ colorimetric chroma on a ColorChecker (AgX inset/outset alone mutes color).
    /// Measured by checks/main.swift; re-measure if the curve, inset or hueHold changes.
    static let chromaNorm = 0.93

    // MARK: - Decode

    /// Scene-linear decode, center-cropped by `crop`.
    /// RAW: Apple's tone curve, local tone mapping (HDR flattening) and sharpening are all off. What's left is
    /// demosaic + the sensor's color matrix + light noise reduction, which any RAW developer has to do.
    static func decode(_ url: URL, crop: Double = 1, maxSide: CGFloat? = nil) -> CIImage? {
        let img: CIImage?
        if url.pathExtension.lowercased() == "dng", let raw = CIRAWFilter(imageURL: url) {
            if let maxSide {
                let side = max(raw.nativeSize.width, raw.nativeSize.height) / crop
                raw.scaleFactor = Float(min(1, maxSide / side))
            }
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.localToneMapAmount = 0
            raw.sharpnessAmount *= 0.6 // mild, like a good camera; Apple's full amount halos
            raw.exposure = Float(rawCompensation)
            img = raw.outputImage
        } else { // processed HEIC fallback (cameras without RAW)
            img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]).map { im in
                guard let maxSide else { return im }
                let s = min(1, maxSide * crop / max(im.extent.width, im.extent.height))
                return im.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
        }
        guard let img else { return nil }
        guard crop > 1 else { return img }
        let e = img.extent
        let w = e.width / crop, h = e.height / crop
        return img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - w / 2), y: -(e.midY - h / 2)))
    }

    /// Render once to memory so slider changes only re-run the look, not the RAW decode.
    static func materialize(_ img: CIImage) -> CIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: context.workingColorSpace)
            .map { CIImage(cgImage: $0) }
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
    }

    /// `grainSeed`: offset into the noise field. Stills use .zero (reproducible); the viewfinder varies it per frame.
    static func apply(_ r: Recipe, to base: CIImage, analysis: Analysis? = nil, grainSeed: CGPoint = .zero) -> CIImage {
        apply(r.grade, to: base, analysis: analysis, grainSeed: grainSeed)
    }

    static func apply(_ gr: Grade, to base: CIImage, analysis: Analysis? = nil, grainSeed: CGPoint = .zero) -> CIImage {
        let a = analysis ?? analyze(base)
        // 1. exposure + white balance + AgX inset, as one linear matrix
        let g = pow(2, gr.exposure)
        let auto = [pow(a.wb.0, gr.autoWB), 1.0, pow(a.wb.2, gr.autoWB)]
        let wb = [auto[0] * (1 + 0.2 * gr.temperature), auto[1] * (1 - 0.12 * gr.tint), auto[2] * (1 - 0.2 * gr.temperature)]
        func row(_ i: Int) -> CIVector {
            CIVector(x: inset[i][0] * g * wb[0], y: inset[i][1] * g * wb[1], z: inset[i][2] * g * wb[2], w: 0)
        }
        // 2. fixed white anchor (see whiteStops)
        let top = 0.18 * pow(2, whiteStops)
        let s = 1 / top
        let shaped = bloom(base, amount: gr.bloom)
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2)])
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
        cube.cubeData = cachedLUT(gr)
        // The cube holds display-encoded values: Core Image stores cube data at ~8-bit precision, which in linear light
        // posterizes the shadows (only a few levels below 1%). Encoded, the steps are perceptually even.
        let display = cube.outputImage?.applyingFilter("CISRGBToneCurveToLinear") ?? base
        return grain(display, amount: gr.grain, seed: grainSeed).cropped(to: base.extent)
    }

    /// Reads a 96px copy on the CPU. The camera's as-shot WB is the prior; this corrects what it got wrong.
    /// We find surfaces that are *nearly* neutral already (walls, ceilings, concrete, white objects) and average them.
    /// Strongly colored areas (a yellow wall, foliage) are ignored, so they keep their color.
    /// The cast is split into two axes and corrected separately (research §7, Fuji's "ambience priority"):
    /// - temperature (blue↔amber): mostly corrected, but a *warm* cast is kept up to half (tungsten, golden hour)
    /// - tint (green↔magenta): almost fully corrected (fluorescent/LED green is never wanted)
    /// Both fade out when few near-neutral surfaces exist (neon, stage light): then the light's color is the point.
    static func analyze(_ img: CIImage) -> Analysis {
        let e = img.extent
        let n = 96
        let scale = Double(n) / max(e.width, e.height)
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale])
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 0, h > 0 else { return Analysis(wb: (1, 1, 1)) }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: small.extent, format: .RGBAf, colorSpace: nil)

        var white = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { white = max(white, Double(max(px[i], px[i + 1], px[i + 2]))) }

        // near-neutral, well-exposed, unclipped pixels
        var sum = (0.0, 0.0, 0.0), weight = 0.0, count = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let y = 0.25 * r + 0.5 * g + 0.25 * b
            guard y > 0.03, max(r, g, b) < white * 0.95 else { continue } // not deep noise, not clipped
            let chroma = (max(r, g, b) - min(r, g, b)) / y
            guard chroma < 0.35 else { continue }
            let wt = (1 - chroma / 0.35) * y // brighter, more neutral surfaces count more
            sum.0 += wt * r / y; sum.1 += wt * g / y; sum.2 += wt * b / y; weight += wt; count += 1
        }
        guard weight > 0 else { return Analysis(wb: (1, 1, 1)) }
        return Analysis(wb: wbGains(r: sum.0 / weight, g: sum.1 / weight, b: sum.2 / weight,
                                    coverage: Double(count) / Double(w * h)))
    }

    /// Average near-neutral color → correction gains. In log space: lnR = −T − G, lnB = T − G,
    /// T = temperature (>0: light is warm), G = tint (>0: light is green).
    static func wbGains(r: Double, g: Double, b: Double, coverage: Double) -> (Double, Double, Double) {
        let lr = log(g / r), lb = log(g / b)
        let T = (lb - lr) / 2, G = -(lr + lb) / 2
        let confidence = min(coverage / 0.08, 1) // ≥8% of the frame near-neutral = trust it fully
        let sT = (T > 0 ? 0.9 - 0.4 * Grade.smooth(0, 0.3, T) : 0.9) * confidence // ambience priority for warm light
        let sG = 0.95 * confidence
        func clampGain(_ x: Double) -> Double { min(max(exp(x), 0.7), 1.45) } // never more than ~half a stop
        return (clampGain(-sT * T - sG * G), 1, clampGain(sT * T - sG * G))
    }

    private static let lutSize = 33
    private static var lutCache: [String: Data] = [:]
    private static let lutLock = NSLock()

    /// Slider drags and the live viewfinder re-render constantly; only rebuild the LUT when its inputs change.
    /// Built outside the lock so the viewfinder never waits behind an editor rebuild.
    static func cachedLUT(_ g: Grade) -> Data {
        let key = g.lutKey
        if let d = lutLock.withLock({ lutCache[key] }) { return d }
        let d = lut(g)
        lutLock.withLock {
            if lutCache.count > 64 { lutCache.removeAll() } // ponytail: crude eviction; LRU if rebuilds show up in profiles
            lutCache[key] = d
        }
        return d
    }

    /// Shaped scene value → display-encoded (sRGB curve) value.
    static func lut(_ gr: Grade) -> Data {
        let n = lutSize
        let top = 0.18 * pow(2, whiteStops)
        func tone(_ v: Double) -> Double { filmic(log2(max(v, 1e-9) / 0.18), hi: whiteStops, k: gr.contrast) }
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

    /// Filmic sigmoid in stops relative to mid grey → display-encoded 0…1.
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

    static func jpeg(_ img: CIImage, quality: Double = 0.85) -> Data? {
        context.jpegRepresentation(of: img, colorSpace: outputSpace,
                                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

    static func heif(_ img: CIImage) -> Data? {
        context.heifRepresentation(of: img, format: .RGBA8, colorSpace: outputSpace, options: [:])
    }
}
