import CoreImage
import Foundation

/// V1 look-first renderer (revision 6). Each look is one fixed, authored, pointwise colour transform:
/// a master tone curve on OKLab lightness, hue-vs-hue / hue-vs-chroma / hue-vs-lightness tables with neutral
/// protection, a path to white and P3 gamut mapping — or, for Silver, a channel mix and a monochrome curve.
/// No scene analysis: the same function for every photograph, preview and still alike.
///
/// Domain (input and output): Display P3 primaries, sRGB transfer function (`CGColorSpace.displayP3`), [0, 1],
/// display-referred. Baked once per look into a 33³ cube and applied with CIColorCubeWithColorSpace, so Core Image
/// converts from/to the linear working space at the cube's boundary — the same filter object for every path.
enum Grade {
    static let revision = 6
    static let dimension = 33

    /// Six active looks (revision 6) plus the four revision-5 looks, kept so recipes saved with them still render
    /// exactly as before. Only `active` looks are offered in the camera and editor.
    enum Look: String, CaseIterable {
        case soleil, leicaM6, editorial, cinema, terra, silver
        case signatureR5, editorialR5, fineArtR5, silverR5

        static let active: [Look] = [.soleil, .leicaM6, .editorial, .cinema, .terra, .silver]

        /// Versioned identifier stored in recipes ("v1r6.<name>"; archived revision-5 looks keep "v1r5.<name>").
        var id: String {
            switch self {
            case .signatureR5: "v1r5.signature"
            case .editorialR5: "v1r5.editorial"
            case .fineArtR5: "v1r5.fineArt"
            case .silverR5: "v1r5.silver"
            default: "v1r6.\(rawValue)"
            }
        }
        var name: String {
            switch self {
            case .leicaM6: "LEICA M6"
            case .signatureR5: "SIGNATURE (rev 5)"
            case .editorialR5: "EDITORIAL (rev 5)"
            case .fineArtR5: "FINE ART (rev 5)"
            case .silverR5: "SILVER (rev 5)"
            default: rawValue.uppercased()
            }
        }
        var isMono: Bool { self == .silver || self == .silverR5 }

        init?(id: String) {
            guard let look = Self.allCases.first(where: { $0.id == id }) else { return nil }
            self = look
        }
    }

    /// Everything that distinguishes a look. Hue tables have 12 nodes at OKLab hue 0°, 30° … 330°:
    /// 0° pink · 30° red · 60° orange/skin · 90° amber · 120° yellow-green/olive · 150° green · 180° green-cyan ·
    /// 210° turquoise · 240° azure sky · 270° ultramarine · 300° violet · 330° magenta.
    struct Style {
        var tone: [(Double, Double)] = [(0, 0), (1, 1)]   // OKLab L in → out, monotone cubic
        var toneChroma = 0.5                              // chroma follows lightness change by (L'/L)^k
        var chroma = 1.0                                  // global chroma gain (neutral-protected)
        var hue = [Double](repeating: 0, count: 12)       // degrees
        var gain = [Double](repeating: 1, count: 12)      // chroma ×
        var lift = [Double](repeating: 0, count: 12)      // OKLab L offset at full colourfulness
        var protect = (0.015, 0.05)                       // chroma ramp below which hue edits fade out (neutrals)
        var restrain = (0.16, 0.30)                       // chroma ramp over which extra gain tapers (no neon)
        var shadowChroma = 0.94                           // chroma × in the deepest values
        var whiteChroma = 0.5                             // chroma removed approaching white
        var clean = 0.0                                   // chroma × reduction of bright near-neutrals
        var density = 0.0                                 // subtractive density: OKLab L lowered by k × chroma
        var mono: SIMD3<Double>?                          // monochrome: linear P3 weights, sum 1
        var monoHue = [Double](repeating: 0, count: 12)   // monochrome: OKLab L offset by original hue at full colour
    }

