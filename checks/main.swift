// Look engine self-check. Runs the app's real Look.swift + Filters.swift on macOS (no simulator):
//   swiftc -O -o lookcheck BetterCam/Look.swift BetterCam/Filters.swift checks/main.swift && ./lookcheck
// Exits non-zero on failure. Also prints the measured Look.chromaNorm (see its comment).
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
var failed = false
func check(_ ok: Bool, _ msg: String) { print(ok ? "ok  " : "FAIL", msg); if !ok { failed = true } }

var clean = Grade.natural; clean.bloom = 0
let noWB = Look.Analysis(wb: (1, 1, 1), clip: 2.4 * 2) // a typical still: sensor clip × (baseline 0, +1 EV)

/// Render scene-linear patches (one per pixel) → sRGB-encoded output.
func render(_ patches: [[Double]], _ g: Grade = clean, analysis: Look.Analysis? = noWB) -> [[Double]] {
    let px: [Float] = patches.flatMap { $0 + [1] }.map { Float($0) }
    let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
    let img = CIImage(bitmapData: data, bytesPerRow: patches.count * 16,
                      size: CGSize(width: patches.count, height: 1), format: .RGBAf, colorSpace: lin)
    let out = Look.apply(g, to: img, analysis: analysis)
    var res = [Float](repeating: 0, count: patches.count * 4)
    Look.context.render(out, toBitmap: &res, rowBytes: patches.count * 16, bounds: img.extent, format: .RGBAf, colorSpace: lin)
    return (0..<patches.count).map { i in (0..<3).map { Look.toEncoded(Double(res[i * 4 + $0])) } }
}
func chroma(_ c: [Double]) -> Double { let y = Grade.luma(c); return hypot(c[0] - y, c[2] - y) }
func hue(_ c: [Double]) -> Double { let y = Grade.luma(c); return atan2(c[2] - y, c[0] - y) * 180 / .pi }
func f3(_ x: Double) -> String { String(format: "%.3f", x) }

// 1. Neutrals stay neutral and land on the research's display targets (§2.3)
let greys = render([[0.18, 0.18, 0.18], [0.9, 0.9, 0.9], [0.0005, 0.0005, 0.0005]])
check(greys.allSatisfy { chroma($0) < 0.004 }, "neutrals stay neutral")
check((0.43...0.50).contains(greys[0][1]), "18% grey → \(f3(greys[0][1])) (target ~0.43–0.47)")
check((0.85...0.97).contains(greys[1][1]), "diffuse white → \(f3(greys[1][1])) (target 0.85–0.97)")
check(greys[2][1] < 0.03, "deep shadow stays dark → \(f3(greys[2][1]))")

// 2. Stable white anchor: a single extreme pixel must not change other pixels
let both = render([[60, 60, 60], [0.18, 0.15, 0.12]])[1], alone = render([[0.18, 0.15, 0.12]])[0]
check(zip(both, alone).allSatisfy { abs($0 - $1) < 1e-4 }, "bright point source doesn't shift other tones")

// 3. Tone curve is monotonic
let ramp = stride(from: -8.0, through: 6.0, by: 0.5).map { s in Array(repeating: 0.18 * pow(2, s), count: 3) }
let rampOut = render(ramp).map { $0[1] }
print("ramp", rampOut.map(f3).joined(separator: " "))
check(zip(rampOut, rampOut.dropFirst()).allSatisfy { $0 <= $1 + 1e-5 }, "tone curve monotonic over −8…+6 stops")

