// Phase 4 look collection (research/14-phase4-look-collection.md). Renders through the app's own Look.swift + Filters.swift.
//   swiftc -O -o phase4 BetterCam/Look.swift BetterCam/Filters.swift checks/phase4/main.swift
//   ./phase4 scene <outdir> <name> <file> [--max px] [--crop label:x,y,w,h]…
//        Natural Reference · EDITORIAL B (selective, as saved) · per candidate: existing public look · candidate global (viewfinder)
//        · candidate selective (saved photo, portraits). Full-res JPEGs, 2400 px overview, crop sheet, skin-mask overlay, metrics.
//   ./phase4 refstats <image>…
import AppKit
import CoreImage
import Foundation

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.removeFirst()

struct Px { var L: [Double]; var a: [Double]; var b: [Double]; var enc: [Float]; var w: Int; var h: Int }
/// P3-encoded output → CIELAB per pixel (D65).
func labPixels(_ img: CIImage) -> Px {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: p3)
    let M = [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0, 0.0451134, 1.0439444]]
    let wp = [0.95047, 1.0, 1.08883]
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
    var L = [Double](repeating: 0, count: w * h), A = L, B = L
    for i in 0..<(w * h) {
        let c0 = Look.toLinear(Double(max(0, p[i * 4]))), c1 = Look.toLinear(Double(max(0, p[i * 4 + 1]))), c2 = Look.toLinear(Double(max(0, p[i * 4 + 2])))
        let x = (M[0][0] * c0 + M[0][1] * c1 + M[0][2] * c2) / wp[0], y = M[1][0] * c0 + M[1][1] * c1 + M[1][2] * c2
        let z = (M[2][0] * c0 + M[2][1] * c1 + M[2][2] * c2) / wp[2]
        L[i] = 116 * f(y) - 16; A[i] = 500 * (f(x) - f(y)); B[i] = 200 * (f(y) - f(z))
    }
    return Px(L: L, a: A, b: B, enc: p, w: w, h: h)
}
func q(_ s: [Double], _ f: Double) -> Double { s.isEmpty ? .nan : s[min(s.count - 1, Int(f * Double(s.count)))] }
func fit(_ img: CIImage, _ side: CGFloat) -> CIImage {
    img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": side / max(img.extent.width, img.extent.height)])
}
func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }
func hueOf(_ a: Double, _ b: Double) -> Double { (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }

/// Whole-image color statistics: tone distribution, chroma by luminance band, neutral split toning, hue × luma chroma table, skin.
let bands: [(String, ClosedRange<Double>)] = [("sh", 0...30), ("mid", 30...70), ("hi", 70...101)]
let sectors: [(String, Double)] = [("red", 20), ("orange", 55), ("yellow", 90), ("green", 140), ("cyan", 200), ("blue", 270), ("magenta", 330)]
func stats(_ o: Px) -> [String: Any] {
    let n = o.w * o.h, Ls = o.L.sorted()
    var m: [String: Any] = ["Lp1": q(Ls, 0.01), "Lp5": q(Ls, 0.05), "Lp50": q(Ls, 0.5), "Lp95": q(Ls, 0.95), "Lp99_9": q(Ls, 0.999),
                            "crushedPct": 100 * Double(Ls.prefix { $0 < 2 }.count) / Double(n)]
    m["shadowLevels"] = Set(Ls.prefix(n / 10).map { Int(($0 * 2).rounded()) }).count
    m["highlightLevels"] = Set(Ls.suffix(n / 50).map { Int(($0 * 2).rounded()) }).count
    var clipped = 0
    for i in 0..<n {
        let c = [o.enc[i * 4], o.enc[i * 4 + 1], o.enc[i * 4 + 2]]
        if c.max()! - c.min()! > 0.1, c.max()! >= 0.998 || c.min()! <= 0.002 { clipped += 1 }
    }
    m["colorClipPct"] = 100 * Double(clipped) / Double(n)
    var table: [String: [String: Double]] = [:]
    for (bn, br) in bands {
        var cs: [Double] = [], na: [Double] = [], nb: [Double] = []
        var sec = [[Double]](repeating: [], count: sectors.count)
        for i in 0..<n where br.contains(o.L[i]) {
            let c = hypot(o.a[i], o.b[i]); cs.append(c)
            if c < 12 { na.append(o.a[i]); nb.append(o.b[i]) }
            if c > 8 {
                let h = hueOf(o.a[i], o.b[i])
                let k = sectors.indices.min { abs(((sectors[$0].1 - h + 540).truncatingRemainder(dividingBy: 360)) - 180) < abs(((sectors[$1].1 - h + 540).truncatingRemainder(dividingBy: 360)) - 180) }!
                sec[k].append(c)
            }
        }
        m["C_\(bn)"] = mean(cs); m["neutral_a_\(bn)"] = mean(na); m["neutral_b_\(bn)"] = mean(nb)
        var row: [String: Double] = [:]
        for (k, s) in sectors.enumerated() where sec[k].count > n / 500 { row[s.0] = mean(sec[k]) }
        table[bn] = row
    }
    m["hueChromaByLuma"] = table
    var sc: [Double] = [], sa: [Double] = [], sb: [Double] = []
    for i in 0..<n {
        let c = hypot(o.a[i], o.b[i]), h = hueOf(o.a[i], o.b[i])
        if (30...75).contains(h), (12...45).contains(c), (35...85).contains(o.L[i]) { sc.append(c); sa.append(o.a[i]); sb.append(o.b[i]) }
    }
    m["skinlikePct"] = 100 * Double(sc.count) / Double(n); m["skinlikeC"] = mean(sc); m["skinlikeH"] = hueOf(mean(sa), mean(sb))
    return m
}
func fmtStats(_ name: String, _ m: [String: Any]) -> String {
    func d(_ k: String) -> Double { (m[k] as? Double) ?? .nan }
    return String(format: "%-28@ L p5 %5.1f p50 %5.1f p95 %5.1f  crush %5.2f%% shLv %3d hiLv %3d clip %5.2f%% | C sh %4.1f mid %4.1f hi %4.1f | neutral ab sh %+4.1f,%+4.1f hi %+4.1f,%+4.1f | skinlike %4.1f%% C %4.1f h %4.1f",
                  name as NSString, d("Lp5"), d("Lp50"), d("Lp95"), d("crushedPct"), m["shadowLevels"] as! Int, m["highlightLevels"] as! Int,
                  d("colorClipPct"), d("C_sh"), d("C_mid"), d("C_hi"), d("neutral_a_sh"), d("neutral_b_sh"), d("neutral_a_hi"), d("neutral_b_hi"),
                  d("skinlikePct"), d("skinlikeC"), d("skinlikeH"))
}

/// JSON can't hold NaN (empty regions): write null instead.
func clean(_ x: Any) -> Any {
    if let d = x as? Double { return d.isFinite ? d : NSNull() }
    if let a = x as? [Any] { return a.map(clean) }
    if let m = x as? [String: Any] { return m.mapValues(clean) }
    return x
}

// MARK: - refstats

if cmd == "refstats" {
    var all: [[String: Any]] = []
    for path in args {
        let img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true])!
        let m = stats(labPixels(fit(img, 600)))
        all.append(m)
        print(fmtStats(URL(fileURLWithPath: path).lastPathComponent, m))
    }
    var med: [String: Any] = [:]
    for k in all[0].keys where all[0][k] is Double {
        med[k] = all.compactMap { $0[k] as? Double }.filter { !$0.isNaN }.sorted()[all.count / 2]
    }
    for k in ["shadowLevels", "highlightLevels"] { med[k] = all.map { $0[k] as! Int }.sorted()[all.count / 2] }
    print(fmtStats("MEDIAN of \(all.count)", med))
    var t: [String: [Double]] = [:]
    for m in all { for (bn, row) in m["hueChromaByLuma"] as! [String: [String: Double]] { for (s, v) in row { t["\(bn) \(s)", default: []].append(v) } } }
    for (bn, _) in bands {
        print("  hue×luma C (median over refs) \(bn): " + sectors.map { s in
            let v = (t["\(bn) \(s.0)"] ?? []).sorted(); return v.isEmpty ? "\(s.0) -" : String(format: "%@ %.1f(n%d)", s.0, v[v.count / 2], v.count)
        }.joined(separator: "  "))
    }
    exit(0)
}