    static func style(_ look: Look) -> Style {
        var s = Style()
        switch look {
        // ── Revision 6: see research/v1/results/reference-driven-six-looks/LOOKS.md ──
        case .soleil, .leicaM6, .editorial, .cinema, .terra, .silver:
            return style6(look)
        // ── Revision 5, archived unchanged so saved recipes render exactly as before ──
        case .signatureR5:
            // Slim Aarons / McCurry / Call Me by Your Name: clean, substantial, independent colour; dense mids,
            // open shadows, a long highlight shoulder. Deep true blues, fresh (not olive) greens, luminous skin.
            s.tone = [(0, 0), (0.10, 0.080), (0.30, 0.272), (0.50, 0.488), (0.72, 0.725), (0.90, 0.910), (1, 1)]
            s.toneChroma = 0.6
            s.chroma = 1.10
            s.density = 0.10
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [0,    0,    1,    -2,   7,    3,    0,    4,    3,    0,    0,    0]
            s.gain = [1.0,  1.04, 1.0,  0.88, 0.96, 1.12, 1.12, 1.14, 1.12, 1.08, 1.0,  0.98]
            s.lift = [0,    -0.01, 0.012, 0,  0.006, 0.008, 0,  0,    -0.014, -0.018, 0,  0]
            s.restrain = (0.14, 0.28)
            s.clean = 0.2
        case .editorialR5:
            // Cameron Hammond / Russell James: luminous golden skin, clean whites, rich environmental blues,
            // restrained greens and yellows, confident contrast with deep but open shadows.
            s.tone = [(0, 0), (0.10, 0.074), (0.30, 0.262), (0.50, 0.492), (0.72, 0.745), (0.90, 0.922), (1, 1)]
            s.toneChroma = 0.45
            s.chroma = 1.0
            s.density = 0.08
            s.hue  = [0,    3,    4,    0,    -2,   0,    0,    -2,   4,    2,    0,    0]
            s.gain = [0.95, 0.98, 1.08, 0.86, 0.84, 0.88, 0.98, 1.12, 1.22, 1.14, 0.96, 0.94]
            s.lift = [0,    0.006, 0.024, 0.008, -0.01, -0.012, 0, 0.004, -0.02, -0.022, 0, 0]
            s.protect = (0.02, 0.06)
            s.restrain = (0.10, 0.22)   // skin-level chroma gets the golden lift; saturated amber light does not
            s.whiteChroma = 0.6
            s.clean = 0.3
        case .fineArtR5:
            // Fletcher / Hägg / Hardman / Strohl: luminous turquoise and marine blue, differentiated botanical
            // greens, mineral neutrals, bright airy highlights and natural shadow depth. Selective: strong colour
            // is rewarded, low-chroma colour stays natural; reds and yellows held back.
            s.tone = [(0, 0), (0.10, 0.082), (0.30, 0.276), (0.50, 0.495), (0.75, 0.775), (0.92, 0.935), (1, 1)]
            s.toneChroma = 0.6
            s.chroma = 1.06
            s.density = 0.12
            s.hue  = [0,    0,    0,    -2,   9,    4,    -3,   0,    4,    2,    0,    0]
            s.gain = [0.90, 0.92, 0.96, 0.90, 1.0,  1.18, 1.26, 1.32, 1.26, 1.14, 0.98, 0.92]
            s.lift = [0,    0,    0.004, 0,   0.01, 0.016, 0.02, 0.024, -0.018, -0.022, 0, 0]
            s.protect = (0.025, 0.09)
            s.restrain = (0.18, 0.32)
            s.clean = 0.15
        case .silverR5:
            // Comte / Coulson / Adams: red-leaning panchromatic mix (luminous skin, sculpted darker skies),
            // a print curve with dense blacks that keep detail, separated mids and brilliant whites.
            s.tone = [(0, 0), (0.06, 0.032), (0.20, 0.160), (0.45, 0.445), (0.70, 0.735), (0.90, 0.935), (1, 1)]
            s.mono = SIMD3(0.46, 0.46, 0.08)
        }
        return s
    }