// 4. White balance policy (§7): green cast corrected almost fully; warm cast partly kept; no neutrals = hands off
func residual(_ k: (Double, Double, Double), _ c: (Double, Double, Double)) -> (temp: Double, tint: Double) {
    let r = c.0 * k.0, g = c.1, b = c.2 * k.2
    return (log(r / b) / 2, log(g / sqrt(r * b)))
}
let green = residual(Look.wbGains(r: 0.9, g: 1.0, b: 0.9, coverage: 0.5), (0.9, 1.0, 0.9))
check(abs(green.tint) < 0.1 * log(1 / 0.9), "fluorescent green removed (residual tint \(f3(green.tint)))")
let warm = residual(Look.wbGains(r: 1.3, g: 1.0, b: 0.7, coverage: 0.5), (1.3, 1.0, 0.7))
let warmIn = log(1.3 / 0.7) / 2
check(warm.temp > 0.1 * warmIn && warm.temp < 0.35 * warmIn, "tungsten keeps a little warmth (\(Int(100 * warm.temp / warmIn))% kept)")
let neon = Look.wbGains(r: 1.3, g: 1.0, b: 0.7, coverage: 0)
check(neon.0 == 1 && neon.2 == 1, "no neutral surfaces → no correction")
let shade = residual(Look.wbGains(r: 0.75, g: 1.0, b: 1.3, coverage: 0.5), (0.75, 1.0, 1.3))
let shadeIn = log(0.75 / 1.3) / 2
let shadeKept = shade.temp / shadeIn
check(shadeKept > 0.1 && shadeKept < 0.4, "open shade/snow keeps some blue (\(Int(100 * shadeKept))% kept)")

// 4a. Whole-scene WB (Look.analyze), regions measured from the user's warm-interior DNG (2026-11-18)
func scene(_ parts: [([Double], Int)]) -> CIImage { // (linear rgb, pixel count) laid out in one row of a 96×96 image
    var px: [Float] = []
    for (c, n) in parts { for _ in 0..<n { px += c.map(Float.init) + [1] } }
    let side = Int(Double(px.count / 4).squareRoot())
    px = Array(px.prefix(side * side * 4))
    return CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 16,
                   size: CGSize(width: side, height: side), format: .RGBAf, colorSpace: lin)
}
func warmthAfter(_ gains: (Double, Double, Double), _ c: [Double]) -> Double { log(c[0] * gains.0 / (c[2] * gains.2)) / 2 }
let paper = [0.46, 0.245, 0.125], dayRoom = [0.45, 0.53, 0.62], wood = [0.16, 0.068, 0.017]
let room = Look.analyze(scene([(paper, 5000), (dayRoom, 1300), (wood, 2916)])).wb
check(warmthAfter(room, paper) < 0.2, "warm interior: white paper ends near-white, not yellow (residual T \(f3(warmthAfter(room, paper))), was 0.66)")
let sky = [0.6, 0.8, 1.2], grey = [0.3, 0.3, 0.3], grass = [0.08, 0.15, 0.03]
let day = Look.analyze(scene([(sky, 4000), (grey, 2000), (grass, 3216)])).wb
check(day.0 <= 1.02 && day.2 >= 0.98, "daylight: blue sky doesn't make the photo warmer (gains \(f3(day.0)), \(f3(day.2)))")

// 4b. Subject lift (doc §7.6): only trusted, genuinely dark, recoverable subjects; capped; After Hours never
check(Look.subjectGap(subjectY: 0.05, backgroundY: 0.2, coverage: 0.2, decisiveness: 0.9) > 1.9, "dark subject measured ~2 stops under")
check(Look.subjectGap(subjectY: 0.05, backgroundY: 0.2, coverage: 0.01, decisiveness: 0.9) == 0, "tiny subject ignored")
check(Look.subjectGap(subjectY: 0.05, backgroundY: 0.2, coverage: 0.2, decisiveness: 0.5) == 0, "mushy mask ignored")
check(Look.subjectGap(subjectY: 0.001, backgroundY: 0.2, coverage: 0.2, decisiveness: 0.9) == 0, "unrecoverable black subject ignored")
check(Look.subjectLift(gap: 0.3, maxEV: 0.15) == 0, "subject barely darker → no lift")
check(Look.subjectLift(gap: 6, maxEV: 0.15) == 0.15, "lift capped at the look's max")
check(Look.subjectLift(gap: 6, maxEV: Filter.named("afterHours").grade.subjectLift) == 0, "After Hours never lifts faces")

