// Phase 3 EDITORIAL evaluation (research/12-phase3-editorial.md). Renders through the app's own Look.swift + Filters.swift.
//   swiftc -O -o phase3 BetterCam/Look.swift BetterCam/Filters.swift checks/phase3/main.swift
//   ./phase3 scene <outdir> <name> <file> [--crop label:x,y,w,h]… [--p3]
//        Natural Reference (0%) · EDITORIAL 25/50/75/100% (parameters interpolated, Grade.mix) · old EDITORIAL v1
//        [· 100% on the experimental P3 working space]. Writes full-resolution JPEGs, a contact sheet (row 1 = whole image at
//        equal display size, then one row per crop at the same source pixels), and metrics.json.
//        Crop = top-left fractions of the upright image.
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.removeFirst() // "scene"

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

/// Source → (base image, analysis, starting exposure). DNG: the app's decode + Library's starting exposure. HEIC/JPEG: look only.
func load(_ url: URL, maxSide: CGFloat?) -> (CIImage, Look.Analysis, Double) {
    let base = Look.decode(url, maxSide: maxSide)!
    let a = Look.analyze(base, subject: true)
    return (base, a, Look.startingExposure(url, captured: true))
}

// MARK: - Scene comparison

guard cmd == "scene" else { print("unknown command"); exit(2) }
let root = URL(fileURLWithPath: args.removeFirst()), name = args.removeFirst(), url = URL(fileURLWithPath: args.removeFirst())
var crops: [(String, CGRect)] = [], withP3 = false
while let f = args.first {
    args.removeFirst()
    if f == "--p3" { withP3 = true; continue }
    let parts = args.removeFirst().split(separator: ":"), v = parts[1].split(separator: ",").map { Double($0)! }
    crops.append((String(parts[0]), CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
}
let dir = root.appendingPathComponent(name)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let (base, analysis, start) = load(url, maxSide: nil)
let nr = Filter.naturalReference.grade, full = Filter.editorialFull
var variants: [(String, Grade, Bool)] = [
    ("0 Natural Reference", nr, false), ("EDITORIAL 25%", Grade.mix(nr, full, 0.25), false), ("EDITORIAL 50%", Grade.mix(nr, full, 0.5), false),
    ("EDITORIAL 75%", Grade.mix(nr, full, 0.75), false), ("EDITORIAL 100%", full, false), ("old EDITORIAL v1", Filter.editorialV1.grade, false),
]
if withP3 { variants.append(("EDITORIAL 100% P3-working", full, true)) }

struct Rendered { let name: String; let img: CIImage; let fitImg: CIImage }
var rendered: [Rendered] = []
for (vn, g0, useP3) in variants {
    var g = g0; g.exposure += start
    Look.workingP3 = useP3
    let img = Look.apply(g, to: base, analysis: analysis)
    let fileName = vn.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "%", with: "pct")
    try! Look.jpeg(img, quality: 0.92)!.write(to: dir.appendingPathComponent("\(name)_\(fileName).jpg"))
    rendered.append(Rendered(name: vn, img: img, fitImg: Look.materialize(fit(img, 1600))!))
    Look.workingP3 = false
    print("rendered \(vn)")
}

// metrics at equal display size (1600 px)
func region(_ o: (L: [Double], a: [Double], b: [Double], enc: [Float], w: Int, h: Int), _ r: CGRect) -> [Int] {
    let x0 = Int(r.minX * Double(o.w)), x1 = Int(r.maxX * Double(o.w)), y0 = Int(r.minY * Double(o.h)), y1 = Int(r.maxY * Double(o.h))
    return (max(1, y0)..<min(o.h - 1, y1)).flatMap { y in (max(1, x0)..<min(o.w - 1, x1)).map { y * o.w + $0 } }
}
var metrics: [String: Any] = ["source": url.lastPathComponent, "startingExposure": start]
var refStats: [String: (L: Double, C: Double, h: Double)] = [:]
var lines: [String] = []
lines.append(String(format: "%-26@ %5@ %5@ %5@ %5@ %6@ %7@ %6@ %6@ %6@ %6@", "variant" as NSString, "Lp1" as NSString, "Lp5" as NSString,
                    "Lp50" as NSString, "Lp95" as NSString, "Lp99.9" as NSString, "crush%" as NSString, "shLv" as NSString,
                    "hiLv" as NSString, "white%" as NSString, "clip%" as NSString))
for r in rendered {
    let o = labPixels(r.fitImg)
    let Ls = o.L.sorted(), n = Double(Ls.count)
    let shadow = Ls.prefix(Ls.count / 10), top = Ls.suffix(Ls.count / 50)
    var clipped = 0
    for i in 0..<(o.w * o.h) {
        let c = [o.enc[i * 4], o.enc[i * 4 + 1], o.enc[i * 4 + 2]]
        if c.max()! - c.min()! > 0.1, c.max()! >= 0.998 || c.min()! <= 0.002 { clipped += 1 }
    }
    // fine texture: mean |L − 3×3 mean|
    func texture(_ idx: [Int]) -> Double {
        idx.map { i -> Double in
            var s = 0.0; for dy in -1...1 { for dx in -1...1 { s += o.L[i + dy * o.w + dx] } }
            return abs(o.L[i] - s / 9)
        }.reduce(0, +) / Double(max(1, idx.count))
    }
    var m: [String: Any] = [
        "Lp1": q(Ls, 0.01), "Lp5": q(Ls, 0.05), "Lp50": q(Ls, 0.5), "Lp95": q(Ls, 0.95), "Lp99_9": q(Ls, 0.999),
        "crushedPct": 100 * Double(Ls.prefix { $0 < 2 }.count) / n,
        "shadowLevels": Set(shadow.map { Int(($0 * 2).rounded()) }).count, "highlightLevels": Set(top.map { Int(($0 * 2).rounded()) }).count,
        "whitePct": 100 * Double(Ls.reversed().prefix { $0 > 98.5 }.count) / n, "colorClipPct": 100 * Double(clipped) / n,
        "meanChroma": zip(o.a, o.b).map { hypot($0, $1) }.reduce(0, +) / n,
        "shadowTexture": texture((0..<(o.w * o.h)).filter { i in i > o.w && i < o.w * (o.h - 1) && i % o.w > 0 && i % o.w < o.w - 1 && o.L[i] < 20 }),
    ]
    lines.append(String(format: "%-26@ %5.1f %5.1f %5.1f %5.1f %6.1f %7.2f %6d %6d %6.2f %6.2f", r.name as NSString, m["Lp1"] as! Double,
                        m["Lp5"] as! Double, m["Lp50"] as! Double, m["Lp95"] as! Double, m["Lp99_9"] as! Double, m["crushedPct"] as! Double,
                        m["shadowLevels"] as! Int, m["highlightLevels"] as! Int, m["whitePct"] as! Double, m["colorClipPct"] as! Double))
    var cm: [String: Any] = [:]
    for (cn, cr) in crops {
        let idx = region(o, cr)
        let Lm = idx.map { o.L[$0] }.sorted(), am = idx.map { o.a[$0] }.reduce(0, +) / Double(idx.count), bm = idx.map { o.b[$0] }.reduce(0, +) / Double(idx.count)
        let st = (L: q(Lm, 0.5), C: hypot(am, bm), h: (atan2(bm, am) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        if r.name.hasPrefix("0 ") { refStats[cn] = st }
        let ref = refStats[cn] ?? st
        let dh = ((st.h - ref.h + 540).truncatingRemainder(dividingBy: 360)) - 180
        cm[cn] = ["L": st.L, "C": st.C, "h": st.h, "Lp5": q(Lm, 0.05), "texture": texture(idx), "dL": st.L - ref.L, "dC": st.C - ref.C, "dh": dh]
        lines.append(String(format: "    %-16@ L %5.1f (p5 %5.1f)  C %5.1f  h %5.1f   Δ vs NR: L %+5.1f C %+5.1f h %+5.1f   texture %.2f",
                            cn as NSString, st.L, q(Lm, 0.05), st.C, st.h, st.L - ref.L, st.C - ref.C, dh, texture(idx)))
    }
    m["crops"] = cm
    metrics[r.name] = m
}
try! JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("metrics.json"))
try! lines.joined(separator: "\n").write(to: dir.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
print(lines.joined(separator: "\n"))

// contact sheet
let cw: CGFloat = 520, lh: CGFloat = 34
func label(_ s: String) -> CIImage {
    CIFilter(name: "CITextImageGenerator", parameters: ["inputText": s, "inputFontSize": 20, "inputScaleFactor": 1])!
        .outputImage!.applyingFilter("CIColorInvert")
}
let first = rendered[0].fitImg.extent
let topH = cw * first.height / first.width
let cropH = cw * 0.75
let rowHs = [topH] + crops.map { _ in cropH }
let sheetH = rowHs.reduce(0, +) + CGFloat(rowHs.count) * lh + lh
var sheet = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06))
    .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(rendered.count) * (cw + 8), height: sheetH))