    /// Revision 6: six looks authored against the owner's 99 reference photographs (REFERENCE_ANALYSIS.md).
    static func style6(_ look: Look) -> Style {
        var s = Style()
        switch look {
        case .soleil:
            // Sun-bleached summer film (refs 03 04 10 22 23 24 26 39 45 48 88): luminous, airy high-key; a soft
            // film toe; creamy highlights; pale luminous aqua; fresh light greens; peach-golden skin.
            s.tone = [(0, 0.035), (0.10, 0.122), (0.30, 0.325), (0.50, 0.532), (0.72, 0.752), (0.90, 0.918), (1, 1)]
            s.toneChroma = 0.4
            s.chroma = 1.0
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [0,    0,    2,    0,    4,    0,    -3,   -6,   -5,   -2,   0,    0]
            s.gain = [1.02, 0.96, 1.06, 0.90, 1.04, 1.06, 1.12, 1.12, 0.94, 0.90, 0.92, 1.0]
            s.lift = [0.006, 0,   0.018, 0.01, 0.022, 0.014, 0.028, 0.03, 0.022, 0.012, 0,  0.004]
            s.shadowChroma = 0.82
            s.whiteChroma = 0.35
        case .leicaM6:
            // V0 Leica M6 references + Slim Aarons/Kodachrome family (refs 01 02 07 21 36 53 59 98 99): the most
            // chromatic look. Luminous azure, marine and turquoise; substantial emerald/botanical greens split from
            // yellow-green; independent floral pinks; rich blacks, clean whites; skin-level orange held.
            s.tone = [(0, 0), (0.10, 0.068), (0.30, 0.256), (0.50, 0.488), (0.72, 0.742), (0.90, 0.928), (1, 1)]
            s.toneChroma = 0.55
            s.chroma = 1.0
            s.density = 0.08
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [-2,   0,    0,    0,    7,    6,    0,    -3,   -2,   2,    0,    -2]
            s.gain = [1.42, 1.12, 1.02, 0.98, 1.28, 1.50, 1.42, 1.48, 1.46, 1.30, 1.28, 1.40]
            s.lift = [0.012, 0,   0,    0,    0.008, 0.004, 0.006, 0.012, 0.018, 0.014, 0,    0.012]
            s.protect = (0.014, 0.045)
            s.restrain = (0.20, 0.34)
            s.clean = 0.3
        case .editorial:
            // Golden-hour fashion campaign (refs 05 06 07 08 09 14 40 43 54 63; Hammond / Russell James): luminous
            // golden skin at skin-level chroma only, sculpted contrast, clean substantial whites, deep marine blues,
            // natural restrained greens.
            s.tone = [(0, 0), (0.08, 0.046), (0.25, 0.205), (0.50, 0.495), (0.72, 0.765), (0.90, 0.935), (1, 1)]
            s.toneChroma = 0.45
            s.density = 0.08
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [0,    2,    4,    -2,   -3,   0,    0,    2,    4,    2,    0,    0]
            s.gain = [0.94, 1.0,  1.10, 0.88, 0.80, 0.88, 1.06, 1.22, 1.36, 1.24, 0.94, 0.94]
            s.lift = [0,    0.004, 0.03, 0.01, -0.012, -0.015, -0.01, -0.012, -0.018, -0.018, 0, 0]
            s.protect = (0.02, 0.06)
            s.restrain = (0.10, 0.22)
            s.whiteChroma = 0.6
            s.clean = 0.3
        case .cinema:
            // Plein Soleil / Call Me by Your Name / Darjeeling Limited (refs 79 88 89 90 91 92 93 94): rich warm
            // midtones, amber/ochre and vermilion accents, blues toward deep Technicolor teal, natural muted greens,
            // magenta folded toward red, compressed chroma extremes, a soft rolled shoulder.
            s.tone = [(0, 0.014), (0.10, 0.090), (0.30, 0.270), (0.50, 0.480), (0.72, 0.705), (0.90, 0.880), (1, 0.985)]
            s.toneChroma = 0.7
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [-6,   4,    3,    0,    -3,   -6,   -4,   -4,   -7,   -4,   -8,   -8]
            s.gain = [0.86, 1.10, 1.08, 1.16, 0.76, 0.74, 0.88, 1.10, 1.00, 0.86, 0.80, 0.82]
            s.lift = [0,    -0.006, 0.006, 0.012, -0.015, -0.02, -0.02, -0.03, -0.025, -0.015, 0, 0]
            s.restrain = (0.10, 0.24)
            s.shadowChroma = 0.9
            s.whiteChroma = 0.3
        case .terra:
            // Environmental fine art (refs 62 64 66 70 71 72 73 77 78 81 82; Fletcher / Lik / Dombrovskis / Rive):
            // rust earth, mineral neutrals, colour kept in the shadows.
            s.tone = [(0, 0), (0.10, 0.058), (0.30, 0.232), (0.50, 0.465), (0.72, 0.725), (0.90, 0.925), (1, 1)]
            s.toneChroma = 0.65
            s.density = 0.13
            //        0     30    60    90    120   150   180   210   240   270   300   330
            s.hue  = [0,    0,    -2,   -4,   0,    5,    0,    -7,   0,    6,    0,    0]
            s.gain = [0.92, 1.08, 1.0,  0.92, 1.36, 1.44, 1.46, 1.48, 1.18, 1.40, 1.0,  0.92]
            s.lift = [0,    -0.008, -0.004, 0, 0.03, 0.01, 0.026, 0.026, 0.01, 0.004, 0,   0]
            s.protect = (0.025, 0.08)
            s.restrain = (0.20, 0.34)
            s.shadowChroma = 1.04
            s.clean = 0.2
        case .silver:
            // Fashion and fine-art print (refs 57 86 87; Comte / Coulson / Adams / Kenna): panchromatic base, hue-
            // authored response (luminous skin, lips held, skies deepened by hue, foliage separated), a print curve.
            s.tone = [(0, 0), (0.05, 0.020), (0.15, 0.098), (0.30, 0.252), (0.50, 0.512), (0.70, 0.752), (0.88, 0.932), (1, 1)]
            s.mono = SIMD3(0.40, 0.50, 0.10)
            //            0     30    60    90    120   150   180   210    240    270    300    330
            s.monoHue = [0.01, 0.01, 0.05, 0.045, 0.035, 0.02, -0.01, -0.04, -0.085, -0.09, -0.03, 0.0]
        default:
            break
        }
        return s
    }

