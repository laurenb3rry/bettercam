// Engine 2 visual comparison (research/19): one file at a time, 1024 px, sequential. Bounded memory by design.
//   swiftc -O -o /tmp/develop BetterCam/{Look,Filters}.swift checks/develop/main.swift
//   /tmp/develop <out dir> <file…>
// Per file: A engine 1 RAW development (Editorial, no local development), B engine 2 Natural Reference,
// C engine 2 Editorial, D engine 2 Leica M6. Prints the measured scene range and the render time.
import CoreImage
import Foundation

setbuf(stdout, nil)
var args = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: args.removeFirst())
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let side: CGFloat = 1024
for path in args {
    autoreleasepool {
        let url = URL(fileURLWithPath: path), name = url.deletingPathExtension().lastPathComponent
        let t0 = Date()
        var r = Recipe(filter: Filter.editorial.id)
        r.baseExposure = Look.startingExposure(url, captured: true)
        let t1 = Date()
        // A: engine 1's ordinary RAW path (no preview match): same decode, analysis without local development
        let old = Look.decode(url, maxSide: side)!
        let oldA = Look.analyze(old, subject: true)
        var variants: [(String, CIImage)] = [("A-engine1-editorial", Look.apply(r, to: old, analysis: oldA, source: url))]
        guard let (base, a) = Look.photo(url, recipe: r, maxSide: side) else { print("FAIL decode \(name)"); return }
        for (label, id) in [("B-reference", Filter.naturalReference.id), ("C-editorial", Filter.editorial.id), ("D-leica", Filter.leicaM6.id)] {
            var x = r; x.filter = id
            variants.append((label, Look.apply(x, to: base, analysis: a, source: url)))
        }
        for (label, img) in variants {
            try! Look.jpeg(img, quality: 0.9)!.write(to: out.appending(path: "\(name)__\(label).jpg"))
        }
        print(String(format: "%@ range %.1f stops local=%@ base %.2f EV  exposure %.2fs render %.2fs mem %.0f MB",
                     name, a.localRange, a.localGain == nil ? "off" : "on", r.baseExposure,
                     t1.timeIntervalSince(t0), Date().timeIntervalSince(t1), Look.footprintMB()))
    }
}
