// Offline diagnostic (research/20): what the looks receive on the still vs in the viewfinder. One file at a time, 1024 px.
//   swiftc -O -o /tmp/baseline BetterCam/{Look,Filters}.swift checks/baseline/main.swift
//   /tmp/baseline <out dir> <look id> <file…>
// A  Apple default ProRAW/RAW development (CIRAWFilter defaults: tone curve, gain table, boost).
// B  A + the look exactly as the viewfinder runs it (display-referred input, clip 1, recipe exposure 0).
// C  BetterCam's photo pipeline (Look.photo + Look.apply), i.e. what the gallery and export show. Built against the
//    pre-research/20 Look.swift it's labeled C-engine2; against the current one D-new, plus D0 (base development, no look).
// Per 1-stop bin of scene light (our decode × the recipe's exposure) it prints median OkLab L and mean chroma of each.
import CoreImage
import Foundation

setbuf(stdout, nil)
var args = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: args.removeFirst())
let look = args.removeFirst()
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let side: CGFloat = 1024

func pixels(_ img: CIImage, _ n: CGFloat = 256) -> (px: [Float], w: Int, h: Int) {
    let e = img.extent
    let s = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": n / max(e.width, e.height)])
    let w = Int(s.extent.width), h = Int(s.extent.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(s, toBitmap: &p, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
    return (p, w, h)
}
func lab(_ p: [Float], _ i: Int) -> (Double, Double, Double) {
    OkLab.from((max(0, Double(p[i])), max(0, Double(p[i + 1])), max(0, Double(p[i + 2]))))
}
/// Local contrast: mean |L − 3×3-box-blurred L| ×1000 (texture/edge energy).
func localContrast(_ p: [Float], _ w: Int, _ h: Int) -> Double {
    var L = [Double](repeating: 0, count: w * h)
    for i in 0..<(w * h) { L[i] = lab(p, 4 * i).0 }
    var acc = 0.0, n = 0.0
    for y in 2..<(h - 2) { for x in 2..<(w - 2) {
        var s = 0.0
        for dy in -2...2 { for dx in -2...2 { s += L[(y + dy) * w + x + dx] } }
        acc += abs(L[y * w + x] - s / 25); n += 1
    }}
    return 1000 * acc / n
}

for path in args {
    autoreleasepool {
        let url = URL(fileURLWithPath: path), name = url.deletingPathExtension().lastPathComponent
        var r = Recipe(filter: look)
        r.baseExposure = Look.startingExposure(url, captured: true)
        guard let (base, a) = Look.photo(url, recipe: r, maxSide: side), let raw = CIRAWFilter(imageURL: url) else { return }
        raw.scaleFactor = Float(min(1, side / max(raw.nativeSize.width, raw.nativeSize.height)))
        guard let appleRaw = raw.outputImage else { return }
        let apple = appleRaw.cropped(to: base.extent).settingProperties([Look.clipKey: 1.0, Look.evKey: Look.sceneEV(url) as Any])
        let vf = Recipe(filter: look) // the viewfinder's recipe: no baseExposure, slider 0
        let B = Look.apply(vf, to: apple, analysis: Look.analyze(apple), source: url)
        let C = Look.apply(r, to: base, analysis: a, source: url)
        let tag = a.raw ? "D-new" : "C-engine2"
        var renders = [("A-apple", apple), ("B-apple+\(look)", B), ("\(tag)+\(look)", C)]
        if CommandLine.arguments.contains("--none") { renders.removeLast() }
        if a.raw { renders.append(("D0-new-base", Look.develop(base, a, exposure: r.baseExposure))) }
        for (label, img) in renders {
            try! Look.jpeg(img, quality: 0.9)!.write(to: out.appending(path: "\(name)__\(label).jpg"))
        }
        // scene axis: our linear decode × the recipe's exposure (before local development)
        let sceneImg = Look.scaled(base, pow(2, r.grade.exposure))
        let (s, w, h) = pixels(sceneImg)
        let stats = renders.map { pixels($0.1) }
        print("\n== \(name)  [\(look)]  white \(String(format: "%.2f", log2(a.clip / 0.18) + r.grade.exposure)) stops  local range \(String(format: "%.1f", a.localRange))  baseExposure \(String(format: "%.2f", r.baseExposure))")
        print("stop bin   share |  " + renders.map { $0.0.padding(toLength: 22, withPad: " ", startingAt: 0) }.joined(separator: " "))
        for bin in -7...4 {
            var idx: [Int] = []
            for i in 0..<(w * h) {
                let y = 0.2126 * Double(s[4 * i]) + 0.7152 * Double(s[4 * i + 1]) + 0.0722 * Double(s[4 * i + 2])
                let st = log2(max(y, 1e-6) / 0.18)
                if st >= Double(bin) - 0.5 && st < Double(bin) + 0.5 { idx.append(4 * i) }
            }
            guard idx.count > w * h / 200 else { continue }
            var line = String(format: "%+3d     %5.1f%% |", bin, 100 * Double(idx.count) / Double(w * h))
            for st in stats {
                let labs = idx.map { lab(st.px, $0) }
                let Ls = labs.map(\.0).sorted()
                let C = labs.map { hypot($0.1, $0.2) }.reduce(0, +) / Double(labs.count)
                line += String(format: "  L %.3f  C %.4f      ", Ls[Ls.count / 2], C)
            }
            print(line)
        }
        var g = "global           |"
        for st in stats {
            let Ls = (0..<(st.w * st.h)).map { lab(st.px, 4 * $0).0 }.sorted()
            let Cs = (0..<(st.w * st.h)).map { i -> Double in let l = lab(st.px, 4 * i); return hypot(l.1, l.2) }
            g += String(format: "  p5 %.2f p50 %.2f p95 %.2f C %.4f LC %.1f", Ls[Ls.count / 20], Ls[Ls.count / 2], Ls[Ls.count * 19 / 20],
                        Cs.reduce(0, +) / Double(Cs.count), localContrast(st.px, st.w, st.h))
        }
        print(g)
        if CommandLine.arguments.contains("--fit") {
            let dev = Look.scaled(a.localGain.map { Look.localGain(base, $0) } ?? base, pow(2, r.baseExposure))
            let (d, _, _) = pixels(dev), ap = stats[0].px
            var line = "fit " + name
            for k in -12...8 {
                let lo = Double(k) / 2 - 0.25
                var ys: [Double] = [], sr: [Double] = []
                for i in stride(from: 0, to: d.count, by: 4) {
                    let y = 0.2126 * Double(d[i]) + 0.7152 * Double(d[i + 1]) + 0.0722 * Double(d[i + 2])
                    let st = log2(max(y, 1e-6) / 0.18)
                    guard st >= lo, st < lo + 0.5 else { continue }
                    let ya = 0.2126 * Double(ap[i]) + 0.7152 * Double(ap[i + 1]) + 0.0722 * Double(ap[i + 2])
                    ys.append(log2(max(ya, 1e-6) / 0.18))
                    let ls = lab(d, i), la = lab(ap, i), cs = hypot(ls.1, ls.2) / max(ls.0, 1e-3)
                    if cs > 0.03 { sr.append(hypot(la.1, la.2) / max(la.0, 1e-3) / cs) }
                }
                guard ys.count > 40 else { continue }
                ys.sort(); sr.sort()
                line += String(format: "  %+.1f:%+.2f/%.2f", Double(k) / 2, ys[ys.count / 2], sr.isEmpty ? 0 : sr[sr.count / 2])
            }
            print(line)
        }
        print(String(format: "mem %.0f MB", Look.footprintMB()))
    }
}

// --fit: Apple's global transfer on top of BetterCam's developed scene light (decode × baseExposure × local gain), per ½ stop:
// median Apple display-linear Y (as stops from 0.18) and median saturation ratio (OkLab C/L, Apple ÷ scene).