    // MARK: - Pointwise transform (Double precision, CPU; baked once)

    /// The look as a pure function of an encoded Display P3 colour. Public so tests and the offline harness use it.
    static func transform(_ e: SIMD3<Double>, _ s: Style, toneCurve: MonotoneCurve) -> SIMD3<Double> {
        let lin = SIMD3(decode(e.x), decode(e.y), decode(e.z))
        if let mono = s.mono {
            let y = max(0, (lin * mono).sum())
            var m = cbrt(y)
            if s.monoHue.contains(where: { $0 != 0 }) {   // hue-authored filter response, faded out for neutrals
                let q = OKLab.from(lin), C = (q.y * q.y + q.z * q.z).squareRoot()
                if C > 1e-5 {
                    var h = atan2(q.z, q.y) * 180 / .pi
                    if h < 0 { h += 360 }
                    m += periodic(s.monoHue, h) * min(1, C / 0.12) * smoothstep(0.02, 0.15, m) * (1 - smoothstep(0.9, 1, m))
                }
            }
            let l = toneCurve(min(1, max(0, m)))
            let v = encode(l * l * l)
            return SIMD3(repeating: v)
        }
        var q = OKLab.from(lin)
        let L = q.x
        var C = (q.y * q.y + q.z * q.z).squareRoot()
        if C < 1e-5 {   // exact neutral axis: tone only, no hue
            let l = toneCurve(L)
            return SIMD3(repeating: encode(l * l * l))
        }
        var h = atan2(q.z, q.y) * 180 / .pi
        if h < 0 { h += 360 }
        let w = smoothstep(s.protect.0, s.protect.1, C) * smoothstep(0.02, 0.14, L)

        // Hue → hue, chroma, lightness.
        h += w * periodic(s.hue, h)
        let extra = periodic(s.gain, h) * s.chroma - 1
        let taper = 1 - smoothstep(s.restrain.0, s.restrain.1, C)
        C *= 1 + w * extra * (extra > 0 ? taper : 1)
        var Lc = L + w * min(1, C / 0.12) * periodic(s.lift, h) * (1 - smoothstep(0.85, 1.0, L))
        Lc -= s.density * w * min(C, 0.25) * smoothstep(0.08, 0.3, L) * (1 - smoothstep(0.8, 1.0, L))

        // Master tone curve on lightness; chroma follows by (L'/L)^k so contrast doesn't bleach or neon colour.
        let Lt = toneCurve(min(1, max(0, Lc)))
        if Lc > 1e-4 { C *= pow(max(Lt, 1e-6) / Lc, s.toneChroma) }
        Lc = Lt
        C *= mix(s.shadowChroma, 1, smoothstep(0.04, 0.3, Lc))
        C *= 1 - s.whiteChroma * smoothstep(0.86, 1.0, Lc)
        C *= 1 - s.clean * (1 - smoothstep(0.012, 0.035, C)) * smoothstep(0.7, 0.95, Lc)

        let r = h * .pi / 180
        q = SIMD3(Lc, C * cos(r), C * sin(r))
        let out = gamutMap(q)
        return SIMD3(encode(out.x), encode(out.y), encode(out.z))
    }