// 5. Hue holds in bright saturated colors (§8.2): a red lamp shouldn't turn yellow as it brightens
let reds = render([[0.18, 0.02, 0.02], [2.5, 0.28, 0.28]]).map(hue)
check(abs(reds[1] - reds[0]) < 12, "red hue drift into highlights \(String(format: "%.1f", reds[1] - reds[0]))°")

// 6. Every look keeps neutrals neutral (no tinted whites or colored blacks). Looks with an authored print split tone
// (Grade.Print, research/13) are bounded by §17 instead: amber highlights / teal shadow tones are the look, white and black aren't.
for f in Filter.all + Filter.retired where !f.grade.print.on {
    var g = f.grade; g.bloom = 0
    let n = render([[0.02, 0.02, 0.02], [0.18, 0.18, 0.18], [1.2, 1.2, 1.2]], g)
    check(n.allSatisfy { chroma($0) < 0.012 }, "\(f.name): neutrals stay neutral (max chroma \(String(format: "%.4f", n.map(chroma).max()!)))")
    guard !g.monochrome else { continue }
    // red light stays red (After Hours' red door; any look): dim vs bright saturated red keep their hue
    let rr = render([[0.18, 0.02, 0.02], [2.5, 0.28, 0.28]], g).map(hue)
    check(abs(rr[1] - rr[0]) < 12, "\(f.name): red light keeps its hue (drift \(String(format: "%.1f", rr[1] - rr[0]))°)")
}

