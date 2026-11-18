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

    /// The neutral baseline (strength 0): clean display transform, light and true.
    static let natural = Grade()

    private static let scalars: [WritableKeyPath<Grade, Double>] = [
        \.exposure, \.contrast, \.blackLift, \.whitePoint, \.saturation, \.autoWB, \.temperature, \.tint,
        \.warmSat, \.warmShift, \.greenSat, \.greenShift, \.blueSat, \.blueShift, \.density, \.grain, \.bloom,
    ]

    func mixed(with o: Grade, _ t: Double) -> Grade {
        var g = self
        for k in Grade.scalars { g[keyPath: k] = self[keyPath: k] + (o[keyPath: k] - self[keyPath: k]) * t }
        g.shadowTint = zip(shadowTint, o.shadowTint).map { $0 + ($1 - $0) * t }
        g.highlightTint = zip(highlightTint, o.highlightTint).map { $0 + ($1 - $0) * t }
        return g
    }

    /// Cache key for the 3D LUT: only what's baked into it. Exposure, WB, grain and bloom run outside the LUT,
    /// so dragging those sliders never rebuilds it.
    var lutKey: String {
        ([contrast, saturation, blackLift, whitePoint, warmSat, warmShift, greenSat, greenShift, blueSat, blueShift, density]
            + shadowTint + highlightTint)
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    // MARK: - Display-space grade (runs inside the LUT builder)

    /// Hue/sat by region, density, split tone, levels. Hue math is in an opponent space (R−Y, B−Y)
    /// so luminance is untouched and transitions between hues are smooth (no HSV banding).
    /// Scalar in/out: this runs ~36k times per LUT, and array allocations made it slow in Debug builds.
    func finish(_ r0: Double, _ g0: Double, _ b0: Double) -> (Double, Double, Double) {
        let r0 = min(max(r0, 0), 1), g0 = min(max(g0, 0), 1), b0 = min(max(b0, 0), 1)
        let y = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0
        var a = r0 - y, b = b0 - y
        let chroma = hypot(a, b)
        if chroma > 1e-5 {
            let h = atan2(b, a) * 180 / .pi
            let ww = Grade.weight(h, Grade.warmHue), wg = Grade.weight(h, Grade.greenHue), wb = Grade.weight(h, Grade.blueHue)
            let rot = (warmShift * Grade.warmDir * ww + greenShift * Grade.greenDir * wg + blueShift * Grade.blueDir * wb) * .pi / 180
            let sc = 1 + (warmSat - 1) * ww + (greenSat - 1) * wg + (blueSat - 1) * wb
            (a, b) = ((a * cos(rot) - b * sin(rot)) * sc, (a * sin(rot) + b * cos(rot)) * sc)
        }
        // subtractive density: the more colorful, the deeper
        let d = 1 - density * min(hypot(a, b) * 2.5, 1)
        let yd = y * d
        let r = yd + a * d, bl = yd + b * d
        let gn = (yd - 0.2126 * r - 0.0722 * bl) / 0.7152
        // split tone
        let y2 = 0.2126 * r + 0.7152 * gn + 0.0722 * bl
        let sh = 1 - Grade.smooth(0, 0.45, y2), hl = Grade.smooth(0.45, 1, y2)
        // levels: film blacks and print whites
        func level(_ v: Double, _ i: Int) -> Double {
            blackLift + (whitePoint - blackLift) * min(max(v + shadowTint[i] * sh + highlightTint[i] * hl, 0), 1)
        }
        return (level(r, 0), level(gn, 1), level(bl, 2))
    }

    static func luma(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }
    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let y = luma([r, g, b]); return atan2(b - y, r - y) * 180 / .pi
    }
    private static func dist(_ a: Double, _ b: Double) -> Double { ((a - b + 540).truncatingRemainder(dividingBy: 360)) - 180 }
    private static func weight(_ h: Double, _ center: Double) -> Double { smooth(0, 1, 1 - abs(dist(h, center)) / 55) }

    private static let warmHue = hue(1, 0.45, 0.15), greenHue = hue(0.25, 0.7, 0.2), blueHue = hue(0.2, 0.45, 0.9)
    private static let yellowHue = hue(0.9, 0.85, 0.1), cyanHue = hue(0.1, 0.8, 0.85)
    // rotation direction (±1) that moves each region toward the named neighbor
    private static let warmDir = dist(yellowHue, warmHue) > 0 ? 1.0 : -1.0
    private static let greenDir = dist(yellowHue, greenHue) > 0 ? 1.0 : -1.0
    private static let blueDir = dist(cyanHue, blueHue) > 0 ? 1.0 : -1.0
}

struct Filter: Identifiable, Equatable {
    let id: String
    let name: String
    let grade: Grade

    static func named(_ id: String) -> Filter { all.first { $0.id == id } ?? all[0] }

    static let all: [Filter] = [natural, chroma, portra, eterna, cmbyn, dune, br2049, classicChrome, nostalgicNeg]

    /// Builds a look from the research tables (§5.2 tone/texture, §5.3 hue sectors). Absolute values, not deltas.
    private static func look(_ id: String, _ name: String,
                             _ exposure: Double, _ contrast: Double, _ blackLift: Double, _ whitePoint: Double,
                             _ saturation: Double, _ density: Double, _ grain: Double, _ bloom: Double,
                             temp: Double, warm: (Double, Double), green: (Double, Double), blue: (Double, Double)) -> Filter {
        var g = Grade()
        g.exposure = exposure; g.contrast = contrast; g.blackLift = blackLift; g.whitePoint = whitePoint
        g.saturation = saturation; g.density = density; g.grain = grain; g.bloom = bloom
        g.temperature = temp
        (g.warmSat, g.warmShift) = warm
        (g.greenSat, g.greenShift) = green
        (g.blueSat, g.blueShift) = blue
        return Filter(id: id, name: name, grade: g)
    }

    /// The baseline on its own: should already look like a good camera with no look picked.
    static let natural = Filter(id: "natural", name: "Natural", grade: .natural)

    // Launch looks (research §5.4 priority). Subject intent in comments.
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
