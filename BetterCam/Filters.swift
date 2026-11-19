import Foundation

/// Everything a film look controls. Rendered by Look into one 3D LUT (+ grain/halation passes).
/// Defaults = "Fuji Natural Baseline" (research/rawCameraResearch.md §5.1): a finished, clean photograph.
/// Looks are small deviations from it. All numbers are provisional v0.1 — tune against chart/real captures, not by spec.
/// Order in the LUT: exposure/WB (scene-linear) → curve → saturation → outset → finish() (display-encoded).
struct Grade: Equatable {
    var exposure = 0.55       // stops of render gain (RAW is shot 1 stop under and restored at decode; this is on top)
    var contrast = 0.68       // filmic curve steepness per stop
    var blackLift = 0.003     // display-encoded floor: near-true black, not faded
    var whitePoint = 0.99     // display-encoded ceiling
    var saturation = 0.98     // × Look.chromaNorm; 1 ≈ colorimetric
    var autoWB = 1.0          // share of the scene-aware WB correction to apply (the policy itself lives in Look.wbGains)
    var temperature = 0.0     // -1 cool … +1 warm (±20% R/B gain)
    var tint = 0.0            // -1 green … +1 magenta
    var shadowTint = [0.0, 0.0, 0.0]     // RGB offsets added in the shadows (keep ~0: split toning reads as "filter")
    var highlightTint = [0.0, 0.0, 0.0]  // RGB offsets added in the highlights
    var warmSat = 1.0, warmShift = 0.0   // reds/oranges/skin; shift + toward yellow
    var greenSat = 0.96, greenShift = -1.0 // shift + toward yellow/olive, − toward teal
    var blueSat = 0.98, blueShift = 0.0  // shift + toward cyan
    var density = 0.04        // strong colors get deeper, not neon (subtractive film dyes)
    var grain = 0.06
    var bloom = 0.02          // halation around bright lights
    var microcontrast = 0.0   // luminance local contrast (doc §7.7: 0.01–0.04, never "clarity")
    var subjectLift = 0.0     // max EV a dark, clearly segmented person is lifted (doc §7.6: ≤ 0.15; 0 = never)

    // Phase 3 controls (research/12-phase3-editorial.md). Every default is neutral: looks that don't set them render as before.
    var midContrast = 0.0     // extra log-log slope at mid grey; fades back to the base slope over `toeWidth` stops of shadow
    var toeWidth = 1.5        // stops below grey over which midContrast hands back to the base slope (deep shadows stay readable)
    var hueHold = 0.35        // share of the hue-preserving tone curve (research §8.2: 0.3–0.6); more keeps bright colors from whitening
    var shadowChroma = 1.0    // chroma × in deep shadows (display luma ≲ 0.3), e.g. calmer colored blacks
    var highlightChroma = 1.0 // chroma × in highlights (display luma ≳ 0.55)
    var skinSat = 1.0         // chroma × on skin-like colors only (skin hue, moderate chroma). PROVISIONAL: no calibrated skin target yet
    var greenCompress = 0.0   // 0…1: soft knee on high-chroma greens (anti-neon foliage); low-chroma greens untouched

    // Phase 3B (research/13-phase3b-authored-editorial.md). All neutral by default; only the EDITORIAL v2 candidates set them.
    var print = Print()       // authored OkLab color-volume transform, baked into the LUT
    var warmAdapt = 0.0       // 0…1 of a *measured* warm cast removed on top of as-shot WB (confidence-gated, continuous)
    var tintAdapt = 0.0       // 0…1 of a measured green/magenta cast removed
    var faceLift = 0.0        // max EV a detected face (inside the person mask) is lifted; actual amount is measured per photo
    var backgroundTone = 0.0  // max EV a background brighter than the person is pulled down
    var skinChromaLocal = 1.0 // chroma × on skin colors *inside the person mask only* (a wall of the same color is untouched)
    // Phase 4 (research/14-phase4-look-collection.md). Neutral defaults; EDITORIAL B doesn't set them.
    var skinRegion = false    // skinChromaLocal over the person's measured skin color (face, neck, arms, hands), not the face ellipse only
    var night: Night? = nil   // extra moves faded in by scene darkness (EXIF EV), so a lit room isn't graded like a night street

    /// Deltas at full darkness (EV ≤ `darkEV`), none at EV ≥ `lightEV`, smooth in between (quantized to quarters: LUT cache).
    struct Night: Equatable {
        var darkEV = 4.5, lightEV = 7.5
        var exposure = 0.0, midContrast = 0.0, bloom = 0.0, grain = 0.0
        var chroma = [Double](repeating: 1, count: 7) // × on Print.chroma per sector
    }

    /// The grade with its night deltas applied for this scene (no EXIF EV: daylight behavior).
    func resolved(sceneEV: Double?) -> Grade {
        guard let n = night, let ev = sceneEV else { return self }
        let d = ((1 - Grade.smooth(n.darkEV, n.lightEV, ev)) * 4).rounded() / 4
        guard d > 0 else { return self }
        var g = self
        g.exposure += n.exposure * d; g.midContrast += n.midContrast * d; g.bloom += n.bloom * d; g.grain += n.grain * d
        g.print.chroma = zip(g.print.chroma, n.chroma).map { $0 * (1 + ($1 - 1) * d) }
        return g
    }

