// Natural Reference golden set (research/12-phase3-editorial.md §1). Compiles against any Look.swift/Filters.swift version,
// so the reference can be written by the code before a change and checked by the code after it.
//   swiftc -O -o golden BetterCam/Look.swift BetterCam/Filters.swift checks/golden/main.swift
//   ./golden write|check checks/golden/natural-reference.json <files…>
//        Natural Reference at 600 px, 6×6 tiles of mean CIELAB (P3 output). `check` fails if any tile moved > 0.5 ΔE.
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var args = Array(CommandLine.arguments.dropFirst())
let cmd = "golden"

/// P3-encoded output → CIELAB per pixel (D65 white).
func labPixels(_ img: CIImage) -> (L: [Double], a: [Double], b: [Double], enc: [Float], w: Int, h: Int) {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: p3)
    let M = [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0, 0.0451134, 1.0439444]]
    let wp = [0.95047, 1.0, 1.08883]
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
    var L = [Double](repeating: 0, count: w * h), A = L, B = L
    for i in 0..<(w * h) {
        let c = (0..<3).map { Look.toLinear(Double(max(0, p[i * 4 + $0]))) }
        let x = (0..<3).map { r in (M[r][0] * c[0] + M[r][1] * c[1] + M[r][2] * c[2]) / wp[r] }
        L[i] = 116 * f(x[1]) - 16; A[i] = 500 * (f(x[0]) - f(x[1])); B[i] = 200 * (f(x[1]) - f(x[2]))
    }
    return (L, A, B, p, w, h)
}
func q(_ s: [Double], _ f: Double) -> Double { s.isEmpty ? .nan : s[min(s.count - 1, Int(f * Double(s.count)))] }
func fit(_ img: CIImage, _ side: CGFloat) -> CIImage {
    img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": side / max(img.extent.width, img.extent.height)])
}

/// Source → (base image, analysis, starting exposure): the app's engine 2 development (Look.photo: guide-size analysis with
/// local tone development) + Library's starting exposure. Engine 1 references are kept as `<look>-engine1.json`.
func load(_ url: URL, maxSide: CGFloat?) -> (CIImage, Look.Analysis, Double) {
    let (base, a) = Look.photo(url, recipe: Recipe(), maxSide: maxSide)!
    return (base, a, Look.startingExposure(url, captured: true))
}

// MARK: - Golden set: Natural Reference must not move

/// GOLDEN_LOOK=<filter id> checks a look other than Natural Reference (Phase 5: the five approved looks are frozen too).
let environment = ProcessInfo.processInfo.environment
let look = Filter.named(environment["GOLDEN_LOOK"] ?? "naturalReference",
                        revision: environment["GOLDEN_LOOK_REVISION"].flatMap(Int.init) ?? 0)
if cmd == "golden" {
    let mode = args.removeFirst(), json = URL(fileURLWithPath: args.removeFirst())
    var stored = (try? Data(contentsOf: json)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [[Double]]] } ?? [:]
    var failed = false
    for path in args {
        let url = URL(fileURLWithPath: path), key = url.lastPathComponent
        let (base, a, e) = load(url, maxSide: 600)
        var g = look.grade; g.exposure += e
        let o = labPixels(Look.apply(g, to: base, analysis: a))
        var tiles: [[Double]] = []
        for ty in 0..<6 { for tx in 0..<6 {
            var s = [0.0, 0.0, 0.0], n = 0.0
            for y in (ty * o.h / 6)..<((ty + 1) * o.h / 6) { for x in (tx * o.w / 6)..<((tx + 1) * o.w / 6) {
                let i = y * o.w + x; s[0] += o.L[i]; s[1] += o.a[i]; s[2] += o.b[i]; n += 1
            } }
            tiles.append(s.map { ($0 / n * 1000).rounded() / 1000 })
        } }
        if mode == "write" { stored[key] = tiles; print("wrote \(key)"); continue }
        guard let ref = stored[key] else { print("FAIL \(key): not in golden set"); failed = true; continue }
        var d = 0.0
        for (r, t) in zip(ref, tiles) {
            let dl = r[0] - t[0], da = r[1] - t[1], db = r[2] - t[2]
            d = max(d, (dl * dl + da * da + db * db).squareRoot())
        }
        print(d <= 0.5 ? "ok  " : "FAIL", "\(key): \(look.name) max tile ΔE \(String(format: "%.3f", d)) (≤ 0.5)")
        if d > 0.5 { failed = true }
    }
    if mode == "write" {
        try! JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys]).write(to: json)
    }
    exit(failed ? 1 : 0)
}

