// Phase 1 before/after renders + measurements from the same source files (research/10-phase1-pipeline.md).
//   swiftc -O -o compare BetterCam/Look.swift BetterCam/Filters.swift checks/compare/main.swift
//   ./compare <outdir> <file.dng|.heic|.jpg>...   → <outdir>/full/<name>_<variant>.jpg + <outdir>/metrics.json
// Variants (DNG): A production (legacy decode + legacy curve, Editorial) · B corrected decode + legacy curve ·
// C corrected decode + calibrated curve · D corrected decode + Natural Reference. Also Sun Study / Alpine as A and C.
// Display-referred inputs (Apple HEIC/JPEG) can't test the decoder: they get the look stage only (A≡B there).
import CoreImage
import Foundation

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let full = out.appendingPathComponent("full")
try? FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)

func floats(_ img: CIImage) -> [Float] {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: lin)
    return p
}
func pct(_ sorted: [Float], _ q: Double) -> Double { Double(sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]) }

/// Decoder output: brightness distribution, out-of-gamut share, and which clipped pixels the sensor actually clipped.
func decoderStats(_ img: CIImage, clip: Double) -> [String: Any] {
    let p = floats(img)
    var m = [Float](), neg = 0
    m.reserveCapacity(p.count / 4)
    for i in stride(from: 0, to: p.count, by: 4) {
        m.append(max(p[i], p[i + 1], p[i + 2]))
        if min(p[i], p[i + 1], p[i + 2]) < 0 { neg += 1 }
    }
    m.sort()
    let n = Double(m.count), top = m.last!
    // a plateau at the maximum = something clipped it (sensor, or the decoder's SDR ceiling)
    let plateau = Double(m.count - m.firstIndex { $0 >= 0.98 * top }!) / n
    return ["max": Double(top), "p50": pct(m, 0.5), "p99": pct(m, 0.99), "p99_9": pct(m, 0.999),
            "curveWhiteLevel": clip, "atMaxPct": 100 * plateau, "negativePct": 100 * Double(neg) / n]
}

/// Final image as stored (8-bit Display P3): L* histogram, percentiles, crushed/white shares, gamut clipping.
func outputStats(_ img: CIImage) -> [String: Any] {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var b = [UInt8](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &b, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: p3)
    let toLin = (0..<256).map { Look.toLinear(Double($0) / 255) } // P3 uses the sRGB transfer curve
    var hist = [Int](repeating: 0, count: 101), Ls = [Float](), crushed = 0, white = 0, chanClip = 0, colored = 0
    Ls.reserveCapacity(w * h)
    for i in stride(from: 0, to: b.count, by: 4) {
        let r = toLin[Int(b[i])], g = toLin[Int(b[i + 1])], bl = toLin[Int(b[i + 2])]
        let y = 0.2290 * r + 0.6917 * g + 0.0793 * bl
        let L = y > 0.008856 ? 116 * pow(y, 1 / 3.0) - 16 : 903.3 * y
        Ls.append(Float(L)); hist[min(100, Int(L.rounded()))] += 1
        if L < 3 { crushed += 1 }
        if L > 98 { white += 1 }
        let mx = max(b[i], b[i + 1], b[i + 2]), mn = min(b[i], b[i + 1], b[i + 2])
        if Int(mx) - Int(mn) > 25 { colored += 1; if mx == 255 || mn == 0 { chanClip += 1 } }
    }
    Ls.sort()
    let n = Double(Ls.count)
    // distinct 8-bit-ish L* levels used by the darkest 10% / brightest 2%: tonal separation that survived
    func levels(_ s: ArraySlice<Float>) -> Int { Set(s.map { Int(($0 * 2.55).rounded()) }).count }
    return ["Lhist": hist,
            "Lpct": ["p1": pct(Ls, 0.01), "p5": pct(Ls, 0.05), "p25": pct(Ls, 0.25), "p50": pct(Ls, 0.5),
                     "p75": pct(Ls, 0.75), "p95": pct(Ls, 0.95), "p99": pct(Ls, 0.99), "p99_9": pct(Ls, 0.999)],
            "crushedPct": 100 * Double(crushed) / n, "whitePct": 100 * Double(white) / n,
            "shadowLevels": levels(Ls[..<(Ls.count / 10)]), "highlightLevels": levels(Ls[(Ls.count * 98 / 100)...]),
            "gamutClipPctOfColored": colored > 0 ? 100 * Double(chanClip) / Double(colored) : 0]
}

