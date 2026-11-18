// Look engine self-check. Runs the app's real Look.swift + Filters.swift on macOS (no simulator):
//   swiftc -O -o lookcheck BetterCam/Look.swift BetterCam/Filters.swift checks/main.swift && ./lookcheck
// Exits non-zero on failure. Also prints the measured Look.chromaNorm (see its comment).
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
var failed = false
func check(_ ok: Bool, _ msg: String) { print(ok ? "ok  " : "FAIL", msg); if !ok { failed = true } }

var clean = Grade.natural; clean.grain = 0; clean.bloom = 0
let noWB = Look.Analysis(wb: (1, 1, 1))

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
check(warm.temp > 0.3 * warmIn && warm.temp < 0.7 * warmIn, "tungsten keeps some warmth (\(Int(100 * warm.temp / warmIn))% kept)")
let neon = Look.wbGains(r: 1.3, g: 1.0, b: 0.7, coverage: 0)
check(neon.0 == 1 && neon.2 == 1, "no neutral surfaces → no correction")

// 5. Hue holds in bright saturated colors (§8.2): a red lamp shouldn't turn yellow as it brightens
let reds = render([[0.18, 0.02, 0.02], [2.5, 0.28, 0.28]]).map(hue)
check(abs(reds[1] - reds[0]) < 12, "red hue drift into highlights \(String(format: "%.1f", reds[1] - reds[0]))°")

// 6. Every look keeps neutrals neutral (no tinted whites or colored blacks)
for f in Filter.all {
    var g = f.grade; g.grain = 0; g.bloom = 0
    let n = render([[0.02, 0.02, 0.02], [0.18, 0.18, 0.18], [1.2, 1.2, 1.2]], g)
    check(n.allSatisfy { chroma($0) < 0.012 }, "\(f.name): neutrals stay neutral (max chroma \(String(format: "%.4f", n.map(chroma).max()!)))")
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
let sliders: [(String, (inout Recipe) -> Void)] = [
    ("exposure", { $0.exposure = 0.5 }), ("contrast", { $0.contrast = 1.5 }), ("warmth", { $0.warmth = 0.5 }),
    ("saturation", { $0.saturation = 1.5 }), ("strength", { $0.filter = "dune"; $0.strength = 0.5 }),
]
for (name, set) in sliders {
    var r = Recipe(); set(&r)
    let diff = zip(renderRecipe(r).joined(), ref.joined()).map { abs($0 - $1) }.max()!
    check(diff > 0.01, "\(name) slider changes the image (max Δ \(f3(diff)))")
}

exit(failed ? 1 : 0)
