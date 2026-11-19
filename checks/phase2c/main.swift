// Phase 2 final review diagnostics (research/11c-phase2-final-review.md). Read-only: changes nothing in the app.
//   swiftc -O -o phase2c BetterCam/Look.swift BetterCam/Filters.swift checks/phase2c/main.swift
//   ./phase2c exposure <proraw.dng>...                  gain-table exposure: region / luminance / resolution sensitivity
//   ./phase2c pairs <a12.dng> <b48.dng> [...]           register each 12/48 MP pair, compare the same surfaces
//   ./phase2c ceiling <proraw.dng>...                   neutral ceiling: where it comes from, what exceeds it
//   ./phase2c gamut <outdir> <name> <file.dng> [--rect label:x,y,w,h]...   out-of-sRGB origin + 3 renders
//      rect = top-left fractions of the upright image. Variants: V0 production (clamp at 0 in linear sRGB),
//      V1 soft gamut compression in linear sRGB before the look, V2 the same look run on linear Display P3 numbers.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.removeFirst()

func floats(_ img: CIImage, _ cs: CGColorSpace) -> (p: [Float], w: Int, h: Int) {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: cs)
    return (p, w, h)
}
func q(_ s: [Double], _ f: Double) -> Double { s.isEmpty ? .nan : s[min(s.count - 1, Int(f * Double(s.count)))] }
func median(_ v: [Double]) -> Double { q(v.sorted(), 0.5) }
func f2(_ x: Double) -> String { String(format: "%+.2f", x) }
func matrix(_ img: CIImage, _ m: [[Double]]) -> CIImage {
    img.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
        "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
        "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
    ]).settingProperties(img.properties)
}

/// Production ProRAW decode settings (Look.decode / Look.proRAWExposure), at a chosen size.
func rawFilter(_ url: URL, side: CGFloat?, apple: Bool) -> CIRAWFilter {
    let r = CIRAWFilter(imageURL: url)!
    if let side { r.scaleFactor = Float(min(1, side / max(r.nativeSize.width, r.nativeSize.height))) }
    r.boostAmount = 0; r.boostShadowAmount = 0; r.shadowBias = 0; r.isGamutMappingEnabled = false
    r.extendedDynamicRangeAmount = 2
    r.localToneMapAmount = apple ? 1 : 0
    if !apple { r.baselineExposure = 0 }
    return r
}

// MARK: - 1. Exposure from the gain table