func save(_ img: CIImage, _ name: String) {
    let url = full.appendingPathComponent(name + ".jpg")
    try! Look.jpeg(img, quality: 0.95)!.write(to: url)
}

func render(_ base: CIImage, _ filter: String) -> CIImage {
    Look.apply(Filter.named(filter).grade, to: base, analysis: Look.analyze(base, subject: true))
}

let metricsURL = out.appendingPathComponent("metrics.json") // merged, so files can be added in later runs
var report = (try? Data(contentsOf: metricsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
for path in CommandLine.arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    let isRaw = url.pathExtension.lowercased() == "dng"
    var entry: [String: Any] = ["raw": isRaw]
    print(name)

    func variant(_ v: String, legacyDecode: Bool, legacyCurve: Bool, filter: String, size: CGFloat? = nil) -> CIImage {
        Look.legacyDecode = legacyDecode; Look.legacyCurve = legacyCurve
        defer { Look.legacyDecode = false; Look.legacyCurve = false }
        return render(Look.decode(url, maxSide: size)!, filter)
    }

    if isRaw {
        Look.legacyDecode = true
        let old = Look.decode(url)!
        Look.legacyDecode = false
        let new = Look.decode(url)!
        let newClip = new.properties[Look.clipKey] as! Double
        let cs = decoderStats(new, clip: newClip)
        var d = ["legacy": decoderStats(old, clip: 1.0), "corrected": cs]
        // sensor-clipped = on the corrected decode's top plateau (only if it is one: ≥0.02% of pixels, else nothing clipped)
        let sensorTop = (cs["atMaxPct"] as! Double) >= 0.02 ? 0.98 * (cs["max"] as! Double) : .infinity
        // decoder-induced = at the legacy SDR ceiling (≥0.98) but not sensor-clipped
        let po = floats(old), pn = floats(new)
        var induced = 0, ceiling = 0
        for i in stride(from: 0, to: po.count, by: 4) where max(po[i], po[i + 1], po[i + 2]) >= 0.98 {
            ceiling += 1
            if Double(max(pn[i], pn[i + 1], pn[i + 2])) < sensorTop { induced += 1 }
        }
        let n = Double(po.count / 4)
        d["legacyCeilingPct"] = ["value": 100 * Double(ceiling) / n] as [String: Any]
        d["decoderInducedPct"] = ["value": 100 * Double(induced) / n] as [String: Any]
        d["baselineExposure"] = ["value": Double(CIRAWFilter(imageURL: url)!.baselineExposure)] as [String: Any]
        entry["decoder"] = d
    }
    var outs: [String: Any] = [:]
    let plan: [(String, Bool, Bool, String)] = isRaw
        ? [("A", true, true, "editorial"), ("B", false, true, "editorial"), ("C", false, false, "editorial"), ("D", false, false, "naturalReference"),
           ("A_sunStudy", true, true, "sunStudy"), ("C_sunStudy", false, false, "sunStudy"),
           ("A_alpine", true, true, "alpine"), ("C_alpine", false, false, "alpine")]
        : [("A", false, true, "editorial"), ("C", false, false, "editorial"), ("D", false, false, "naturalReference"),
           ("A_sunStudy", false, true, "sunStudy"), ("C_sunStudy", false, false, "sunStudy"),
           ("A_alpine", false, true, "alpine"), ("C_alpine", false, false, "alpine")]
    for (v, ld, lc, f) in plan {
        let img = variant(v, legacyDecode: ld, legacyCurve: lc, filter: f)
        save(img, "\(name)_\(v)")
        outs[v] = outputStats(img)
        print("  \(v)")
    }
    entry["outputs"] = outs
    report[name] = entry
}
let json = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: metricsURL)