for (ci, r) in rendered.enumerated() {
    let x = CGFloat(ci) * (cw + 8)
    var y = sheetH - lh
    sheet = label(r.name).transformed(by: CGAffineTransform(translationX: x + 4, y: y + 6)).composited(over: sheet)
    let s0 = cw / r.fitImg.extent.width
    var cells: [(String, CIImage)] = [("", r.fitImg.transformed(by: CGAffineTransform(scaleX: s0, y: s0)))]
    for (cn, cr) in crops {
        let e = r.img.extent
        let box = CGRect(x: e.minX + cr.minX * e.width, y: e.maxY - cr.maxY * e.height, width: cr.width * e.width, height: cr.height * e.height)
        let s = min(cw / box.width, cropH / box.height)
        cells.append(("\(cn) (\(String(format: "%.0f", s * 100))%)", r.img.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s])))
    }
    for (ri, (cn, img)) in cells.enumerated() {
        y -= rowHs[ri] + (ri == 0 ? 0 : lh)
        sheet = img.transformed(by: CGAffineTransform(translationX: x - img.extent.minX, y: y - img.extent.minY)).composited(over: sheet)
        if ci == 0, !cn.isEmpty { sheet = label(cn).transformed(by: CGAffineTransform(translationX: x + 4, y: y + rowHs[ri] + 6)).composited(over: sheet) }
    }
}
try! Look.jpeg(sheet, quality: 0.92)!.write(to: dir.appendingPathComponent("\(name)_sheet.jpg"))
print("sheet: \(dir.appendingPathComponent("\(name)_sheet.jpg").path)")
