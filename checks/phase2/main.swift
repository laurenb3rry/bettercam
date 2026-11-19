// Phase 2 capture comparison (research/11-phase2-capture.md). Every file goes through the same decode + Natural Reference.
//   swiftc -O -o phase2 BetterCam/Look.swift BetterCam/Filters.swift checks/phase2/main.swift
//   ./phase2 <outdir> <scene> [--at fx,fy] <file.dng>...      (one scene per run: A/B/C/D shots of the same framing)
// Out: <outdir>/<scene>/<label>_full.jpg (full res) · <label>_fit.jpg (2400 px long side: equal display size) ·
//      sheet.jpg (columns = files; rows = fit, equal-FOV crop at --at, 100% crop at --at, equal-FOV shadow crop) ·
//      <outdir>/phase2.json (merged across runs). Frames needn't be aligned: every metric is a tile statistic.
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var args = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: args.removeFirst()), scene = args.removeFirst()
var at = CGPoint(x: 0.5, y: 0.5)
if args.first == "--at" { args.removeFirst(); let v = args.removeFirst().split(separator: ",").map { Double($0)! }; at = CGPoint(x: v[0], y: v[1]) }
let dir = root.appendingPathComponent(scene)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fitSide: CGFloat = 2400, cropPx: CGFloat = 480

func floats(_ img: CIImage, _ cs: CGColorSpace) -> (p: [Float], w: Int, h: Int) {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: cs)
    return (p, w, h)
}
func pct(_ s: [Float], _ q: Double) -> Double { Double(s[min(s.count - 1, Int(q * Double(s.count)))]) }

/// Decoder: max, where the neutral highlight plateau really is (vs the metadata anchor), share sensor-clipped, out-of-sRGB.
func decoderStats(_ img: CIImage) -> [String: Double] {
    let (p, _, _) = floats(img, lin), anchor = img.properties[Look.clipKey] as! Double
    var m = [Float](), atAnchor = 0, neg = 0, hist = [Int](repeating: 0, count: 1500)
    m.reserveCapacity(p.count / 4)
    for i in stride(from: 0, to: p.count, by: 4) {
        m.append(max(p[i], p[i + 1], p[i + 2]))
        if Double(p[i + 1]) >= 0.99 * anchor { atAnchor += 1 }
        if min(p[i], p[i + 1], p[i + 2]) < 0 { neg += 1 }
        hist[min(1499, max(0, Int(Double(p[i + 1]) / anchor * 1000)))] += 1 // green relative to the anchor, 0.1% bins
    }
    m.sort()
    let n = Double(m.count)
    // measured plateau: the highest bin (≥ 50% of the anchor) holding ≥ 0.01% of pixels and ≥ 5× its neighbor 3 bins down
    let plateau = (500..<1499).reversed().first { Double(hist[$0]) > n * 1e-4 && hist[$0] > 5 * max(1, hist[$0 - 3]) }
    return ["max": Double(m.last!), "p99_9": pct(m, 0.999), "anchor": anchor,
            "plateauOverAnchor": plateau.map { Double($0) / 1000 } ?? 0, // ≈1.00 when the anchor is right; 0 = nothing clipped
            "sensorClippedPct": 100 * Double(atAnchor) / n, "negativePct": 100 * Double(neg) / n]
}