    /// Hue × luminance × chroma rendering in OkLab, on display-linear values (research/13 §2). Seven hue sectors with smooth,
    /// wrap-around interpolation between their centers; every move fades out toward neutral, so greys stay grey.
    struct Print: Equatable {
        static let centers: [Double] = [30, 60, 105, 145, 200, 260, 325] // OkLab hue: red, skin/orange, yellow, green, cyan, blue, magenta
        var on = false
        var hueShift = [Double](repeating: 0, count: 7)   // degrees
        var chroma = [Double](repeating: 1, count: 7)     // ×, midtones
        var shadowChroma = [Double](repeating: 1, count: 7)    // extra × in shadows (L ≲ 0.45)
        var highlightChroma = [Double](repeating: 1, count: 7) // extra × in highlights (L ≳ 0.75)
        var luma = [Double](repeating: 0, count: 7)       // ΔL/L for a fully chromatic color (hue-vs-luminance)
        var shadowSplit = [0.0, 0.0]     // OkLab (a, b) added in shadows: film-print crossover
        var highlightSplit = [0.0, 0.0]  // OkLab (a, b) added in highlights
        var density = 0.0                // L × (1 − density·C): saturated colors print deeper
        var skinChroma = 1.0             // × on skin-like hue/chroma (wide, soft gate)
        var gamutKnee = 0.9              // chroma above this share of the gamut edge is compressed, not clipped
        // Phase 4 (research/14). Neutral defaults: EDITORIAL B renders bit-identically.
        var skinProtect = 0.0            // 0…1: share of hueShift/luma/density withheld from skin-gated colors (neighbors' moves don't drag skin)
        var skinHue = 0.0                // degrees added on the skin gate only (+ = toward golden)

        var key: String {
            guard on else { return "p0" }
            let parts: [[Double]] = [hueShift, chroma, shadowChroma, highlightChroma, luma, shadowSplit, highlightSplit, [density, skinChroma, gamutKnee]]
            let extra = skinProtect == 0 && skinHue == 0 ? "" : String(format: ",sp%.4f,%.4f", skinProtect, skinHue)
            return parts.joined().map { String(format: "%.4f", $0) }.joined(separator: ",") + extra
        }

        static func mix(_ a: Print, _ b: Print, _ t: Double) -> Print {
            func m(_ x: [Double], _ y: [Double]) -> [Double] { zip(x, y).map { $0 + ($1 - $0) * t } }
            var p = a
            p.on = a.on || b.on
            p.hueShift = m(a.hueShift, b.hueShift); p.chroma = m(a.chroma, b.chroma); p.luma = m(a.luma, b.luma)
            p.shadowChroma = m(a.shadowChroma, b.shadowChroma); p.highlightChroma = m(a.highlightChroma, b.highlightChroma)
            p.shadowSplit = m(a.shadowSplit, b.shadowSplit); p.highlightSplit = m(a.highlightSplit, b.highlightSplit)
            p.density += (b.density - a.density) * t; p.skinChroma += (b.skinChroma - a.skinChroma) * t
            p.gamutKnee += (b.gamutKnee - a.gamutKnee) * t
            p.skinProtect += (b.skinProtect - a.skinProtect) * t; p.skinHue += (b.skinHue - a.skinHue) * t
            return p
        }

        /// Sector value at hue h: cosine interpolation between the two neighboring centers (wraps at 360°).
        static func at(_ v: [Double], _ h: Double) -> Double {
            let c = centers, n = c.count
            for i in 0..<n {
                let a = c[i], b = i + 1 < n ? c[i + 1] : c[0] + 360
                var x = h; if x < a { x += 360 }
                if x >= a && x < b {
                    let t = (x - a) / (b - a), s = (1 - cos(t * .pi)) / 2
                    return v[i] + (v[(i + 1) % n] - v[i]) * s
                }
            }
            return v[0]
        }