// MARK: - scene

guard cmd == "scene" else { print("unknown command"); exit(2) }
let root = URL(fileURLWithPath: args.removeFirst()), name = args.removeFirst(), url = URL(fileURLWithPath: args.removeFirst())
var crops: [(String, CGRect)] = [], maxSide: CGFloat? = nil
while let f = args.first {
    args.removeFirst()
    if f == "--max" { maxSide = CGFloat(Double(args.removeFirst())!); continue }
    let parts = args.removeFirst().split(separator: ":"), v = parts[1].split(separator: ",").map { Double($0)! }
    crops.append((String(parts[0]), CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
}
let dir = root.appendingPathComponent(name)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var t0 = Date()
let base = Look.materialize(Look.decode(url, maxSide: maxSide)!)!
let tDecode = Date().timeIntervalSince(t0); t0 = Date()
let analysis = Look.analyze(base, subject: true)
let tAnalyze = Date().timeIntervalSince(t0)
let start = Look.startingExposure(url, captured: true)
func globalOnly(_ g: Grade) -> Grade { var g = g; g.faceLift = 0; g.backgroundTone = 0; g.skinChromaLocal = 1; return g }

let cands = Filter.phase4
let old: [String: Filter] = ["rivieraP4": .riviera, "sunStudyP4": .sunStudy, "alpineP4": .alpine, "afterHoursP4": .afterHours]
let guideImg = base.applyingFilter("CILinearToSRGBToneCurve")
let plan = Look.selectivePlan(cands[0].grade, analysis, guide: guideImg)
var variants: [(String, Grade)] = [("Natural Reference", Filter.naturalReference.grade), ("EDITORIAL B", Filter.editorial.grade)]
var pairs: [(String, Int, Int)] = [] // candidate, global index, selective index (preview → final)
for c in cands {
    variants.append(("old \(old[c.id]!.name)", old[c.id]!.grade))
    variants.append(("\(c.name) global", globalOnly(c.grade)))
    if plan != nil { variants.append(("\(c.name) selective", c.grade)); pairs.append((c.name, variants.count - 2, variants.count - 1)) }
}
if plan != nil { variants.append(("EDITORIAL B global", globalOnly(Filter.editorial.grade))); pairs.append(("EDITORIAL B", variants.count - 1, 1)) }

struct Rendered { let name: String; let grade: Grade; let img: CIImage; let fitImg: CIImage; let seconds: Double }
var rendered: [Rendered] = []
for (vn, g0) in variants {
    var g = g0; g.exposure += start
    t0 = Date()
    let img = Look.materialize(Look.apply(g, to: base, analysis: analysis))!
    let secs = Date().timeIntervalSince(t0)
    let file = vn.replacingOccurrences(of: " ", with: "_")
    try! Look.jpeg(img, quality: 0.92)!.write(to: dir.appendingPathComponent("\(name)_\(file).jpg"))
    rendered.append(Rendered(name: vn, grade: g, img: img, fitImg: Look.materialize(fit(img, 1600))!, seconds: secs))
    print(String(format: "rendered %@ (%.2f s)", vn, secs))
}

// MARK: metrics (1600 px, equal display size)
func region(_ o: Px, _ r: CGRect) -> [Int] {
    let x0 = Int(r.minX * Double(o.w)), x1 = Int(r.maxX * Double(o.w)), y0 = Int(r.minY * Double(o.h)), y1 = Int(r.maxY * Double(o.h))
    return (max(1, y0)..<min(o.h - 1, y1)).flatMap { y in (max(1, x0)..<min(o.w - 1, x1)).map { y * o.w + $0 } }
}
func texture(_ o: Px, _ idx: [Int]) -> Double {
    mean(idx.map { i in var s = 0.0; for dy in -1...1 { for dx in -1...1 { s += o.L[i + dy * o.w + dx] } }; return abs(o.L[i] - s / 9) })
}
var metrics: [String: Any] = ["source": url.lastPathComponent, "startingExposure": start, "decodeSeconds": tDecode, "analyzeSeconds": tAnalyze,
                              "lightMood": Look.lightMood(analysis),
                              "illuminant": ["T": analysis.illuminant.T, "G": analysis.illuminant.G, "confidence": analysis.illuminant.confidence],
                              "faces": analysis.faces.count, "maskTrusted": analysis.maskTrusted, "subjectGap": analysis.subjectGap, "faceGap": analysis.faceGap]
var preLines: [String] = []
for c in cands + [Filter.editorial] {
    if let p = Look.selectivePlan(c.grade, analysis, guide: guideImg) {
        metrics["selective_\(c.id)"] = ["liftEV": p.lift, "backgroundEV": p.background, "skinRegion": p.skin != nil]
        preLines.append(String(format: "selective %@: face lift %+.2f EV, background %+.2f EV, skin region %@", c.name as NSString, p.lift, -p.background, p.skin != nil ? "yes" : "no (face ellipse)"))
    }
}
let ev = analysis.sceneEV, night = Filter.afterHoursP4.grade.night!
preLines.append(String(format: "scene EV %@ → After Hours night share %.2f", ev.map { String(format: "%.1f", $0) } ?? "n/a", ev.map { ((1 - Grade.smooth(night.darkEV, night.lightEV, $0)) * 4).rounded() / 4 } ?? 0))
var lines = [String(format: "%@  light: %@ (T %.2f G %.2f conf %.2f)  faces %d  mask trusted %@  subjectGap %.2f  faceGap %.2f  decode %.2fs analyze %.2fs",
                    url.lastPathComponent as NSString, Look.lightMood(analysis) as NSString, analysis.illuminant.T, analysis.illuminant.G,
                    analysis.illuminant.confidence, analysis.faces.count, analysis.maskTrusted ? "yes" : "no", analysis.subjectGap, analysis.faceGap, tDecode, tAnalyze)]
lines += preLines
let px = rendered.map { labPixels($0.fitImg) }
var refCrop: [String: (L: Double, C: Double, h: Double)] = [:]
for (ri, r) in rendered.enumerated() {
    let o = px[ri]
    var m = stats(o)
    m["renderSeconds"] = r.seconds
    // visible change vs Reference: mean ΔE76 and share of pixels moved ≥ 5 ΔE (diagnostic, not a target)
    let o0 = px[0]
    var de: [Double] = []
    for i in 0..<(o.w * o.h) { de.append(sqrt(pow(o.L[i] - o0.L[i], 2) + pow(o.a[i] - o0.a[i], 2) + pow(o.b[i] - o0.b[i], 2))) }
    m["meanDE_vsNR"] = mean(de); m["pctDE5_vsNR"] = 100 * Double(de.filter { $0 >= 5 }.count) / Double(de.count)
    lines.append(fmtStats(r.name, m) + String(format: " | ΔE vs NR %.1f (%.0f%% ≥5) | %.2fs", m["meanDE_vsNR"] as! Double, m["pctDE5_vsNR"] as! Double, r.seconds))
    var cm: [String: Any] = [:]
    for (cn, cr) in crops {
        let idx = region(o, cr)
        let Lm = idx.map { o.L[$0] }.sorted(), am = mean(idx.map { o.a[$0] }), bm = mean(idx.map { o.b[$0] })
        let st = (L: q(Lm, 0.5), C: hypot(am, bm), h: hueOf(am, bm))
        if ri == 0 { refCrop[cn] = st }
        let ref = refCrop[cn]!, dh = ((st.h - ref.h + 540).truncatingRemainder(dividingBy: 360)) - 180
        cm[cn] = ["L": st.L, "C": st.C, "h": st.h, "Lp5": q(Lm, 0.05), "texture": texture(o, idx), "dL": st.L - ref.L, "dC": st.C - ref.C, "dh": dh]
        lines.append(String(format: "    %-14@ L %5.1f (p5 %5.1f)  C %5.1f  h %5.1f   Δ vs NR: L %+5.1f C %+5.1f h %+6.1f   texture %.2f",
                            cn as NSString, st.L, q(Lm, 0.05), st.C, st.h, st.L - ref.L, st.C - ref.C, dh, texture(o, idx)))
    }
    m["crops"] = cm
    metrics[r.name] = m
}
// preview (global-only, what the viewfinder shows) vs final (selective), inside the person and overall
if let plan {
    let mask = labPixels(fit(plan.person, 1600).cropped(to: rendered[0].fitImg.extent))
    for (k, (cn, gi, si)) in pairs.enumerated() {
        var inP: [Double] = [], all: [Double] = []
        let a = px[gi], b = px[si]
        for i in 0..<min(a.L.count, mask.L.count) {
            let d = sqrt(pow(a.L[i] - b.L[i], 2) + pow(a.a[i] - b.a[i], 2) + pow(a.b[i] - b.b[i], 2))
            all.append(d); if mask.L[i] > 50 { inP.append(d) }
        }
        let s = String(format: "preview→final %@: mean ΔE %.2f overall, %.2f inside person, p95 %.1f", cn as NSString, mean(all), mean(inP), q(inP.sorted(), 0.95))
        lines.append(s); metrics["previewToFinal_\(k)"] = ["look": cn, "overall": mean(all), "person": mean(inP)]
    }
}

// MARK: tone and highlight curves: synthetic ramps through each grade (scene stops −8…+5 around grey)
let rampStops = stride(from: -8.0, through: 5.0, by: 0.25).map { $0 }
func ramp(_ rgb: (Double, Double, Double)) -> CIImage {
    var p = [Float]()
    for s in rampStops { let v = 0.18 * pow(2, s); p += [Float(rgb.0 * v), Float(rgb.1 * v), Float(rgb.2 * v), 1] }
    let d = p.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(bitmapData: d, bytesPerRow: rampStops.count * 16, size: CGSize(width: rampStops.count, height: 1), format: .RGBAf,
                   colorSpace: Look.context.workingColorSpace).settingProperties([Look.clipKey: analysis.clip])
}
var curves: [String: Any] = [:]
let flat = Look.Analysis(wb: (1, 1, 1), clip: analysis.clip)
let curveSet = rendered.filter { $0.name == "Natural Reference" || $0.name == "EDITORIAL B" || $0.name.hasSuffix("P4 global") }
for r in curveSet {
    var g = r.grade; g.grain = 0; g.bloom = 0
    let grey = labPixels(Look.apply(g, to: ramp((1, 1, 1)), analysis: flat)), red = labPixels(Look.apply(g, to: ramp((1, 0.12, 0.08)), analysis: flat))
    let skin = labPixels(Look.apply(g, to: ramp((0.62, 0.42, 0.33)), analysis: flat))
    curves[r.name] = ["stops": rampStops, "greyL": grey.L, "redL": red.L, "redC": zip(red.a, red.b).map { hypot($0, $1) },
                      "skinC": zip(skin.a, skin.b).map { hypot($0, $1) }, "skinH": zip(skin.a, skin.b).map { hueOf($0, $1) }]
}
metrics["curves"] = curves
try! JSONSerialization.data(withJSONObject: clean(metrics), options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("metrics.json"))
try! lines.joined(separator: "\n").write(to: dir.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
print(lines.joined(separator: "\n"))

// curve plot (CoreGraphics): grey L*, saturated red L* and C*, skin C* vs scene stops
func plotCurves() {
    let W = 1200, H = 500
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let colors: [CGColor] = [CGColor(gray: 0.85, alpha: 1), CGColor(gray: 0.5, alpha: 1), CGColor(red: 0.3, green: 0.75, blue: 0.85, alpha: 1),
                             CGColor(red: 0.95, green: 0.65, blue: 0.2, alpha: 1), CGColor(red: 0.45, green: 0.55, blue: 1.0, alpha: 1), CGColor(red: 0.9, green: 0.25, blue: 0.35, alpha: 1)]
    let panels: [(String, Double)] = [("greyL", 100), ("redC", 100), ("skinC", 50)]
    let pw = W / 3
    for (pi, (key, ymax)) in panels.enumerated() {
        let x0 = Double(pi * pw + 30), w = Double(pw - 45), y0 = 30.0, h = Double(H - 70)
        ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.stroke(CGRect(x: x0, y: y0, width: w, height: h))
        let label = NSAttributedString(string: "\(key) vs scene stops (−8…+5)", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14)])
        let line = CTLineCreateWithAttributedString(label); ctx.textPosition = CGPoint(x: x0, y: Double(H) - 25); CTLineDraw(line, ctx)
        for (ci, r) in curveSet.enumerated() {
            let ys = (curves[r.name] as! [String: Any])[key] as! [Double]
            ctx.setStrokeColor(colors[ci]); ctx.setLineWidth(2)
            for (i, v) in ys.enumerated() {
                let p = CGPoint(x: x0 + w * Double(i) / Double(ys.count - 1), y: y0 + h * min(v, ymax) / ymax)
                i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
            }
            ctx.strokePath()
            if pi == 0 {
                let l = NSAttributedString(string: r.name, attributes: [.foregroundColor: NSColor(cgColor: colors[ci])!, .font: NSFont.systemFont(ofSize: 13)])
                ctx.textPosition = CGPoint(x: x0 + 8, y: y0 + h - 20 - Double(ci) * 17); CTLineDraw(CTLineCreateWithAttributedString(l), ctx)
            }
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name)_curves.png"))
}
plotCurves()

// MARK: sheets
func label(_ s: String, _ size: Double = 20) -> CIImage {
    CIFilter(name: "CITextImageGenerator", parameters: ["inputText": s, "inputFontSize": size, "inputScaleFactor": 1])!
        .outputImage!.applyingFilter("CIColorInvert")
}
let bg = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06))
// overview: 3 columns × N rows, 2400 px wide, every image at the same display size
let cols = 4, cell: CGFloat = 591, gap: CGFloat = 12, lh: CGFloat = 34
let ar = rendered[0].fitImg.extent.height / rendered[0].fitImg.extent.width
let cellH = cell * ar, rowsN = (rendered.count + cols - 1) / cols
let ovH = CGFloat(rowsN) * (cellH + lh)
var ov = bg.cropped(to: CGRect(x: 0, y: 0, width: 2400, height: ovH))
for (i, r) in rendered.enumerated() {
    let x = CGFloat(i % cols) * (cell + gap), y = ovH - CGFloat(i / cols + 1) * (cellH + lh)
    let s = cell / r.fitImg.extent.width
    ov = r.fitImg.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: x, y: y))).composited(over: ov)
    ov = label(r.name, 24).transformed(by: CGAffineTransform(translationX: x + 4, y: y + cellH + 4)).composited(over: ov)
}
try! Look.jpeg(ov, quality: 0.92)!.write(to: dir.appendingPathComponent("\(name)_overview_2400.jpg"))