if cmd == "exposure" {
    for path in args {
        let url = URL(fileURLWithPath: path)
        let be = Double(CIRAWFilter(imageURL: url)!.baselineExposure)
        func study(_ side: CGFloat) -> (lr: [Double], lv: [Double], x: [Double], y: [Double]) {
            let a = floats(rawFilter(url, side: side, apple: true).outputImage!, lin)
            let l = floats(rawFilter(url, side: side, apple: false).outputImage!, lin)
            var lr: [Double] = [], lv: [Double] = [], xs: [Double] = [], ys: [Double] = []
            for i in 0..<(l.w * l.h) {
                let x = Double(a.p[i * 4 + 1]), y = Double(l.p[i * 4 + 1])
                guard y > 0.002, x > 0 else { continue } // production's filter
                lr.append(log2(x / y)); lv.append(y)
                xs.append((Double(i % l.w) + 0.5) / Double(l.w)); ys.append((Double(i / l.w) + 0.5) / Double(l.h)) // y: bottom-up
            }
            return (lr, lv, xs, ys)
        }
        let s = study(256), big = study(1024)
        func est(_ keep: (Int) -> Bool) -> Double { median(s.lr.indices.filter(keep).map { s.lr[$0] }) - be }
        let prod = est { _ in true }
        let lvSorted = s.lv.sorted(), p25 = q(lvSorted, 0.25), p75 = q(lvSorted, 0.75), p90 = q(lvSorted, 0.9)
        let regions: [(String, Double)] = [
            ("center50%", est { abs(s.x[$0] - 0.5) < 0.25 && abs(s.y[$0] - 0.5) < 0.25 }),
            ("top half", est { s.y[$0] > 0.5 }), ("bottom half", est { s.y[$0] <= 0.5 }),
            ("left half", est { s.x[$0] < 0.5 }), ("right half", est { s.x[$0] >= 0.5 }),
            ("mid-tones p25–p75", est { (p25...p75).contains(s.lv[$0]) }),
            ("shadows <p25", est { s.lv[$0] < p25 }), ("highlights >p90", est { s.lv[$0] > p90 }),
        ]
        let mean = s.lr.reduce(0, +) / Double(s.lr.count) - be
        let lrs = s.lr.sorted()
        print("\(url.lastPathComponent)  BE \(f2(be))  production correction \(f2(prod))  (Look.proRAWExposure \(f2(Look.proRAWExposure(url))))")
        print("  same estimator at 1024 px: \(f2(median(big.lr) - be))   log-mean: \(f2(mean))   pixel gain p10/p25/p75/p90 rel. BE: \(f2(q(lrs, 0.1) - be)) \(f2(q(lrs, 0.25) - be)) \(f2(q(lrs, 0.75) - be)) \(f2(q(lrs, 0.9) - be))")
        print("  regions: " + regions.map { "\($0.0) \(f2($0.1)) (Δ\(f2($0.1 - prod)))" }.joined(separator: " · "))
        // gain vs input level: the table's luminance dependence
        var bins: [Int: [Double]] = [:]
        for i in s.lr.indices { bins[Int(floor(log2(s.lv[i]))), default: []].append(s.lr[i]) }
        print("  gain (stops, rel. BE) by input level log2(linear): " + bins.keys.sorted().filter { bins[$0]!.count >= 20 }
            .map { "\($0):\(f2(median(bins[$0]!) - be))" }.joined(separator: " "))
        // gain vs position (4×4 cells) at matched input level (the p25–p75 band): the table's spatial dependence
        var cells: [Double] = []
        for cy in 0..<4 { for cx in 0..<4 {
            let v = s.lr.indices.filter { Int(s.x[$0] * 4) == cx && Int(s.y[$0] * 4) == cy && (p25...p75).contains(s.lv[$0]) }.map { s.lr[$0] }
            if v.count >= 20 { cells.append(median(v) - be) }
        } }
        print("  spatial (4×4 cells, mid-tone band only): min \(f2(cells.min() ?? .nan)) max \(f2(cells.max() ?? .nan)) spread \(String(format: "%.2f", (cells.max() ?? 0) - (cells.min() ?? 0))) stops")
    }
}

// MARK: - 2. 12/48 MP pairs on the same surfaces