/// Rendered (Natural Reference, display P3) at equal display size. Tiles of 16 px:
/// flat = bottom 30% by coarse (4×4-block) texture; textured = top 10%. Noise = fine residual (pixel − 3×3 mean).
func outputStats(_ img: CIImage) -> [String: Double] {
    let (p, w, h) = floats(img, p3)
    let M: [[Double]] = [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0, 0.0451134, 1.0439444]]
    let wp = [0.95047, 1.0, 1.08883]
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
    var L = [Double](repeating: 0, count: w * h), A = L, B = L
    for i in 0..<(w * h) {
        let c = (0..<3).map { Look.toLinear(Double(max(0, p[i * 4 + $0]))) }
        let xyz = (0..<3).map { r in (0..<3).reduce(0.0) { $0 + M[r][$1] * c[$1] } / wp[r] }
        let fx = f(xyz[0]), fy = f(xyz[1]), fz = f(xyz[2])
        L[i] = 116 * fy - 16; A[i] = 500 * (fx - fy); B[i] = 200 * (fy - fz)
    }
    func resid(_ ch: [Double], _ x: Int, _ y: Int) -> Double {
        var s = 0.0; for dy in -1...1 { for dx in -1...1 { s += ch[(y + dy) * w + x + dx] } }
        return ch[y * w + x] - s / 9
    }
    struct Tile { var meanL, coarse, noiseL, noiseC, lap: Double }
    var tiles: [Tile] = []
    let T = 16
    for ty in stride(from: 1, to: h - T - 1, by: T) {
        for tx in stride(from: 1, to: w - T - 1, by: T) {
            var sL = 0.0, rL = 0.0, rC = 0.0, lap = 0.0, blocks: [Double] = []
            for by in stride(from: 0, to: T, by: 4) { for bx in stride(from: 0, to: T, by: 4) {
                var b = 0.0; for y in 0..<4 { for x in 0..<4 { b += L[(ty + by + y) * w + tx + bx + x] } }; blocks.append(b / 16)
            } }
            for y in ty..<(ty + T) { for x in tx..<(tx + T) {
                sL += L[y * w + x]
                let l = resid(L, x, y), a = resid(A, x, y), b = resid(B, x, y)
                rL += l * l; rC += a * a + b * b; lap += abs(l)
            } }
            let n = Double(T * T), bm = blocks.reduce(0, +) / 16
            tiles.append(Tile(meanL: sL / n, coarse: (blocks.map { ($0 - bm) * ($0 - bm) }.reduce(0, +) / 16).squareRoot(),
                              noiseL: (rL / n).squareRoot(), noiseC: (rC / n).squareRoot(), lap: lap / n))
        }
    }
    func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
    func flat(_ band: ClosedRange<Double>) -> [Tile] {
        let t = tiles.filter { band.contains($0.meanL) }.sorted { $0.coarse < $1.coarse }
        return Array(t.prefix(max(1, t.count * 3 / 10)))
    }
    let shadow = flat(8...30), mid = flat(40...65)
    let textured = tiles.sorted { $0.coarse > $1.coarse }.prefix(max(1, tiles.count / 10))
    let Ls = L.map(Float.init).sorted()
    let top = Ls[(Ls.count * 98 / 100)...]
    return ["shadowNoiseL": median(shadow.map(\.noiseL)), "shadowChromaNoise": median(shadow.map(\.noiseC)),
            "midNoiseL": median(mid.map(\.noiseL)), "midChromaNoise": median(mid.map(\.noiseC)),
            "shadowTiles": Double(shadow.count), "detailTextured": median(textured.map(\.lap)),
            "highlightLevels": Double(Set(top.map { Int(($0 * 2.55).rounded()) }).count),
            "crushedPct": 100 * Double(Ls.prefix { $0 < 3 }.count) / Double(Ls.count),
            "Lp5": pct(Ls, 0.05), "Lp50": pct(Ls, 0.5), "Lp99_9": pct(Ls, 0.999)]
}

func meta(_ url: URL) -> (label: String, info: [String: Any]) {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [String: Any]
    let exif = p["{Exif}"] as? [String: Any] ?? [:], dng = p["{DNG}"] as? [String: Any] ?? [:]
    let w = p["PixelWidth"] as? Int ?? 0, h = p["PixelHeight"] as? Int ?? 0
    let pro = Look.isProRAW(url), bias = exif["ExposureBiasValue"] as? Double ?? 0
    let label = "\(pro ? "ProRAW" : "Bayer")\(Int((Double(w * h) / 1e6).rounded()))MP_\(String(format: "%+.1f", bias))EV_" + url.deletingPathExtension().lastPathComponent
    return (label, ["proRAW": pro, "width": w, "height": h, "lens": exif["LensModel"] ?? "?", "iso": (exif["ISOSpeedRatings"] as? [Int])?.first ?? 0,
                    "shutter": exif["ExposureTime"] ?? 0, "bias": bias, "baseline": dng["BaselineExposure"] ?? 0,
                    "neutral": dng["AsShotNeutral"] ?? [], "whiteLevel": dng["WhiteLevel"] ?? [], "nrApplied": dng["NoiseReductionApplied"] ?? "?"])
}