// crops: one column per variant, same source pixels
if !crops.isEmpty {
    let finals = rendered.filter { r in r.name == "Natural Reference" || r.name == "EDITORIAL B" || (r.name.contains("P4") && (plan == nil ? r.name.hasSuffix("global") : r.name.hasSuffix("selective"))) }
    let cw: CGFloat = 420, cropH = cw * 0.8
    let sheetH = CGFloat(crops.count) * (cropH + lh) + lh
    var sheet = bg.cropped(to: CGRect(x: 0, y: 0, width: CGFloat(finals.count) * (cw + 8), height: sheetH))
    for (ci, r) in finals.enumerated() {
        let x = CGFloat(ci) * (cw + 8)
        var y = sheetH - lh
        sheet = label(r.name, 18).transformed(by: CGAffineTransform(translationX: x + 4, y: y + 6)).composited(over: sheet)
        for (cn, cr) in crops {
            let e = r.img.extent
            let box = CGRect(x: e.minX + cr.minX * e.width, y: e.maxY - cr.maxY * e.height, width: cr.width * e.width, height: cr.height * e.height)
            let s = min(cw / box.width, cropH / box.height)
            y -= cropH + lh
            let img = r.img.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s])
            sheet = img.transformed(by: CGAffineTransform(translationX: x - img.extent.minX, y: y - img.extent.minY)).composited(over: sheet)
            if ci == 0 { sheet = label("\(cn) (\(String(format: "%.0f", s * 100))%)", 18).transformed(by: CGAffineTransform(translationX: x + 4, y: y + cropH + 6)).composited(over: sheet) }
        }
    }
    try! Look.jpeg(sheet, quality: 0.92)!.write(to: dir.appendingPathComponent("\(name)_crops.jpg"))
}