/// Linear decode (BE 0, no table) and an 8-bit display copy for Vision.
func linearAndCG(_ url: URL, side: CGFloat) -> (CIImage, CGImage) {
    let img = rawFilter(url, side: side, apple: false).outputImage!
    let f = floats(img, lin)
    let med = median(stride(from: 1, to: f.p.count, by: 4).map { Double(f.p[$0]) })
    let disp = matrix(img, [[0.18 / med, 0, 0], [0, 0.18 / med, 0], [0, 0, 0.18 / med]])
        .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    return (img, Look.context.createCGImage(disp, from: disp.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
}

func warp(_ img: CIImage, _ m: simd_float3x3) -> CIImage {
    let e = img.extent
    func pt(_ x: CGFloat, _ y: CGFloat) -> CIVector {
        let v = m * simd_float3(Float(x), Float(y), 1); return CIVector(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }
    return img.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": pt(e.minX, e.maxY), "inputTopRight": pt(e.maxX, e.maxY),
        "inputBottomLeft": pt(e.minX, e.minY), "inputBottomRight": pt(e.maxX, e.minY),
    ])
}

if cmd == "pairs" {
    for k in stride(from: 0, to: args.count - 1, by: 2) {
        let u12 = URL(fileURLWithPath: args[k]), u48 = URL(fileURLWithPath: args[k + 1])
        let (r, rcg) = linearAndCG(u12, side: 1024), (m, mcg) = linearAndCG(u48, side: 1024)
        let req = VNHomographicImageRegistrationRequest(targetedCGImage: mcg)
        try! VNImageRequestHandler(cgImage: rcg).perform([req])
        guard let H = (req.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { print("registration failed"); continue }
        let ref = floats(r, lin), h = Float(r.extent.height)
        let flip = simd_float3x3(rows: [simd_float3(1, 0, 0), simd_float3(0, -1, h), simd_float3(0, 0, 1)])
        // Vision's matrix convention isn't documented for this use: try the 4 readings, keep the best-aligned one
        var best: (mad: Double, med: Double, n: Int, d: [Double])?
        for M in [H, H.inverse, flip * H * flip, flip * H.inverse * flip] {
            let mv = floats(warp(m, M).composited(over: CIImage(color: .clear).cropped(to: r.extent)).cropped(to: r.extent), lin)
            guard mv.w == ref.w, mv.h == ref.h else { continue }
            var d: [Double] = []
            for i in 0..<(ref.w * ref.h) where mv.p[i * 4 + 3] > 0.999 {
                let a = Double(ref.p[i * 4 + 1]), b = Double(mv.p[i * 4 + 1])
                guard a > 0.003, b > 0.003, a < 2, b < 2 else { continue } // above noise, below the ceiling
                d.append(log2(a / b))
            }
            guard d.count > 1000 else { continue }
            let md = median(d), mad = median(d.map { abs($0 - md) })
            if best == nil || mad < best!.mad { best = (mad, md, d.count, d) }
        }
        guard let b = best else { print("no valid alignment"); continue }
        let inl = b.d.filter { abs($0 - b.med) < 3 * max(b.mad, 0.05) } // drop the dog / moved person
        let D = median(inl)
        func meta(_ u: URL) -> (be: Double, iso: Double, t: Double) {
            let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil) as! [String: Any]
            let ex = p["{Exif}"] as! [String: Any]
            return (Double(CIRAWFilter(imageURL: u)!.baselineExposure), Double((ex["ISOSpeedRatings"] as! [Int])[0]), ex["ExposureTime"] as! Double)
        }
        let a = meta(u12), c = meta(u48)
        let corr12 = Look.proRAWExposure(u12), corr48 = Look.proRAWExposure(u48)
        let settings = log2(a.iso * a.t / (c.iso * c.t))
        print("\(u12.lastPathComponent) vs \(u48.lastPathComponent): \(b.n) matched px, \(inl.count) inliers, alignment MAD \(String(format: "%.3f", b.mad)) stop")
        print("  stored level, same surfaces (12 ÷ 48, BE 0): \(f2(D)) stops   ISO×t says \(f2(settings)) (12 MP got \(Int(a.iso))×\(String(format: "%.4f", a.t)) vs \(Int(c.iso))×\(String(format: "%.4f", c.t)))")
        print("  rendered 12 ÷ 48 on the same surfaces:  BE only \(f2(D + a.be - c.be))   production (BE + table median) \(f2(D + a.be + corr12 - c.be - corr48))")
        print("  → a metering-faithful render would show \(f2(settings)); a scene-matched one 0")
    }
}

// MARK: - 3. Neutral ceiling

if cmd == "ceiling" {
    let inset = Look.inset
    for path in args {
        let url = URL(fileURLWithPath: path)
        func stats(_ tweak: (CIRAWFilter) -> Void, side: CGFloat) -> String {
            let r = rawFilter(url, side: side, apple: false); tweak(r)
            let f = floats(r.outputImage!, lin)
            var neutralMax: Float = 0, maxC: [Float] = [0, 0, 0], over = 0, overInset = 0, atCeil = 0
            let n = f.w * f.h
            for i in 0..<n {
                let c = [f.p[i * 4], f.p[i * 4 + 1], f.p[i * 4 + 2]]
                neutralMax = max(neutralMax, c.min()!)
                for k in 0..<3 { maxC[k] = max(maxC[k], c[k]) }
                if c.max()! > 2.5 { over += 1 }
                if c.min()! >= 0.99 * 2.5 { atCeil += 1 }
                let ins = (0..<3).map { k in Float(inset[k][0]) * c[0] + Float(inset[k][1]) * c[1] + Float(inset[k][2]) * c[2] }
                if ins.max()! > 2.5 { overInset += 1 }
            }
            func pc(_ x: Int) -> String { String(format: "%.4f%%", 100 * Double(x) / Double(n)) }
            return String(format: "neutral max %.3f · max R/G/B %.2f/%.2f/%.2f", neutralMax, maxC[0], maxC[1], maxC[2])
                + " · all 3 ≥ 0.99×2.5: \(pc(atCeil)) · any channel > 2.5: \(pc(over)) · after AgX inset > 2.5 (clipped per channel by apply): \(pc(overInset))"
        }
        print(url.lastPathComponent)
        print("  production (BE 0, EDR 2):        " + stats({ _ in }, side: 4032))
        print("  in-filter exposure −1:           " + stats({ $0.exposure = -1 }, side: 1024))
        print("  in-filter exposure +1:           " + stats({ $0.exposure = 1 }, side: 1024))
        print("  file BaselineExposure kept:      " + stats({ $0.baselineExposure = CIRAWFilter(imageURL: url)!.baselineExposure }, side: 1024))
        print("  EDR 8:                           " + stats({ $0.extendedDynamicRangeAmount = 8 }, side: 1024))
        print("  gamut mapping on:                " + stats({ $0.isGamutMappingEnabled = true }, side: 1024))
    }
}

// MARK: - 4. Gamut

/// CIE 1931 spectral locus, 380–700 nm (closed by the purple line).
let locus: [(Double, Double)] = [(0.1741, 0.0050), (0.1733, 0.0048), (0.1714, 0.0051), (0.1644, 0.0109), (0.1566, 0.0177), (0.1440, 0.0297),
    (0.1241, 0.0578), (0.1096, 0.0868), (0.0913, 0.1327), (0.0687, 0.2007), (0.0454, 0.2950), (0.0235, 0.4127), (0.0082, 0.5384),
    (0.0039, 0.6548), (0.0139, 0.7502), (0.0389, 0.8120), (0.0743, 0.8338), (0.1142, 0.8262), (0.1547, 0.8059), (0.2296, 0.7543),
    (0.3016, 0.6923), (0.3731, 0.6245), (0.4441, 0.5547), (0.5125, 0.4866), (0.5752, 0.4242), (0.6270, 0.3725), (0.6658, 0.3340),
    (0.6915, 0.3083), (0.7079, 0.2920), (0.7190, 0.2809), (0.7260, 0.2740), (0.7347, 0.2653)]
let tri709 = [(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], triP3 = [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
let tri2020 = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
func inside(_ p: (Double, Double), _ poly: [(Double, Double)]) -> Bool {
    var c = false, j = poly.count - 1
    for i in poly.indices {
        let (xi, yi) = poly[i], (xj, yj) = poly[j]
        if (yi > p.1) != (yj > p.1), p.0 < (xj - xi) * (p.1 - yi) / (yj - yi) + xi { c.toggle() }
        j = i
    }
    return c
}
let srgbToXYZ = [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]
let p3ToXYZ = [[0.4865709, 0.2656677, 0.1982173], [0.2289746, 0.6917385, 0.0792869], [0, 0.0451134, 1.0439444]]
let srgbToP3 = [[0.822462, 0.177538, 0], [0.033194, 0.966806, 0], [0.017083, 0.072397, 0.910520]]
let p3ToSRGB = [[1.224940, -0.224940, 0], [-0.042057, 1.042057, 0], [-0.019638, -0.078636, 1.098274]]
func mul(_ m: [[Double]], _ v: [Double]) -> [Double] { (0..<3).map { r in m[r][0] * v[0] + m[r][1] * v[1] + m[r][2] * v[2] } }
func lab(xyz v: [Double]) -> [Double] {
    let wp = [0.95047, 1.0, 1.08883]
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
    let fx = f(v[0] / wp[0]), fy = f(v[1] / wp[1]), fz = f(v[2] / wp[2])
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
}
func de2000(_ x: [Double], _ y: [Double]) -> Double {
    let r = Double.pi / 180
    let C1 = hypot(x[1], x[2]), C2 = hypot(y[1], y[2]), Cb = (C1 + C2) / 2
    let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
    let a1 = (1 + G) * x[1], a2 = (1 + G) * y[1], C1p = hypot(a1, x[2]), C2p = hypot(a2, y[2])
    func hp(_ b: Double, _ a: Double) -> Double { a == 0 && b == 0 ? 0 : (atan2(b, a) / r + 360).truncatingRemainder(dividingBy: 360) }
    let h1 = hp(x[2], a1), h2 = hp(y[2], a2)
    var dh = 0.0
    if C1p * C2p != 0 { dh = h2 - h1; if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 } }
    let dH = 2 * sqrt(C1p * C2p) * sin(dh / 2 * r), Lb = (x[0] + y[0]) / 2, Cbp = (C1p + C2p) / 2
    var hb = h1 + h2
    if C1p * C2p != 0 { if abs(h1 - h2) > 180 { hb += hb < 360 ? 360 : -360 }; hb /= 2 }
    let T = 1 - 0.17 * cos((hb - 30) * r) + 0.24 * cos(2 * hb * r) + 0.32 * cos((3 * hb + 6) * r) - 0.20 * cos((4 * hb - 63) * r)
    let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7))), dT = 30 * exp(-pow((hb - 275) / 25, 2))
    let Sl = 1 + 0.015 * pow(Lb - 50, 2) / sqrt(20 + pow(Lb - 50, 2)), Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
    let dL = (y[0] - x[0]) / Sl, dC = (C2p - C1p) / Sc, dHs = dH / Sh
    return sqrt(dL * dL + dC * dC + dHs * dHs - sin(2 * dT * r) * Rc * dC * dHs)
}