// 7. ColorChecker-like patches: chroma vs colorimetric at the same luminance → Look.chromaNorm
let checker: [[Double]] = [[115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177], [103, 189, 170],
    [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
    [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31], [187, 86, 149], [8, 133, 161]]
    .map { $0.map { Look.toLinear($0 / 255) * 0.9 } }
var unit = clean; unit.saturation = 1; unit.warmSat = 1; unit.greenSat = 1; unit.blueSat = 1; unit.greenShift = 0; unit.density = 0
let engine = render(checker, unit)
let ratios = zip(checker, engine).map { p, e -> Double in
    let ref = p.map { Look.toEncoded($0 * Look.toLinear(Grade.luma(e)) / max(Grade.luma(p), 1e-6)) }
    return chroma(e) / max(chroma(ref), 1e-6)
}
let mean = ratios.reduce(0, +) / Double(ratios.count)
print(String(format: "info chroma vs colorimetric at saturation 1: %.3f → chromaNorm ≈ %.2f (now %.2f)", mean, Look.chromaNorm / mean, Look.chromaNorm))
check(abs(mean - 1) < 0.08, "saturation 1.0 ≈ colorimetric chroma")

// 8. Every editor slider visibly changes the photo (a mid-tone skin-ish patch and a grey)
let patch: [[Double]] = [[0.25, 0.15, 0.1], [0.18, 0.18, 0.18], [1.5, 1.5, 1.5]]
func renderRecipe(_ r: Recipe) -> [[Double]] { var g = r.grade; g.bloom = 0; return render(patch, g) }
let ref = renderRecipe(Recipe())
// sliders at full travel (doc §8 ranges); Δ ≥ 0.004 ≈ one 8-bit code value
let sliders: [(String, (inout Recipe) -> Void)] = [
    ("exposure", { $0.exposure = Recipe.exposureRange.upperBound }), ("contrast", { $0.contrast = Recipe.contrastRange.upperBound }),
    ("warmth", { $0.warmth = Recipe.warmthRange.upperBound }), ("saturation", { $0.saturation = Recipe.saturationRange.upperBound }),
    ("look switch", { $0.filter = "afterHours" }),
]
for (name, set) in sliders {
    var r = Recipe(); set(&r)
    let diff = zip(renderRecipe(r).joined(), ref.joined()).map { abs($0 - $1) }.max()!
    check(diff > 0.004, "\(name) changes the image (max Δ \(f3(diff)))")
}

// 9. Local contrast: flat areas and neutrals untouched, edges get a little crisper
var micro = clean; micro.microcontrast = 0.03
let flat = Array(repeating: [0.18, 0.15, 0.12], count: 16)
check(zip(render(flat, micro).joined(), render(flat).joined()).allSatisfy { abs($0 - $1) < 1e-3 }, "local contrast leaves flat areas alone")
let step = Array(repeating: [0.05, 0.05, 0.05], count: 1000) + Array(repeating: [0.5, 0.5, 0.5], count: 1000) // radius scales with size: needs a real-width image
let crisp = render(step, micro), soft = render(step)
check(crisp.allSatisfy { chroma($0) < 0.004 }, "local contrast adds no color fringes")
check(crisp[1001][1] > soft[1001][1] && crisp[998][1] < soft[998][1], "local contrast sharpens the edge (\(f3(soft[1001][1]))→\(f3(crisp[1001][1])))")
check(abs(crisp[1001][1] - soft[1001][1]) < 0.03, "…but only slightly (no clarity halo)")

// 10. Recipe migration: pre-v10 imported RAW keeps its −1 EV compensation; look and crop survive
let old = #"{"version":9,"filter":"dune","strength":1,"exposure":-1,"contrast":1,"warmth":0,"saturation":1,"bloom":0,"grain":0,"crop":2}"#
let mig = try! JSONDecoder().decode(Recipe.self, from: Data(old.utf8))
check(mig.filter == "dune" && mig.crop == 2 && mig.baseExposure == -1 && mig.exposure == 0 && mig.contrast == 0,
      "old recipe migrates (look kept, sliders reset, import compensation kept)")
check(Filter.named("dune").id == "dune", "retired looks still render old photos")

// 11. Phase 1 calibrated curve: white sits at the photo's clip, reached through a shoulder (not a plateau);
// grey and midtones don't move when the clip level changes (e.g. per-file baseline exposure)
var refG = Filter.named("naturalReference").grade
check(refG.bloom == 0 && refG.microcontrast == 0 && refG.subjectLift == 0 && refG.density == 0
      && refG.autoWB == 0 && refG.blackLift == 0 && refG.whitePoint == 1, "Natural Reference has no creative stages")
let clipLin = noWB.clip / pow(2, refG.exposure) // the scene level that lands exactly on the clip after exposure
let top = render([[clipLin, clipLin, clipLin], [clipLin / 2, clipLin / 2, clipLin / 2], [clipLin / 8, clipLin / 8, clipLin / 8]], refG)
check(top[0][1] > 0.985, "clipped highlight reaches display white → \(f3(top[0][1]))")
check(top[1][1] < top[0][1] - 0.01 && top[2][1] < top[1][1] - 0.05, "highlights 1 and 3 stops under the clip stay separated (\(f3(top[2][1])) \(f3(top[1][1])) \(f3(top[0][1])))")
var hiClip = noWB; hiClip.clip *= 2.5 // a 4× shot (baseline 1.36): same scene, more headroom
let mids: [[Double]] = [[0.01, 0.01, 0.01], [0.18, 0.18, 0.18], [0.3, 0.2, 0.15]]
check(zip(render(mids, refG).joined(), render(mids, refG, analysis: hiClip).joined()).allSatisfy { abs($0 - $1) < 0.004 },
      "clip level moves only the shoulder, not shadows or midtones")
let refGrey = render([[0.18, 0.18, 0.18]], refG)[0][1]
check((0.47...0.53).contains(refGrey), "Natural Reference: 18% grey → \(f3(refGrey))")

// 12. Exposure slider (Phase 2 §1): grey brightens smoothly and monotonically across the full slider in the LUT's
// 0.05-stop white steps; a clipped highlight stays at white at every setting (white moves with exposure, by design)
var expo: [Double] = [], clipped: [Double] = []
for e in stride(from: Recipe.exposureRange.lowerBound, through: Recipe.exposureRange.upperBound, by: 0.01) {
    var g = refG; g.exposure += e
    let o = render([[0.18, 0.18, 0.18], [clipLin, clipLin, clipLin]], g)
    expo.append(o[0][1]); clipped.append(o[1][1])
}
let steps = zip(expo, expo.dropFirst()).map { $1 - $0 }
// measured: 0.0015 per 0.01 EV, down to 0.0001 where the anchor bucket flips (< ½ 8-bit code: invisible)
check(steps.allSatisfy { $0 >= 0 } && steps.max()! < 1 / 255.0,
      "exposure slider: grey monotonic, no step > 1 code value at white-anchor flips (\(String(format: "%.4f…%.4f", steps.min()!, steps.max()!)))")
check(clipped.allSatisfy { $0 > 0.985 }, "exposure slider: clipped highlight stays white (min \(f3(clipped.min()!)))")

// 13. White anchor from metadata (Phase 2): neutral clip = max/min AsShotNeutral, measured on 11 clipped 17 Pro DNGs
let samples = ProcessInfo.processInfo.environment["DNG_DIR"].map { URL(fileURLWithPath: $0) }
if let dir = samples, let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
    for u in urls where u.pathExtension.lowercased() == "dng" { // skip unless DNG_DIR is set: samples live outside git
        check(Look.neutralClip(u) > 1.5 && Look.neutralClip(u) < 4.5, "\(u.lastPathComponent): anchor \(f3(Look.neutralClip(u)))")
    }
}