        /// Encoded working RGB in → encoded working RGB out, inside the working gamut.
        func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            func lin(_ v: Double) -> Double { v < 0 ? -Look.toLinear(-v) : Look.toLinear(v) }
            var (L, A, B) = OkLab.from(Look.workingToSRGB(lin(r), lin(g), lin(b)))
            let C0 = hypot(A, B)
            guard C0 > 1e-6 || shadowSplit != [0, 0] || highlightSplit != [0, 0] else { return (r, g, b) }
            var h = atan2(B, A) * 180 / .pi; if h < 0 { h += 360 }
            let cw = Grade.smooth(0.015, 0.08, C0) // how "colorful": hue/luma moves fade out toward neutral
            let sh = 1 - Grade.smooth(0.25, 0.6, L), hi = Grade.smooth(0.65, 0.95, L)
            // skin: wide soft gate on hue 35–85° and moderate chroma (orange paint and red dresses are more chromatic)
            let skinW = Grade.smooth(0, 1, 1 - abs(h - 60) / 30) * Grade.smooth(0.01, 0.03, C0) * (1 - Grade.smooth(0.13, 0.2, C0))
            let keep = 1 - skinProtect * skinW // 1 unless skinProtect: then skin ignores the sector moves around it
            // hue-vs-hue, hue-vs-chroma by luminance band
            let h2 = (h + Print.at(hueShift, h) * cw * keep + skinHue * skinW) * .pi / 180
            let kS: Double = 1 + (Print.at(shadowChroma, h) - 1) * sh
            let kH: Double = 1 + (Print.at(highlightChroma, h) - 1) * hi
            var C: Double = C0 * Print.at(chroma, h) * kS * kH
            C *= 1 + (skinChroma - 1) * skinW
            // hue-vs-luminance and subtractive density (colorful = deeper, like dye)
            L *= (1 + Print.at(luma, h) * cw * keep) * (1 - density * keep * min(C, 0.25))
            // split tone scales with L in the shadows, so black stays neutral (a print's D-max is neutral) and only the
            // shadow *tones* carry the crossover; a constant offset turned near-black visibly teal
            let ws = sh * (1 - hi) * min(L / 0.55, 1)
            A = C * cos(h2) + shadowSplit[0] * ws + highlightSplit[0] * hi
            B = C * sin(h2) + shadowSplit[1] * ws + highlightSplit[1] * hi
            // gamut: compress chroma toward the working gamut edge at this L and hue instead of clipping channels
            let Cn = hypot(A, B)
            if Cn > 1e-6 {
                let hx = A / Cn, hy = B / Cn
                func inside(_ c: Double) -> Bool {
                    let (x, y, z) = Look.sRGBToWorking(OkLab.to(L, c * hx, c * hy))
                    return min(x, y, z) >= -1e-4 && max(x, y, z) <= 1 + 1e-4
                }
                var lo = 0.0, hiC = 0.5
                if L > 0 && L < 1 && !inside(hiC) {
                    for _ in 0..<16 { let m = (lo + hiC) / 2; if inside(m) { lo = m } else { hiC = m } }
                    let edge = lo, k = gamutKnee * edge
                    if Cn > k && edge > 1e-6 {
                        let over = Cn - k, room = edge - k
                        let c = k + room * over / (over + room) // soft knee: approaches the edge, never crosses
                        A = hx * c; B = hy * c
                    }
                }
            }
            let (x, y, z) = Look.sRGBToWorking(OkLab.to(min(max(L, 0), 1), A, B))
            return (Look.toEncoded(x), Look.toEncoded(y), Look.toEncoded(z))
        }
    }

    /// The neutral baseline (the Natural look): clean display transform, light and true.
    static let natural = Grade()

    /// Every continuous parameter, for `mix`. (autoWB is a parameter too: 0 = as-shot, 1 = full scene-aware correction.)
    private static let mixable: [WritableKeyPath<Grade, Double>] = [
        \.exposure, \.contrast, \.blackLift, \.whitePoint, \.saturation, \.autoWB, \.temperature, \.tint,
        \.warmSat, \.warmShift, \.greenSat, \.greenShift, \.blueSat, \.blueShift, \.density, \.grain, \.bloom,
        \.microcontrast, \.subjectLift, \.midContrast, \.toeWidth, \.hueHold, \.shadowChroma, \.highlightChroma,
        \.skinSat, \.greenCompress, \.warmAdapt, \.tintAdapt, \.faceLift, \.backgroundTone, \.skinChromaLocal,
    ]

    /// A look at partial strength: every rendering *parameter* is interpolated (t = 0 → `a`, 1 → `b`) and the result is
    /// rendered once. Not a blend of two finished images, which would mix two tone curves into a third, flatter one.
    static func mix(_ a: Grade, _ b: Grade, _ t: Double) -> Grade {
        var g = a
        for k in mixable { g[keyPath: k] = a[keyPath: k] + (b[keyPath: k] - a[keyPath: k]) * t }
        g.shadowTint = zip(a.shadowTint, b.shadowTint).map { $0 + ($1 - $0) * t }
        g.highlightTint = zip(a.highlightTint, b.highlightTint).map { $0 + ($1 - $0) * t }
        g.print = Print.mix(a.print, b.print, t)
        return g
    }

    /// Cache key for the 3D LUT: only what's baked into it. Exposure, WB, grain and bloom run outside the LUT,
    /// so dragging those sliders never rebuilds it.
    var lutKey: String {
        ([contrast, saturation, blackLift, whitePoint, warmSat, warmShift, greenSat, greenShift, blueSat, blueShift, density,
          midContrast, toeWidth, hueHold, shadowChroma, highlightChroma, skinSat, greenCompress]
            + shadowTint + highlightTint)
            .map { String(format: "%.3f", $0) }.joined(separator: ",") + "|" + print.key
    }

    // MARK: - Display-space grade (runs inside the LUT builder)

    /// Hue/sat by region, density, split tone, levels. Hue math is in an opponent space (R−Y, B−Y)
    /// so luminance is untouched and transitions between hues are smooth (no HSV banding).
    /// Scalar in/out: this runs ~36k times per LUT, and array allocations made it slow in Debug builds.
    func finish(_ ri: Double, _ gi: Double, _ bi: Double) -> (Double, Double, Double) {
        let (rp, gp, bp) = print.on ? print.apply(ri, gi, bi) : (ri, gi, bi) // gamut-mapped before the clamp below
        let r0 = min(max(rp, 0), 1), g0 = min(max(gp, 0), 1), b0 = min(max(bp, 0), 1)
        let (kr, kg, kb) = Look.lumaWeights
        let y = kr * r0 + kg * g0 + kb * b0
        var a = r0 - y, b = b0 - y
        let chroma = hypot(a, b)
        if chroma > 1e-5 {
            let h = atan2(b, a) * 180 / .pi
            let ww = Grade.weight(h, Grade.warmHue), wg = Grade.weight(h, Grade.greenHue), wb = Grade.weight(h, Grade.blueHue)
            let rot = (warmShift * Grade.warmDir * ww + greenShift * Grade.greenDir * wg + blueShift * Grade.blueDir * wb) * .pi / 180
            var sc = 1 + (warmSat - 1) * ww + (greenSat - 1) * wg + (blueSat - 1) * wb
            // Phase 3, luminance-aware chroma: shadows and highlights scaled separately, midtones untouched by these two
            sc *= 1 + (shadowChroma - 1) * (1 - Grade.smooth(0.04, 0.30, y)) + (highlightChroma - 1) * Grade.smooth(0.55, 0.95, y)
            // skin: narrow hue window, and only moderate chroma, so orange paint, brick or a red dress aren't "skin"
            let ws = Grade.smooth(0, 1, 1 - abs(Grade.dist(h, Grade.skinHue)) / 30) * (1 - Grade.smooth(0.20, 0.45, chroma))
            sc *= 1 + (skinSat - 1) * ws
            (a, b) = ((a * cos(rot) - b * sin(rot)) * sc, (a * sin(rot) + b * cos(rot)) * sc)
            // greens: soft knee above 0.10 opponent chroma (≈ C*30), so foliage keeps its color but never goes neon
            let c = hypot(a, b), knee = 0.10
            if greenCompress > 0, wg > 0, c > knee {
                let soft = knee + (c - knee) / (1 + (c - knee) / 0.12)
                let k = 1 + (soft / c - 1) * greenCompress * wg
                a *= k; b *= k
            }
        }
        // subtractive density: the more colorful, the deeper
        let d = 1 - density * min(hypot(a, b) * 2.5, 1)
        let yd = y * d
        let r = yd + a * d, bl = yd + b * d
        let gn = (yd - kr * r - kb * bl) / kg
        // split tone
        let y2 = kr * r + kg * gn + kb * bl
        let sh = 1 - Grade.smooth(0, 0.45, y2), hl = Grade.smooth(0.45, 1, y2)
        // levels: film blacks and print whites
        func level(_ v: Double, _ i: Int) -> Double {
            blackLift + (whitePoint - blackLift) * min(max(v + shadowTint[i] * sh + highlightTint[i] * hl, 0), 1)
        }
        return (level(r, 0), level(gn, 1), level(bl, 2))
    }

    static func luma(_ c: [Double]) -> Double { let k = Look.lumaWeights; return k.0 * c[0] + k.1 * c[1] + k.2 * c[2] }
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }
    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let y = luma([r, g, b]); return atan2(b - y, r - y) * 180 / .pi
    }
    private static func dist(_ a: Double, _ b: Double) -> Double { ((a - b + 540).truncatingRemainder(dividingBy: 360)) - 180 }
    private static func weight(_ h: Double, _ center: Double) -> Double { smooth(0, 1, 1 - abs(dist(h, center)) / 55) }

    /// Skin's display-encoded hue: the median of the six measured faces in research/11b (Lab h 41–50) sits here.
    /// ponytail: one center ±30°; very dark or very pale skin at other hues gets less of `skinSat` — widen if that shows.
    private static let skinHue = hue(0.80, 0.60, 0.50)
    private static let warmHue = hue(1, 0.45, 0.15), greenHue = hue(0.25, 0.7, 0.2), blueHue = hue(0.2, 0.45, 0.9)
    private static let yellowHue = hue(0.9, 0.85, 0.1), cyanHue = hue(0.1, 0.8, 0.85)
    // rotation direction (±1) that moves each region toward the named neighbor
    private static let warmDir = dist(yellowHue, warmHue) > 0 ? 1.0 : -1.0
    private static let greenDir = dist(yellowHue, greenHue) > 0 ? 1.0 : -1.0
    private static let blueDir = dist(cyanHue, blueHue) > 0 ? 1.0 : -1.0
}