/// Soft gamut compression (ACES 1.3 reference gamut compression shape), distance from the achromatic axis per channel.
/// In-gamut colors with distance < `t` are untouched; distances up to `limit` are compressed into ≤ 1; beyond that, still clamped.
/// ponytail: fixed threshold/limit for a diagnostic; production would fit `limit` to the camera's gamut, not to these files.
func compress(_ c: [Float], t: Float = 0.8, limit: Float = 1.6, power: Float = 1.2) -> [Float] {
    let ach = c.max()!
    guard ach > 0 else { return c.map { max($0, 0) } }
    let s = (limit - t) / pow(pow((1 - t) / (limit - t), -power) - 1, 1 / power)
    return c.map { v in
        let d = (ach - v) / ach
        guard d > t else { return v }
        let dc = t + (d - t) / pow(1 + pow((d - t) / s, power), 1 / power)
        return ach - dc * ach
    }
}

func writeJPEG(_ img: CIImage, _ url: URL) { try! Look.jpeg(img, quality: 0.92)!.write(to: url) }

if cmd == "gamut" {
    let root = URL(fileURLWithPath: args.removeFirst()), name = args.removeFirst(), url = URL(fileURLWithPath: args.removeFirst())
    var rects: [(String, CGRect)] = []
    while args.first == "--rect" {
        args.removeFirst()
        let parts = args.removeFirst().split(separator: ":"), v = parts[1].split(separator: ",").map { Double($0)! }
        rects.append((String(parts[0]), CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
    }
    let dir = root.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let base = Look.decode(url, maxSide: 1600)!
    let clip = base.properties[Look.clipKey] as! Double
    var grade = Filter.named("naturalReference").grade
    grade.exposure += Look.startingExposure(url, captured: true)
    let an = Look.Analysis(wb: (1, 1, 1), clip: clip) // Natural Reference: autoWB 0, no subject lift → only the clip matters
    let src = floats(base, lin), w = src.w, h = src.h, n = w * h

    // V1: compressed copy of the scene-linear input
    var comp = src.p
    for i in 0..<n {
        let c = compress([src.p[i * 4], src.p[i * 4 + 1], src.p[i * 4 + 2]])
        comp[i * 4] = c[0]; comp[i * 4 + 1] = c[1]; comp[i * 4 + 2] = c[2]
    }
    let compImg = comp.withUnsafeBufferPointer { CIImage(bitmapData: Data(buffer: $0), bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: lin) }
        .settingProperties(base.properties)
    let variants: [(String, CIImage)] = [
        ("V0-production", Look.apply(grade, to: base, analysis: an)),
        ("V1-softcompress-sRGB", Look.apply(grade, to: compImg, analysis: an)),
        ("V2-P3-working", matrix(Look.apply(grade, to: matrix(base, srgbToP3), analysis: an), p3ToSRGB)),
    ]
    var outLab: [[[Double]]] = []
    for (vn, img) in variants {
        writeJPEG(img, dir.appendingPathComponent("\(vn).jpg"))
        let f = floats(img, p3)
        outLab.append((0..<n).map { i in lab(xyz: mul(p3ToXYZ, (0..<3).map { Look.toLinear(Double(f.p[i * 4 + $0])) })) })
    }

    // classify each pixel's scene color
    enum Cls: Int { case inGamut, dark, p3, rec2020, locus, outside }
    var cls = [Cls](repeating: .inGamut, count: n), sceneLab = [[Double]](repeating: [0, 0, 0], count: n)
    var p3neg = 0
    for i in 0..<n {
        let c = (0..<3).map { Double(src.p[i * 4 + $0]) }
        let xyz = mul(srgbToXYZ, c)
        if mul(srgbToP3, c).min()! < 0 { p3neg += 1 }
        guard c.min()! < 0 else { continue }
        let sum = xyz.reduce(0, +)
        if xyz[1] < 0.004 || sum <= 0 { cls[i] = .dark; continue } // ≳ 5.5 stops under the decode's grey: noise floor
        let xy = (xyz[0] / sum, xyz[1] / sum)
        cls[i] = inside(xy, triP3) ? .p3 : inside(xy, tri2020) ? .rec2020 : inside(xy, locus) ? .locus : .outside
    }
    // scene hue reference: the scene color scaled to the V0 output's lightness (hue is what we compare, not tone)
    for i in 0..<n {
        let xyz = mul(srgbToXYZ, (0..<3).map { Double(src.p[i * 4 + $0]) })
        guard xyz[1] > 1e-5 else { continue }
        let L = outLab[0][i][0], fy = (L + 16) / 116, Y = fy > 0.206893 ? fy * fy * fy : (fy - 16 / 116) / 7.787
        sceneLab[i] = lab(xyz: xyz.map { $0 * Y / xyz[1] })
    }
    var counts = [Int](repeating: 0, count: 6)
    for c in cls { counts[c.rawValue] += 1 }
    let neg = n - counts[0]
    func pc(_ x: Int, _ of: Int) -> String { String(format: "%.1f%%", 100 * Double(x) / Double(max(of, 1))) }
    print("\(name) (\(url.lastPathComponent)): \(w)x\(h)  negative in linear sRGB: \(pc(neg, n)) of pixels;  negative in linear P3: \(pc(p3neg, n))")
    print("  of the negative pixels: noise-floor dark \(pc(counts[1], neg)) · inside P3 \(pc(counts[2], neg)) · P3–Rec.2020 \(pc(counts[3], neg)) · Rec.2020–locus \(pc(counts[4], neg)) · outside the spectral locus \(pc(counts[5], neg))")

    // hue sector of the valid (non-dark) out-of-gamut pixels
    var sectors: [String: Int] = [:]
    for i in 0..<n where cls[i].rawValue >= 2 {
        let hh = (atan2(sceneLab[i][2], sceneLab[i][1]) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let s = hh < 25 ? "magenta-red" : hh < 50 ? "red" : hh < 80 ? "orange/skin" : hh < 105 ? "yellow" : hh < 170 ? "green" : hh < 230 ? "cyan" : hh < 300 ? "blue" : "violet/magenta"
        sectors[s, default: 0] += 1
    }
    print("  valid out-of-gamut by scene hue: " + sectors.sorted { $0.value > $1.value }.map { "\($0.key) \(pc($0.value, neg - counts[1]))" }.joined(separator: " · "))

    // region masks: rects, faces (Vision on V0), lights (top 1% scene luminance), all valid out-of-gamut, in-gamut
    var regions: [(String, [Int])] = []
    func rectIdx(_ r: CGRect) -> [Int] { // r: top-left fractions; pixel rows are top-down in the rendered bitmap
        let x0 = Int(r.minX * Double(w)), x1 = Int(r.maxX * Double(w)), y0 = Int(r.minY * Double(h)), y1 = Int(r.maxY * Double(h))
        return (max(0, y0)..<min(h, y1)).flatMap { y in (max(0, x0)..<min(w, x1)).map { y * w + $0 } }
    }
    let cg = Look.context.createCGImage(variants[0].1, from: variants[0].1.extent, format: .RGBA8, colorSpace: p3)!
    let faces = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: cg).perform([faces])
    for (k, f) in (faces.results ?? []).enumerated() { // Vision: normalized, bottom-left origin. Inner 50% of the box = skin
        let b = f.boundingBox
        regions.append(("face\(k) skin", rectIdx(CGRect(x: b.midX - b.width / 4, y: 1 - b.midY - b.height / 4, width: b.width / 2, height: b.height / 2))))
    }
    for (l, r) in rects { regions.append((l, rectIdx(r))) }
    let ys = (0..<n).map { i in mul(srgbToXYZ, (0..<3).map { Double(src.p[i * 4 + $0]) })[1] }
    let yCut = q(ys.sorted(), 0.99)
    regions.append(("lights (top 1% luminance)", (0..<n).filter { ys[$0] >= yCut }))
    regions.append(("all valid out-of-gamut", (0..<n).filter { cls[$0].rawValue >= 2 }))
    regions.append(("in-gamut (cost check)", (0..<n).filter { cls[$0] == .inGamut }))

    print("  region                       px     oog%   |  ΔE00 vs V0 (mean/p95)   V1        V2      |  C*  V0 / V1 / V2      |  |hue err| vs scene, oog px only V0 / V1 / V2")
    for (rn, idx) in regions where !idx.isEmpty {
        let oog = idx.filter { cls[$0].rawValue >= 2 }
        func deStats(_ v: Int) -> String {
            let d = idx.map { de2000(outLab[0][$0], outLab[v][$0]) }.sorted()
            return String(format: "%.2f/%.2f", d.reduce(0, +) / Double(d.count), q(d, 0.95))
        }
        func meanC(_ v: Int) -> Double { idx.map { hypot(outLab[v][$0][1], outLab[v][$0][2]) }.reduce(0, +) / Double(idx.count) }
        func hueErr(_ v: Int) -> String {
            let e = oog.filter { hypot(sceneLab[$0][1], sceneLab[$0][2]) > 10 && hypot(outLab[v][$0][1], outLab[v][$0][2]) > 2 }.map { i -> Double in
                let a = atan2(sceneLab[i][2], sceneLab[i][1]), b = atan2(outLab[v][i][2], outLab[v][i][1])
                return abs((((b - a) * 180 / .pi) + 540).truncatingRemainder(dividingBy: 360) - 180)
            }
            return e.count < 20 ? "  –  " : String(format: "%4.1f°", median(e))
        }
        print(String(format: "  %-26@ %7d  %5.1f%%  |  %@   %@ | %5.1f / %5.1f / %5.1f  |  %@ / %@ / %@", rn as NSString, idx.count,
                     100 * Double(oog.count) / Double(idx.count), deStats(1), deStats(2), meanC(0), meanC(1), meanC(2), hueErr(0), hueErr(1), hueErr(2)))
    }

    // out-of-gamut map: grey image, colored by class
    var map = [UInt8](repeating: 255, count: n * 4)
    let colors: [Cls: (UInt8, UInt8, UInt8)] = [.dark: (40, 60, 255), .p3: (255, 230, 0), .rec2020: (255, 140, 0), .locus: (255, 0, 0), .outside: (255, 0, 255)]
    for i in 0..<n {
        let c = colors[cls[i]] ?? { let g = UInt8(min(255, 60 + outLab[0][i][0] * 1.2)); return (g, g, g) }()
        map[i * 4] = c.0; map[i * 4 + 1] = c.1; map[i * 4 + 2] = c.2
    }
    let mapImg = CIImage(bitmapData: Data(map), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    writeJPEG(mapImg, dir.appendingPathComponent("oog-map.jpg"))

    // crop sheet: rows = densest valid-oog cell + each rect + faces; columns = V0 · V1 · V2 · map
    var cell = (n: 0, x: 0.5, y: 0.5)
    for cy in 0..<8 { for cx in 0..<8 {
        let k = rectIdx(CGRect(x: Double(cx) / 8, y: Double(cy) / 8, width: 0.125, height: 0.125)).filter { cls[$0].rawValue >= 2 }.count
        if k > cell.n { cell = (k, (Double(cx) + 0.5) / 8, (Double(cy) + 0.5) / 8) }
    } }
    var rows: [(String, CGRect)] = [("densest out-of-gamut", CGRect(x: cell.x - 0.12, y: cell.y - 0.09, width: 0.24, height: 0.18))] + rects
    for (k, f) in (faces.results ?? []).enumerated() {
        let b = f.boundingBox; rows.append(("face\(k)", CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
    }
    let cw: CGFloat = 400, chh: CGFloat = 300
    let images = variants.map(\.1) + [mapImg]
    var sheet = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: CGRect(x: 0, y: 0, width: 4 * (cw + 6), height: CGFloat(rows.count) * (chh + 6)))
    for (ri, (_, r)) in rows.enumerated() {
        for (ci, img) in images.enumerated() {
            let e = img.extent
            let box = CGRect(x: e.minX + r.minX * e.width, y: e.maxY - r.maxY * e.height, width: r.width * e.width, height: r.height * e.height).intersection(e)
            let s = min(cw / box.width, chh / box.height)
            let c = img.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s])
            sheet = c.transformed(by: CGAffineTransform(translationX: CGFloat(ci) * (cw + 6), y: CGFloat(rows.count - 1 - ri) * (chh + 6))).composited(over: sheet)
        }
    }
    writeJPEG(sheet, dir.appendingPathComponent("sheet.jpg"))
    print("  sheet rows: " + rows.map(\.0).joined(separator: " · ") + "   (columns V0 · V1 · V2 · map: yellow P3, orange Rec.2020, red locus, magenta outside locus, blue dark)")
}