// 14. ProRAW (research/11b): anchor = measured neutral ceiling, not the Bayer formula; 12/48 MP exposure consistency.
// Samples live outside git: PRORAW_DIR=research/proRAWs (pairs IMG_6929/6930 and IMG_6932/6931 = same scene 48/12 MP).
func medianGreen(_ img: CIImage) -> Double {
    let s = img.transformed(by: CGAffineTransform(scaleX: 256 / img.extent.width, y: 256 / img.extent.width))
    let e = s.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(s, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: lin)
    let g = stride(from: 1, to: p.count, by: 4).map { p[$0] }.sorted()
    return Double(g[g.count / 2])
}
if let dir = ProcessInfo.processInfo.environment["PRORAW_DIR"] {
    let u = { (n: String) in URL(fileURLWithPath: dir).appendingPathComponent("IMG_\(n).DNG") }
    var level: [String: Double] = [:]
    for n in ["6929", "6930", "6931", "6932", "6933", "6934"] where FileManager.default.fileExists(atPath: u(n).path) {
        let url = u(n)
        let img = Look.decode(url, maxSide: 1024)!
        let gain = pow(2, Double(CIRAWFilter(imageURL: url)!.baselineExposure) + Look.rawCompensation)
        check(Look.isProRAW(url), "IMG_\(n): detected as ProRAW")
        check(abs((img.properties[Look.clipKey] as! Double) / gain - Look.proRAWCeiling) < 1e-9, "IMG_\(n): anchor = ProRAW ceiling, not 1/min(AsShotNeutral) = \(f3(Look.neutralClip(url)))")
        let start = Look.startingExposure(url, captured: true)
        level[n] = log2(medianGreen(img)) + start
        // 15a (research/11c §1): pin the correction (all six are bias 0). If the method changes on purpose, re-measure the
        // pairs on matched surfaces (checks/phase2c `pairs`) before updating these numbers.
        let pinned = ["6929": 1.43, "6930": 0.26, "6931": 0.70, "6932": 1.89, "6933": 1.14, "6934": 1.49][n]!
        check(abs(start + Look.rawCompensation - pinned) < 0.05, "IMG_\(n): ProRAW exposure correction \(f3(start + Look.rawCompensation)) = pinned \(pinned) ± 0.05")
        // 15b (research/11c §1): the ceiling is the data's own maximum neutral, and almost nothing exceeds it per channel
        // (apply() clamps each channel at the anchor, after the AgX inset). 12 MP at native size, 48 MP at half size.
        let full = Look.decode(url, maxSide: 4032)!
        let e = full.extent.integral, w = Int(e.width), h = Int(e.height)
        var p = [Float](repeating: 0, count: w * h * 4)
        Look.context.render(full, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: lin)
        let k = Float(gain), c = Float(Look.proRAWCeiling), ins = Look.inset.map { $0.map(Float.init) }
        var neutralMax: Float = 0, over = 0
        for i in stride(from: 0, to: p.count, by: 4) {
            let r = p[i] / k, g = p[i + 1] / k, b = p[i + 2] / k
            neutralMax = max(neutralMax, min(r, g, b))
            if (0..<3).contains(where: { ins[$0][0] * r + ins[$0][1] * g + ins[$0][2] * b > c }) { over += 1 }
        }
        check(neutralMax <= c * 1.002, "IMG_\(n): neutral max \(f3(Double(neutralMax))) ≤ ceiling")
        if let s = CIRAWFilter(imageURL: url)?.nativeSize, s.width * s.height <= 13_000_000 { check(neutralMax >= c * 0.98, "IMG_\(n): 12 MP lamp reaches the ceiling (\(f3(Double(neutralMax))))") }
        check(Double(over) / Double(w * h) < 0.0005, "IMG_\(n): \(String(format: "%.4f", 100 * Double(over) / Double(w * h)))% of pixels above the anchor in a channel (< 0.05%)")
    }
    for (a, b) in [("6929", "6930"), ("6932", "6931")] {
        if let x = level[a], let y = level[b] {
            check(abs(x - y) < 0.6, "12/48 MP pair \(a)/\(b): median exposure within 0.6 stop (\(String(format: "%.2f", abs(x - y)))); BE alone was ~1.55 apart")
        }
    }
}
if let dir = samples, let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
    check(urls.filter { $0.pathExtension.lowercased() == "dng" }.allSatisfy { !Look.isProRAW($0) }, "Bayer samples stay on the Bayer path")
}