    /// Constant-lightness, constant-hue chroma reduction into [0, 1] linear P3 with a soft knee.
    static func gamutMap(_ q: SIMD3<Double>) -> SIMD3<Double> {
        let L = min(1, max(0, q.x))
        let C = (q.y * q.y + q.z * q.z).squareRoot()
        guard C > 1e-9 else { return SIMD3(repeating: L * L * L) }
        let d = SIMD2(q.y, q.z) / C
        func inside(_ c: Double) -> Bool {
            let p = OKLab.to(SIMD3(L, c * d.x, c * d.y))
            return p.min() >= -1e-6 && p.max() <= 1 + 1e-6
        }
        var lo = 0.0, hi = 0.6
        if inside(hi) { lo = hi } else {
            for _ in 0..<24 { let m = (lo + hi) / 2; if inside(m) { lo = m } else { hi = m } }
        }
        let knee = lo * 0.85, width = max(lo - knee, 1e-9)
        let mapped = C <= knee ? C : knee + width * (1 - exp(-(C - knee) / width))
        let p = OKLab.to(SIMD3(L, mapped * d.x, mapped * d.y))
        return SIMD3(min(1, max(0, p.x)), min(1, max(0, p.y)), min(1, max(0, p.z)))
    }

    // MARK: - Baking and application