/// OkLab (Björn Ottosson 2020) on linear sRGB: a perceptual opponent space where hue and chroma moves stay hue-linear.
enum OkLab {
    static func from(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = c
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    static func to(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
}

struct Filter: Identifiable, Equatable {
    let id: String
    let name: String
    let grade: Grade

    static func named(_ id: String) -> Filter { (all + retired + [naturalReference]).first { $0.id == id } ?? all[0] }

    /// First = default for new photos and the camera. Editorial set (research/newFilters_11_18.md) leads, in its launch order.
    /// Debug builds also list the Natural Reference, so it can be picked on the phone without shipping it.
    #if DEBUG
    static let all: [Filter] = [editorial, riviera, sunStudy, afterHours, alpine, chroma, natural, naturalReference]
    #else
    static let all: [Filter] = [editorial, riviera, sunStudy, afterHours, alpine, chroma, natural]
    #endif
    /// Out of the app but kept: photos already saved with them still render with their look.
    static let retired: [Filter] = [editorialPhase3, editorialV1, portra, eterna, cmbyn, dune, br2049, classicChrome, nostalgicNeg]

    /// Builds a look from the research tables (§5.2 tone/texture, §5.3 hue sectors). Absolute values, not deltas.
    private static func look(_ id: String, _ name: String,
                             _ exposure: Double, _ contrast: Double, _ blackLift: Double, _ whitePoint: Double,
                             _ saturation: Double, _ density: Double, _ grain: Double, _ bloom: Double,
                             temp: Double, warm: (Double, Double), green: (Double, Double), blue: (Double, Double),
                             micro: Double = 0, lift: Double = 0) -> Filter {
        var g = Grade()
        g.exposure = exposure; g.contrast = contrast; g.blackLift = blackLift; g.whitePoint = whitePoint
        g.saturation = saturation; g.density = density; g.grain = grain; g.bloom = bloom
        g.temperature = temp
        (g.warmSat, g.warmShift) = warm
        (g.greenSat, g.greenShift) = green
        (g.blueSat, g.blueShift) = blue
        g.microcontrast = micro; g.subjectLift = lift
        return Filter(id: id, name: name, grade: g)
    }

    /// The baseline on its own: should already look like a good camera with no look picked.
    static let natural = Filter(id: "natural", name: "Natural", grade: .natural)

    /// Diagnostic reference (Phase 1, research/10-phase1-pipeline.md), not a creative look: correct development only.
    /// Camera's as-shot white balance, colorimetric chroma, gentle photographic curve (midtone slope ≈ 1.1 vs the
    /// looks' 1.3–1.6), no hue moves, density, split tone, levels, grain, bloom, unsharp or subject lift.
    /// Creative looks are judged by whether they beat this.
    static let naturalReference: Filter = {
        var g = Grade()
        g.exposure = 0.45; g.contrast = 0.55; g.blackLift = 0; g.whitePoint = 1
        g.saturation = 1; g.autoWB = 0
        g.warmSat = 1; g.greenSat = 1; g.greenShift = 0; g.blueSat = 1
        g.density = 0; g.grain = 0; g.bloom = 0; g.microcontrast = 0; g.subjectLift = 0
        return Filter(id: "naturalReference", name: "Reference", grade: g)
    }()

    // Editorial set (research/newFilters_11_18.md §5), tuned 2026-11-18 by eye against the user's 23 reference photos
    // (the doc's own values were too close to tell apart). Still no tints: differences are tone, density and per-hue
    // chroma, so whites stay white. Warm-sector boosts capped at +2% after "way too yellow" feedback (2026-11-18). micro/lift ranges from doc §7.6/7.7. All provisional: re-tune on real captures.

    /// EDITORIAL (flagship), Phase 3 (research/12-phase3-editorial.md): Natural Reference + a few deliberate moves, at
    /// `editorialStrength` of the full look below. Same exposure, grey, white balance and white point as the Reference.
    /// Phase 3 EDITORIAL (research/12), retired 2026-11-19 after visual review ("effectively no edit"). Kept for comparisons.
    static let editorialPhase3 = Filter(id: "editorialPhase3", name: "Editorial (Phase 3)",
                                        grade: Grade.mix(naturalReference.grade, editorialFull, editorialStrength))
    /// Chosen by visual review of 0/25/50/75/100% renders (research/12 §9). Every parameter scales with it, none blends images.
    static let editorialStrength = 1.0
    /// Full strength. Offsets from Natural Reference, each with one job:
    static let editorialFull: Grade = {
        var g = naturalReference.grade
        g.midContrast = 0.16    // midtone separation; deep shadows only 0.16×1.6 ≈ ¼ stop lower (no crushed toe)
        g.toeWidth = 1.6
        g.hueHold = 0.5         // bright saturated colors keep their color instead of whitening (was 0.35)
        g.saturation = 1.0      // midContrast already adds midtone richness (per-channel slope); more read as a filter
        g.shadowChroma = 0.88   // calmer, cleaner colored blacks (and chroma noise)
        g.highlightChroma = 1.04
        g.greenCompress = 0.6   // foliage rich, never neon
        g.density = 0.03        // saturated colors slightly deeper, film-dye style (old Editorial 0.055)
        g.grain = 0.02          // barely there; binds noise into texture at 100%
        g.skinSat = 0.88        // PROVISIONAL (no calibrated skin reference): cancels the chroma midContrast adds to skin, so skin
                                // stays at Reference chroma (light/deep/bright skin −4…+5%). Not a skin "look"; move this one number later
        return g
    }()
    /// EDITORIAL (flagship), Phase 3B candidate B "Print Editorial" (research/13), chosen by the user 2026-11-19 together with
    /// its selective (person/face) pass, face lift cap +0.30 EV and face skin chroma ×1.2.
    /// Photographic print density, a visible but believable film crossover (teal shadow tones, amber highlights), deep blues and
    /// reds, olive greens, textured highlights with a touch of halation and grain. Sector order: red, skin, yellow, green, cyan, blue, magenta.
    static let editorial: Filter = {
        var g = naturalReference.grade
        g.exposure -= 0.05
        g.midContrast = 0.48; g.toeWidth = 1.1        // print-like snap; toe hands back fast so blacks keep texture
        g.hueHold = 0.6
        g.warmAdapt = 0.2; g.tintAdapt = 0.5          // trims a fifth of a measured warm cast, only in dim (interior) scenes
        var p = Grade.Print(); p.on = true
        p.chroma          = [1.18, 1.00, 0.90, 0.82, 1.05, 1.20, 0.92]
        p.shadowChroma    = [1.05, 0.95, 0.85, 0.80, 1.10, 1.10, 0.85]
        p.highlightChroma = [1.00, 1.00, 0.95, 0.85, 0.90, 0.90, 0.85]
        p.hueShift        = [4, 2, -8, 16, -10, -10, -6] // yellows to amber, greens to olive, blues to teal-navy
        p.luma            = [-0.07, 0.00, -0.02, -0.08, -0.05, -0.12, -0.05]
        p.shadowSplit = [-0.010, -0.012]    // teal-cool shadow tones (crossover)
        p.highlightSplit = [0.004, 0.009]   // amber highlights
        p.density = 0.30
        p.skinChroma = 1.03                 // global gate kept small: it can't tell skin from a same-colored wall or hoodie
        g.print = p
        g.shadowChroma = 0.92
        g.grain = 0.06; g.bloom = 0.03
        g.faceLift = 0.30; g.backgroundTone = 0.25; g.skinChromaLocal = 1.20 // user's pick from the face ladder
        return Filter(id: "editorial", name: "Editorial", grade: g)
    }()

    // MARK: Phase 4 looks (research/14-phase4-look-collection.md), promoted by the user 2026-11-19 (old versions removed).
    // Same engine as EDITORIAL B (OkLab print transform + selective pass), each with
    // its own tone curve, hue×luminance map, crossover and selective treatment. Sector order: red, skin, yellow, green, cyan, blue, magenta.
    /// Shared portrait rules for all four: skin keeps its hue while neighboring sectors move (skinProtect), local skin chroma
    /// covers the person's measured skin (face, neck, arms), never the clothes or walls; face lift is measured and capped.
    private static func p4Base() -> (Grade, Grade.Print) {
        var g = naturalReference.grade
        g.skinRegion = true
        var p = Grade.Print(); p.on = true; p.skinProtect = 0.75
        return (g, p)
    }

    /// RIVIERA: Mediterranean coastal film. Open and airy (soft mids, long toe, +⅙ EV), luminous skin, water that separates by
    /// *luminance*: turquoise lifted and nudged green, deep blue darkened toward navy. Creamy highlights from a highlight-only
    /// amber split on near-white (scaled to L, so mid-grey walls don't tint), faint cool air in the shadow tones, quiet olive greens.
    static let riviera: Filter = {
        var (g, p) = p4Base()
        g.exposure += 0.17
        g.midContrast = 0.20; g.toeWidth = 2.2
        g.hueHold = 0.65                                   // bright sea/sky stay colored instead of whitening
        p.chroma          = [1.04, 1.04, 0.92, 0.84, 1.14, 1.12, 0.90]
        p.shadowChroma    = [1.00, 1.00, 0.90, 0.85, 1.08, 1.12, 0.90]
        p.highlightChroma = [0.95, 1.02, 0.88, 0.85, 1.05, 0.95, 0.85]
        p.hueShift        = [2, 0, -4, 10, -7, -3, -4]     // greens olive, cyan toward turquoise
        p.luma            = [-0.02, 0.02, 0.02, -0.04, 0.05, -0.10, -0.02] // turquoise up, deep blue down
        p.shadowSplit = [-0.003, -0.006]                    // sea air in the shadow tones (half of B's crossover)
        p.highlightSplit = [0.003, 0.007]                   // cream, not yellow
        p.density = 0.14; p.skinChroma = 1.02; p.skinHue = 2
        g.print = p
        g.shadowChroma = 0.95; g.highlightChroma = 0.98
        g.grain = 0.05; g.bloom = 0.035
        g.faceLift = 0.25; g.backgroundTone = 0.10; g.skinChromaLocal = 1.12
        return Filter(id: "riviera", name: "Riviera", grade: g)
    }()

    /// SUN STUDY: sculpted natural sunlight. Firm mids with a readable toe, warmth that lives in warm *lit* colors (skin/yellow
    /// highlight chroma, golden skin hue) rather than a global tint, so white shirts and snow stay white. Skin is dimensional:
    /// richer chroma on its shadow side, slightly calmer in its brightest highlights (no orange glare). Deep sky/water blues.
    static let sunStudy: Filter = {
        var (g, p) = p4Base()
        g.exposure += 0.02
        g.midContrast = 0.40; g.toeWidth = 1.5
        g.hueHold = 0.6
        p.chroma          = [1.10, 1.06, 1.04, 0.90, 1.00, 1.14, 0.92]
        p.shadowChroma    = [1.06, 1.12, 1.00, 0.88, 0.95, 1.10, 0.90] // warm, rich skin shadow side
        p.highlightChroma = [1.00, 1.06, 1.08, 0.88, 0.90, 0.95, 0.85] // sunlit warm surfaces carry color, cool highlights calm
        p.hueShift        = [3, 0, -5, 8, -4, -6, -4]
        p.luma            = [-0.04, 0.00, 0.03, -0.06, -0.04, -0.12, -0.04] // yellow sun up, blue sky down
        p.shadowSplit = [-0.002, -0.004]
        p.highlightSplit = [0.002, 0.004]                   // a trace only: whites stay white
        p.density = 0.22; p.skinChroma = 1.03; p.skinHue = 3 // golden, against Phase 3B's redder skin drift
        g.print = p
        g.warmAdapt = 0                                     // warm light is the point; as-shot WB only
        g.grain = 0.045; g.bloom = 0.025; g.microcontrast = 0.015
        g.faceLift = 0.20; g.backgroundTone = 0.15; g.skinChromaLocal = 1.12
        return Filter(id: "sunStudy", name: "Sun Study", grade: g)
    }()

    /// ALPINE: premium outdoor clarity. Tonal separation, not temperature: bright neutral snow (highlight chroma calmed, no
    /// split), deep but believable blues (darkened by luminance, not saturated to neon), dark evergreens kept apart by hue
    /// (toward teal-green) and lightness, gentle local contrast for rock/fabric texture. Skin held natural in cool light.
    static let alpine: Filter = {
        var (g, p) = p4Base()
        g.exposure += 0.08
        g.midContrast = 0.34; g.toeWidth = 1.4
        g.hueHold = 0.55
        g.tintAdapt = 0.4                                   // trims a measured green/magenta cast; temperature left as shot
        p.chroma          = [1.06, 1.00, 1.08, 0.94, 1.08, 1.16, 0.90]
        p.shadowChroma    = [1.00, 1.00, 0.95, 1.00, 1.05, 1.08, 0.88]
        p.highlightChroma = [0.95, 0.98, 1.00, 0.85, 0.80, 0.82, 0.85] // snow and white sky stay clean
        p.hueShift        = [0, 0, -3, -6, -3, -4, -4]      // forests toward deep spruce, blues toward true blue
        p.luma            = [-0.03, 0.00, 0.02, -0.10, -0.06, -0.14, -0.04] // dimensional landscape: greens and blues deeper
        p.shadowSplit = [-0.002, -0.004]
        p.highlightSplit = [0, 0]
        p.density = 0.20; p.skinChroma = 1.02; p.skinHue = 1.5
        g.print = p
        g.shadowChroma = 0.95
        g.grain = 0.03; g.bloom = 0.01; g.microcontrast = 0.03
        g.faceLift = 0.25; g.backgroundTone = 0.10; g.skinChromaLocal = 1.08
        return Filter(id: "alpine", name: "Alpine", grade: g)
    }()

    /// AFTER HOURS: cinematic night and flash. Deep, still-textured blacks (steep mids, short toe, −⅙ EV), practicals kept
    /// colored (as-shot WB, no warm adaptation, high hueHold), calm chroma noise in the shadows, visible fine grain.
    /// Its theatrical part is *gated by darkness* (`night`, EXIF EV ≤ 4.5 full, ≥ 7.5 none): darker exposure, more red/amber/
    /// blue/magenta, bloom around real sources. A neutral fluorescent room (EV ≈ 8) gets only the dense day version.
    static let afterHours: Filter = {
        var (g, p) = p4Base()
        g.exposure -= 0.17
        g.midContrast = 0.52; g.toeWidth = 1.0
        g.hueHold = 0.75
        p.chroma          = [1.12, 1.00, 0.95, 0.85, 0.98, 1.08, 1.02]
        p.shadowChroma    = [1.00, 0.95, 0.85, 0.80, 0.90, 1.00, 0.95]
        p.highlightChroma = [1.06, 1.02, 1.00, 0.85, 0.90, 0.95, 1.00] // lit practicals keep their color
        p.hueShift        = [-2, 0, -6, 6, -6, -4, 4]
        p.luma            = [-0.04, 0.00, -0.02, -0.08, -0.06, -0.10, -0.04]
        p.shadowSplit = [-0.004, -0.007]
        p.highlightSplit = [0.003, 0.004]
        p.density = 0.24; p.skinChroma = 1.02; p.skinHue = 2
        g.print = p
        g.shadowChroma = 0.85                               // clean colored blacks, less chroma noise
        g.grain = 0.09; g.bloom = 0.03
        g.faceLift = 0.15; g.backgroundTone = 0.25; g.skinChromaLocal = 1.10 // subject lit against a darker room, no daylight lift
        var n = Grade.Night()
        n.exposure = -0.25; n.midContrast = 0.06; n.bloom = 0.04; n.grain = 0.03
        n.chroma = [1.10, 1.00, 1.06, 1.00, 1.04, 1.10, 1.12]
        g.night = n
        return Filter(id: "afterHours", name: "After Hours", grade: g)
    }()

    /// EDITORIAL v1 (2026-11-18 until Phase 3), retired: kept so saved comparisons can be reproduced and the change reverted.
    /// Its midtone slope 1.51, auto-WB, unsharp mask and 0.993 white point are what Phase 3 removed.
    static let editorialV1 = look("editorialV1", "Editorial v1", 0.50, 0.76, 0.000, 0.993, 1.00, 0.055, 0.04, 0.012,
                                  temp: 0, warm: (1.00, 0), green: (0.97, 0), blue: (1.03, 0), micro: 0.02, lift: 0.15)

    // Earlier looks (research/rawCameraResearch.md §5.4). Subject intent in comments.
    /// Chromagraph-inspired: skin gently warmer, not orange; soft bright transitions; quieter greens/blues.
    static let chroma = look("chroma", "Chroma", 0.48, 0.71, 0.003, 0.987, 0.96, 0.050, 0.12, 0.10,
                             temp: 0.012, warm: (1.02, -1), green: (0.93, -1), blue: (0.93, 0))
    /// Portra 400: soft pink/peach skin, gentle shoulder, restrained foliage, fine grain.
    static let portra = look("portra", "Portra", 0.60, 0.66, 0.005, 0.992, 0.97, 0.035, 0.14, 0.025,
                             temp: 0.008, warm: (1.02, -1), green: (0.93, -1), blue: (0.97, 0))
    /// Eterna: very natural skin, soft gradation, quiet color. (sat .89→.91, green .95→.96: global and hue sat compound)
    static let eterna = look("eterna", "Eterna", 0.56, 0.63, 0.004, 0.993, 0.91, 0.030, 0.06, 0.010,
                             temp: 0, warm: (1.00, 0), green: (0.96, 0), blue: (0.98, 0))

    // Secondary looks: tune after the baseline is chart-validated.
    /// Call Me by Your Name: airy mids, soft contrast, less neon garden green, whites stay white.
    static let cmbyn = look("cmbyn", "Summer", 0.62, 0.65, 0.006, 0.990, 0.95, 0.035, 0.16, 0.04,
                            temp: 0.010, warm: (1.02, -1), green: (0.93, -2), blue: (0.95, 0))
    /// Dune editorial: denser mids, darker-but-readable shadows, restrained greens/blues. Not sand-orange faces.
    /// (§5.3: table's sat .88 × green .88 compounds to −23%; using the suggested .93 / .96)
    static let dune = look("dune", "Arrakis", 0.46, 0.72, 0.003, 0.987, 0.93, 0.060, 0.08, 0.02,
                           temp: 0.012, warm: (0.99, 0), green: (0.96, -1), blue: (0.94, 0))
    /// Blade Runner 2049 editorial: more shadow structure, deep non-muddy greens, denser skies; clean whites.
    static let br2049 = look("br2049", "2049", 0.49, 0.72, 0.003, 0.988, 0.92, 0.055, 0.08, 0.035,
                             temp: 0, warm: (1.01, 0), green: (0.94, -2), blue: (0.95, -2))
    /// Classic Chrome: muted, defined shadows, slightly cooler cyan-ish blues; restrained, not grey.
    static let classicChrome = look("classicChrome", "Classic Chrome", 0.52, 0.72, 0.002, 0.989, 0.91, 0.055, 0.08, 0.015,
                                    temp: 0, warm: (0.98, 0), green: (0.94, -1), blue: (0.94, -2))
    /// Nostalgic Neg: subtle warmth, subdued greens/blues, firm shadows.
    static let nostalgicNeg = look("nostalgicNeg", "Nostalgic Neg", 0.57, 0.70, 0.003, 0.987, 0.95, 0.055, 0.10, 0.025,
                                   temp: 0.012, warm: (1.03, 1), green: (0.92, -1), blue: (0.93, 0))
}