// 16. Phase 3 EDITORIAL (research/12, now retired as `editorialPhase3`) guardrails: a refinement of Natural Reference.
// (Natural Reference itself is frozen by checks/golden on real files.)
do {
    let nr = Filter.naturalReference.grade
    let e100 = Filter.editorialFull
    let nrClean = nr
    func same(_ x: Grade, _ y: Grade) -> Bool {
        x.lutKey == y.lutKey && abs(x.exposure - y.exposure) < 1e-9 && x.autoWB == y.autoWB
    }
    check(same(Grade.mix(nr, Filter.editorialFull, 0), nr) && same(Grade.mix(nr, Filter.editorialFull, 1), Filter.editorialFull),
          "EDITORIAL strength 0 = Natural Reference, 1 = full look (parameters, not images)")
    let ramp = stride(from: -6.0, through: 2.0, by: 1.0).map { s in [0.18 * pow(2, s), 0.18 * pow(2, s), 0.18 * pow(2, s)] }
    let a = render(ramp, nrClean), b = render(ramp, e100)
    check(abs(b[6][1] - a[6][1]) < 0.01, "EDITORIAL keeps mid grey: \(f3(b[6][1])) vs Reference \(f3(a[6][1]))")
    let stopsDown = (0..<6).map { i in log2(Look.toLinear(a[i][1]) / Look.toLinear(b[i][1])) }
    check(stopsDown.allSatisfy { $0 < 0.35 }, "EDITORIAL deep shadows ≤ 0.35 stop under Reference at −6…−1 stops (max \(String(format: "%.2f", stopsDown.max()!)))")
    let midSep = (b[7][1] - b[5][1]) / (a[7][1] - a[5][1])
    check(midSep > 1.03, "EDITORIAL separates midtones more than Reference (±1 stop span × \(String(format: "%.3f", midSep)))")
    check(b.allSatisfy { chroma($0) < 0.004 }, "EDITORIAL neutrals stay neutral")
    let clipped = render([[noWB.clip, noWB.clip, noWB.clip]], e100)[0][1]
    check(clipped > 0.985, "EDITORIAL clipped highlight reaches white (\(f3(clipped))), no grey whites")
    // skin like the measured faces (Lab C 15–27, research/11b, 12): chroma held at Reference by the provisional skinSat
    for (name, s) in [("light skin", [0.30, 0.22, 0.17]), ("deeper skin", [0.12, 0.08, 0.055]), ("bright skin", [0.55, 0.40, 0.31])] {
        let n = render([s], nrClean)[0], e = render([s], e100)[0]
        check(abs(hue(e) - hue(n)) < 3, "EDITORIAL keeps \(name) hue (Δ \(String(format: "%.1f", hue(e) - hue(n)))°)")
        check(abs(chroma(e) / chroma(n) - 1) < 0.05, "EDITORIAL \(name) chroma within ±5% of Reference (× \(String(format: "%.3f", chroma(e) / chroma(n))))")
    }
    // strong warm colors (brick, tan leather) get richer, but stay bounded
    let warm = [[0.30, 0.19, 0.13]], wN = render(warm, nrClean)[0], wE = render(warm, e100)[0]
    check(chroma(wE) / chroma(wN) < 1.12 && abs(hue(wE) - hue(wN)) < 3, "EDITORIAL saturated warm: × \(String(format: "%.3f", chroma(wE) / chroma(wN))) chroma (< 1.12), hue kept")
}