    /// Cube data: RGBA float32, red fastest, then green, then blue (Core Image layout).
    static func cubeData(_ look: Look, dimension n: Int = dimension) -> Data {
        let s = style(look)
        let curve = MonotoneCurve(s.tone)
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Double(n - 1)
        values.withUnsafeMutableBufferPointer { buffer in
            let out = buffer   // each blue slice writes a disjoint range
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for g in 0..<n { for r in 0..<n {
                    let o = transform(SIMD3(Double(r) * step, Double(g) * step, Double(b) * step), s, toneCurve: curve)
                    let i = ((b * n + g) * n + r) * 4
                    out[i] = Float(o.x); out[i + 1] = Float(o.y); out[i + 2] = Float(o.z)
                } }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let space = CGColorSpace(name: CGColorSpace.displayP3)!
    private static var baked: [Look: Data] = [:]
    private static let bakeLock = NSLock()
    /// Baked once per look on first use; archived looks only when an old recipe needs them.
    static func cube(_ look: Look) -> Data {
        bakeLock.lock(); defer { bakeLock.unlock() }
        if let d = baked[look] { return d }
        let d = cubeData(look)
        baked[look] = d
        return d
    }

    /// Bakes the active cubes off the main thread at launch (≈0.15 s optimized, ≈1.5 s in an unoptimized Debug build).
    static func warm() {
        DispatchQueue.global(qos: .userInitiated).async { for look in Look.active { _ = cube(look) } }
    }

    /// Applies the look exactly once. `data` overrides the baked cube (identity / diagnostic tests).
    static func apply(_ look: Look, to image: CIImage, data: Data? = nil) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data ?? cube(look),
            "inputColorSpace": space,
        ])
    }

    static func identityData(dimension n: Int = dimension) -> Data {
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = ((b * n + g) * n + r) * 4
            values[i] = Float(r) / Float(n - 1); values[i + 1] = Float(g) / Float(n - 1); values[i + 2] = Float(b) / Float(n - 1)
        } } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Short fingerprint of a look's baked cube, logged so the running build is identifiable.
    static func fingerprint(_ look: Look) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in cube(look) { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: - Maths

    static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    static func encode(_ v: Double) -> Double {
        let c = min(1, max(0, v))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Periodic Catmull-Rom through 12 nodes spaced 30°.
    static func periodic(_ v: [Double], _ h: Double) -> Double {
        let x = h / 30, i = Int(floor(x)), t = x - floor(x)
        func at(_ k: Int) -> Double { v[((k % 12) + 12) % 12] }
        let p0: Double = at(i - 1), p1: Double = at(i), p2: Double = at(i + 1), p3: Double = at(i + 2)
        let c1: Double = p2 - p0
        let c2: Double = 2 * p0 - 5 * p1 + 4 * p2 - p3
        let c3: Double = 3 * (p1 - p2) + p3 - p0
        return p1 + 0.5 * t * (c1 + t * (c2 + t * c3))
    }

    /// OKLab for linear Display P3 (Björn Ottosson's matrices composed with P3→XYZ→LMS).
    enum OKLab {
        static func from(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let l = cbrt(0.48137985 * p.x + 0.46211837 * p.y + 0.05650178 * p.z)
            let m = cbrt(0.22883194 * p.x + 0.65321682 * p.y + 0.11795124 * p.z)
            let s = cbrt(0.08394575 * p.x + 0.22416527 * p.y + 0.69188898 * p.z)
            return SIMD3(0.21045426 * l + 0.79361779 * m - 0.00407205 * s,
                         1.97799850 * l - 2.42859220 * m + 0.45059370 * s,
                         0.02590404 * l + 0.78277177 * m - 0.80867581 * s)
        }
        static func to(_ q: SIMD3<Double>) -> SIMD3<Double> {
            let l = q.x + 0.39633778 * q.y + 0.21580376 * q.z
            let m = q.x - 0.10556135 * q.y - 0.06385417 * q.z
            let s = q.x - 0.08948418 * q.y - 1.29148555 * q.z
            let L = l * l * l, M = m * m * m, S = s * s * s
            return SIMD3(3.12776899 * L - 2.25713580 * M + 0.12936681 * S,
                         -1.09100902 * L + 2.41333176 * M - 0.32232274 * S,
                         -0.02601080 * L - 0.50804133 * M + 1.53405213 * S)
        }
    }
}

/// Fritsch–Carlson monotone cubic through control points (x ascending): no overshoot, no reversals.
struct MonotoneCurve {
    let x: [Double], y: [Double], m: [Double]

    init(_ points: [(Double, Double)]) {
        x = points.map(\.0); y = points.map(\.1)
        let n = x.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            let product: Double = d[i - 1] * d[i]
            m[i] = product <= 0 ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a: Double = m[i] / d[i], b: Double = m[i + 1] / d[i]
            let s: Double = a * a + b * b
            if s > 9 {
                let k: Double = 3 / s.squareRoot()
                m[i] = k * a * d[i]
                m[i + 1] = k * b * d[i]
            }
        }
        self.m = m
    }

    func callAsFunction(_ v: Double) -> Double {
        if v <= x[0] { return y[0] + m[0] * (v - x[0]) }
        if v >= x[x.count - 1] { return y[y.count - 1] + m[m.count - 1] * (v - x[x.count - 1]) }
        var i = 0
        while v > x[i + 1] { i += 1 }
        let h = x[i + 1] - x[i], t = (v - x[i]) / h
        let t2: Double = t * t, t3: Double = t2 * t
        let h00: Double = 2 * t3 - 3 * t2 + 1, h10: Double = t3 - 2 * t2 + t
        let h01: Double = 3 * t2 - 2 * t3, h11: Double = t3 - t2
        return h00 * y[i] + h10 * h * m[i] + h01 * y[i + 1] + h11 * h * m[i + 1]
    }
}