// masks: refined person mask (red) and face lift mask (yellow) over the Reference; plus the raw person mask
if let plan {
    let e = rendered[0].img.extent
    let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: e)
    var over = red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: rendered[0].img,
        kCIInputMaskImageKey: plan.person.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.45, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.45, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.45, y: 0, z: 0, w: 0)])])
    if let sk = plan.skin {
        let grn = CIImage(color: CIColor(red: 0.1, green: 1, blue: 0.3)).cropped(to: e)
        over = grn.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: over,
            kCIInputMaskImageKey: sk.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.6, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.6, y: 0, z: 0, w: 0)])])
        try! Look.jpeg(Look.materialize(sk.cropped(to: e).composited(over: CIImage(color: .black).cropped(to: e)))!, quality: 0.9)!.write(to: dir.appendingPathComponent("\(name)_mask_skin_fullres.jpg"))
    }
    if let f = plan.face {
        let yel = CIImage(color: CIColor(red: 1, green: 0.9, blue: 0)).cropped(to: e)
        over = yel.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: over,
            kCIInputMaskImageKey: f.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.5, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.5, y: 0, z: 0, w: 0)])])
    }
    try! Look.jpeg(fit(over.cropped(to: e), 2400), quality: 0.9)!.write(to: dir.appendingPathComponent("\(name)_mask_overlay.jpg"))
    try! Look.jpeg(Look.materialize(plan.person.cropped(to: e).composited(over: CIImage(color: .black).cropped(to: e)))!, quality: 0.9)!.write(to: dir.appendingPathComponent("\(name)_mask_person_fullres.jpg"))
}
try! lines.joined(separator: "\n").write(to: dir.appendingPathComponent("metrics.txt"), atomically: true, encoding: .utf8)
print("done: \(dir.path)")