// 17. Phase 3B (research/13): the OkLab print transform and the EDITORIAL v2 candidates. Guardrails only — whether the
// looks are *good* is decided on the sheets, not here.
do {
    check(Grade().print.on == false && Filter.editorial.grade.print.on, "Print transform off by default, on in EDITORIAL")
    check(Filter.named("editorialPhase3").id == "editorialPhase3", "Phase 3 EDITORIAL still renders for comparison")
    check(abs(Grade.Print.at([0, 1, 0, 0, 0, 0, 0], 60) - 1) < 1e-9 && abs(Grade.Print.at([5, 0, 0, 0, 0, 0, 9], 359) - Grade.Print.at([5, 0, 0, 0, 0, 0, 9], -1 + 360)) < 1e-9
          && Grade.Print.at([5, 0, 0, 0, 0, 0, 9], 10) > 5 && Grade.Print.at([5, 0, 0, 0, 0, 0, 9], 10) < 9, "Print sectors interpolate smoothly and wrap at 360°")
    var p = Grade.Print(); p.on = true
    let id = p.apply(0.4, 0.3, 0.2)
    check(abs(id.0 - 0.4) < 1e-4 && abs(id.1 - 0.3) < 1e-4 && abs(id.2 - 0.2) < 1e-4, "Print transform at neutral settings is the identity")
    for c in [Filter.editorial] {
        var g = c.grade; g.bloom = 0
        let ramp = stride(from: -6.0, through: 2.0, by: 1.0).map { s in [0.18 * pow(2, s), 0.18 * pow(2, s), 0.18 * pow(2, s)] }
        let out = render(ramp, g)
        let white = render([[noWB.clip, noWB.clip, noWB.clip]], g)[0], black = render([[0.0005, 0.0005, 0.0005]], g)[0]
        check(chroma(white) < 0.012 && chroma(black) < 0.012, "\(c.name): clipped white and black stay neutral (\(f3(chroma(white))), \(f3(chroma(black))))")
        check(out.allSatisfy { chroma($0) < 0.035 }, "\(c.name): greys stay near-neutral (max chroma \(f3(out.map { chroma($0) }.max()!)), split tone allowed)")
        let reds = render([[2.0, 0.05, 0.03], [0.05, 0.08, 1.6], [0.1, 1.4, 0.08]], g)
        check(reds.allSatisfy { $0.allSatisfy { (0...1).contains($0) } && chroma($0) > 0.15 }, "\(c.name): saturated highlights stay in gamut and keep color")
        let shadowStops = log2(Look.toLinear(render([[0.18 / 32, 0.18 / 32, 0.18 / 32]], Filter.naturalReference.grade)[0][1])
                               / Look.toLinear(out[1][1]))
        check(shadowStops < 0.8, "\(c.name): −5 stops sits \(String(format: "%.2f", shadowStops)) stop under Reference (< 0.8, not crushed)")
    }
    check(Look.subjectLift(gap: 0, maxEV: 0.3) == 0, "no lift without a measured gap")
}

exit(failed ? 1 : 0)