func label(_ s: String) -> CIImage {
    let f = CIFilter(name: "CITextImageGenerator", parameters: ["inputText": s, "inputFontSize": 22, "inputScaleFactor": 1])!
    return f.outputImage!.applyingFilter("CIColorInvert") // white text
}
/// Crop around fractional point `c` with half-size `r` (source pixels), scaled so the result is `cropPx` wide.
func crop(_ img: CIImage, _ c: CGPoint, half r: CGFloat) -> CIImage {
    let e = img.extent, x = e.minX + c.x * e.width, y = e.maxY - c.y * e.height // c is top-left based
    let box = CGRect(x: min(max(e.minX, x - r), e.maxX - 2 * r), y: min(max(e.minY, y - r * 0.75), e.maxY - 1.5 * r), width: 2 * r, height: 1.5 * r)
    let s = cropPx / box.width
    return img.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s])
        .cropped(to: CGRect(x: 0, y: 0, width: cropPx, height: cropPx * 0.75))
}

let reportURL = root.appendingPathComponent("phase2.json")
var report = (try? Data(contentsOf: reportURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
var sceneReport: [String: Any] = [:]
var columns: [(String, [CIImage])] = []
var shadowAt: CGPoint?
let refWidth = args.map { URL(fileURLWithPath: $0) }.compactMap { CIRAWFilter(imageURL: $0)?.nativeSize.width }.min() ?? 4032

/// Variants per file. Bayer: the production path. ProRAW (research/11b): A Apple's default Core Image rendering
/// (its curve, gain-table local tone map, BaselineExposure, SDR), B the first Phase 2 ProRAW path, C corrected.
/// Every BetterCam variant starts from the exposure Library would store for this photo (EXIF bias; ProRAW correction for C).
struct Variant { let tag: String; let legacy: Bool?; let exposure: (URL) -> Double }
let bias = { (u: URL) -> Double in (meta(u).info["bias"] as? Double) ?? 0 }
let bayerPlan = [Variant(tag: "", legacy: false, exposure: { Look.startingExposure($0, captured: true) })]
let proRAWPlan = [Variant(tag: "A-apple", legacy: nil, exposure: { _ in 0 }),
                  Variant(tag: "B-phase2", legacy: true, exposure: { -(bias($0) + Look.rawCompensation) }),
                  Variant(tag: "C-fixed", legacy: false, exposure: { Look.startingExposure($0, captured: true) })]

for path in args {
    let url = URL(fileURLWithPath: path)
    let (fileName, fileInfo) = meta(url)
    for v in Look.isProRAW(url) ? proRAWPlan : bayerPlan {
    let name = v.tag.isEmpty ? fileName : v.tag + "_" + fileName
    var info = fileInfo
    print(name)
    let m0 = Look.footprintMB(), t0 = Date()
    let rendered: CIImage
    if let legacy = v.legacy {
        Look.legacyProRAW = legacy
        defer { Look.legacyProRAW = false }
        guard let base = Look.decode(url) else { print("  can't decode"); continue }
        // 48 MP doesn't fit one float buffer comfortably: decoder stats on a 12 MP-sized copy (smooths 1-px extremes slightly)
        let s = min(1, 4032 / base.extent.width)
        info["decoder"] = decoderStats(s < 1 ? base.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s]).settingProperties(base.properties) : base)
        var grade = Filter.named("naturalReference").grade
        let e = v.exposure(url)
        grade.exposure += e
        info["startingExposure"] = e
        rendered = Look.apply(grade, to: base, analysis: Look.analyze(base, subject: true))
    } else {
        guard let apple = CIRAWFilter(imageURL: url)?.outputImage else { continue } // all Apple defaults
        rendered = apple
    }
    try! Look.jpeg(rendered, quality: 0.95)!.write(to: dir.appendingPathComponent("\(name)_full.jpg"))
    info["fullRenderSec"] = Date().timeIntervalSince(t0)
    info["memDeltaMB"] = Look.footprintMB() - m0
    let fit = rendered.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": fitSide / max(rendered.extent.width, rendered.extent.height)])
    let fitR = Look.materialize(fit)!
    try! Look.jpeg(fitR, quality: 0.95)!.write(to: dir.appendingPathComponent("\(name)_fit.jpg"))
    let o = outputStats(fitR)
    info["output2400"] = o
    // shadow crop point: flattest dark textured region of the first render, reused for all (same scene, approx. same framing)
    if shadowAt == nil {
        let small = floats(fitR.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 0.05]), p3)
        var best = (v: Double.infinity, i: 0)
        for i in 0..<(small.w * small.h) { let v = Double(small.p[i * 4 + 1]); if v > 0.06, v < best.v { best = (v, i) } }
        shadowAt = CGPoint(x: (Double(best.i % small.w) + 0.5) / Double(small.w), y: 1 - (Double(best.i / small.w) + 0.5) / Double(small.h))
    }
    let k = rendered.extent.width / refWidth // equal FOV: the 12 MP crop's field of view in this file's pixels
    let thumb = min(cropPx / fitR.extent.width, cropPx * 0.75 / fitR.extent.height) // portrait or landscape fits the cell
    columns.append((name, [fitR.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": thumb]),
                           crop(rendered, at, half: cropPx / 2 * k), crop(rendered, at, half: cropPx / 2), crop(rendered, shadowAt!, half: cropPx / 2 * k)]))
    sceneReport[name] = info
    let d = info["decoder"] as? [String: Double] ?? [:]
    print(String(format: "  start %+.2f | max %.2f anchor %.2f plateau/anchor %.3f atAnchor %.3f%% | L* p50 %.0f p99.9 %.1f hiLv %.0f crushed %.2f%% | shadow σL %.2f σC %.2f mid σL %.2f σC %.2f | detail %.2f | %.1fs",
                 info["startingExposure"] as? Double ?? .nan, d["max"] ?? .nan, d["anchor"] ?? .nan, d["plateauOverAnchor"] ?? .nan, d["sensorClippedPct"] ?? .nan,
                 o["Lp50"]!, o["Lp99_9"]!, o["highlightLevels"]!, o["crushedPct"]!, o["shadowNoiseL"]!, o["shadowChromaNoise"]!, o["midNoiseL"]!, o["midChromaNoise"]!,
                 o["detailTextured"]!, info["fullRenderSec"] as! Double))
    }
}

