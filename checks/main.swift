// Look engine self-check. Runs the app's real Look.swift + Filters.swift on macOS (no simulator):
//   swiftc -O -o lookcheck BetterCam/Look.swift BetterCam/Filters.swift checks/main.swift && ./lookcheck
// Exits non-zero on failure. Also prints the measured Look.chromaNorm (see its comment).
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
var failed = false
func check(_ ok: Bool, _ msg: String) { print(ok ? "ok  " : "FAIL", msg); if !ok { failed = true } }

var clean = Grade.natural; clean.grain = 0; clean.bloom = 0
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

// 6. Every look keeps neutrals neutral (no tinted whites or colored blacks)
for f in Filter.all + Filter.retired {
    var g = f.grade; g.grain = 0; g.bloom = 0
    let n = render([[0.02, 0.02, 0.02], [0.18, 0.18, 0.18], [1.2, 1.2, 1.2]], g)
    check(n.allSatisfy { chroma($0) < 0.012 }, "\(f.name): neutrals stay neutral (max chroma \(String(format: "%.4f", n.map(chroma).max()!)))")
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
func renderRecipe(_ r: Recipe) -> [[Double]] { var g = r.grade; g.grain = 0; g.bloom = 0; return render(patch, g) }
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
check(refG.grain == 0 && refG.bloom == 0 && refG.microcontrast == 0 && refG.subjectLift == 0 && refG.density == 0
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

exit(failed ? 1 : 0)