// sheet: one column per file
let rowH = [cropPx * 0.75, cropPx * 0.75, cropPx * 0.75, cropPx * 0.75]
let rowNames = ["equal display size", "equal-FOV crop", "100% crop", "equal-FOV shadow crop"]
var sheet = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(columns.count) * (cropPx + 8), height: rowH.reduce(0, +) + 4 * 30 + 40))
for (ci, (name, imgs)) in columns.enumerated() {
    var y = sheet.extent.height - 34
    let x = CGFloat(ci) * (cropPx + 8)
    sheet = label(name).transformed(by: CGAffineTransform(translationX: x + 4, y: y)).composited(over: sheet)
    for (ri, img) in imgs.enumerated() {
        y -= rowH[ri] + 30
        sheet = img.transformed(by: CGAffineTransform(translationX: x - img.extent.minX, y: y - img.extent.minY)).composited(over: sheet)
        if ci == 0 { sheet = label(rowNames[ri]).transformed(by: CGAffineTransform(translationX: x + 4, y: y + rowH[ri] + 4)).composited(over: sheet) }
    }
}
try! Look.jpeg(sheet, quality: 0.9)!.write(to: dir.appendingPathComponent("sheet.jpg"))
sceneReport["cropAt"] = [at.x, at.y]; sceneReport["shadowAt"] = shadowAt.map { [$0.x, $0.y] } ?? []
report[scene] = sceneReport
try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
