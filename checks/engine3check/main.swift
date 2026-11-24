// Revision 2 engine checks (research/23-photographic-engine-v3.md). Guide-size renders only (≤ 1200 px), sequential.
//   swiftc -O BetterCam/{Look,Filters}.swift checks/engine3check/main.swift -o /tmp/e3check && /tmp/e3check
import CoreImage
import Foundation

setbuf(stdout, nil)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let pro12 = root.appending(path: "research/proRAWs/IMG_6931.DNG")
let baselineDir = root.appending(path: "research/photographic-engine-v3/baseline")

func pixels(_ img: CIImage) -> [Float] {
    let e = img.extent.integral, w = Int(e.width), h = Int(e.height)
    var p = [Float](repeating: 0, count: w * h * 4)
    Look.context.render(img, toBitmap: &p, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: Look.outputSpace)
    return p
}
func patch(_ v: (CGFloat, CGFloat, CGFloat), clip: Double) -> CIImage {
    CIImage(color: CIColor(red: v.0, green: v.1, blue: v.2, colorSpace: Look.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        .settingProperties([Look.clipKey: clip])
}

// 1. Recipes and revisions
do {
    check(Recipe().lookRevision == 2 && Filter.revision == 2, "new recipes use revision 2")
    let old = try! JSONDecoder().decode(Recipe.self, from: Data(#"{"filter":"leicaM6","version":10,"exposure":0,"contrast":0,"warmth":0,"saturation":1}"#.utf8))
    check(old.lookRevision == 0 && !Look.sceneReferred(old), "recipes without lookRevision keep the old development")
    for f in Filter.all {
        check(Filter.named(f.id, revision: 1) == Filter.revision1.first { $0.id == f.id }! && Filter.named(f.id, revision: 2) == f,
              "\(f.id): revision 1 frozen, revision 2 current")
    }
}

// 2. Development routing on a real ProRAW
do {
    var r1 = Recipe(filter: "editorial"); r1.lookRevision = 1
    var r2 = Recipe(filter: "editorial"); r2.baseExposure = Look.startingExposure(pro12, captured: true)
    let (b1, a1) = Look.photo(pro12, recipe: r1, maxSide: 400)!
    let (b2, a2) = Look.photo(pro12, recipe: r2, maxSide: 400)!
    check(!a1.raw && a1.clip == 1, "revision 1 ProRAW: Apple profile, display white (unchanged)")
    check(!a2.raw && a2.clip == 1 && (b2.properties[Look.clipKey] as? Double ?? 0) == 1,
          "current ProRAW starts from the Apple display profile")
    var pending = r2; pending.pendingCaptureExposure = true
    let (captured, _, ca) = Look.captureDevelopment(pro12, recipe: pending)!
    check(captured.baseExposure == 0 && captured.pendingCaptureExposure == nil && !ca.raw,
          "capture clears pending exposure and uses Apple's display rendering")
    let display = b2.settingProperties([Look.clipKey: 1.0])
    var video = r2; video.baseExposure = 0
    check(pixels(Look.apply(r2, to: b2, analysis: a2, source: pro12)) ==
          pixels(Look.apply(video, to: display, analysis: a2, source: pro12)),
          "the ProRAW profile and video receive the same look on identical display pixels")
    let e1 = pixels(Look.apply(r2, to: b2, analysis: a2, source: pro12))
    var leica = r2; leica.filter = "leicaM6"
    _ = pixels(Look.apply(leica, to: b2, analysis: a2, source: pro12))
    check(e1 == pixels(Look.apply(r2, to: b2, analysis: a2, source: pro12)), "revision 2 render is deterministic and look-independent")
    // revision 1 still matches the frozen rev 27 guide render (Look.version 27 harness, checks/engine3)
    let ref = baselineDir.appending(path: "IMG_6931__r1-editorial.jpg")
    if let refImg = CIImage(contentsOf: ref) {
        let (g1, ga1) = Look.photo(pro12, recipe: r1, maxSide: 1200)!
        let now = CIImage(data: Look.jpeg(Look.apply(r1, to: g1, analysis: ga1, source: pro12), quality: 0.93)!)!
        let a = pixels(now), b = pixels(refImg)
        var d = [Float](); for i in a.indices where i % 4 != 3 { d.append(abs(a[i] - b[i])) }
        d.sort()
        check(a.count == b.count && d[d.count * 99 / 100] < 1.5 / 255, "revision 1 render matches the frozen rev 27 baseline (p99 Δ \(d[d.count * 99 / 100] * 255) codes)")
    } else { check(false, "baseline \(ref.lastPathComponent) present") }
    _ = b1
}

// 3. Grade properties on synthetic scene light (clip 4 = scene-referred input)
let scene = Look.Analysis(wb: (1, 1, 1), clip: 4)
for f in Filter.all {
    var r = Recipe(filter: f.id); r.grainSeed = 1
    var g = f.grade; g.grain = 0; g.bloom = 0
    for v in [0.02, 0.18, 0.7, 2.0] {
        let p = pixels(Look.apply(g, to: patch((v, v, v), clip: 4), analysis: scene))
        let spread = max(p[0], p[1], p[2]) - min(p[0], p[1], p[2])
        // Editorial, After Hours and Monochrome keep greys strictly neutral; the crossover looks may tint ≤ 2%
        let strict = ["editorial", "afterHours", "monochrome"].contains(f.id)
        check(spread < (strict ? 0.006 : 0.02), "\(f.id): scene grey \(v) prints \(strict ? "neutral" : "near-neutral") (spread \(spread))")
    }
    let lut = Look.lut(g, white: log2(4 / 0.18))
    let bad = lut.withUnsafeBytes { $0.bindMemory(to: Float.self).filter { !$0.isFinite || $0 < -0.0001 || $0 > 1.0001 }.count }
    check(bad == 0, "\(f.id): LUT inside 0…1 (\(bad) bad)")
    let grey = pixels(Look.apply(g, to: patch((0.18, 0.18, 0.18), clip: 4), analysis: scene))[1]
    check((0.38...0.56).contains(grey), "\(f.id): 18% scene grey prints at encoded \(grey)")
}
do { // monochrome orange-filter response: equal-luminance red vs blue
    var g = Filter.monochrome.grade; g.grain = 0
    let red = pixels(Look.apply(g, to: patch((0.40, 0.12, 0.10), clip: 4), analysis: scene))[0]
    let y = 0.2126 * 0.40 + 0.7152 * 0.12 + 0.0722 * 0.10
    let blue = pixels(Look.apply(g, to: patch(((y - 0.7152 * 0.12 - 0.0722 * 0.9) / 0.2126, 0.12, 0.9), clip: 4), analysis: scene))[0]
    check(red > blue + 0.05, "monochrome prints red lighter than an equal-luminance blue (\(red) vs \(blue))")
}

// 4. Sky burn: same brightness, blue vs neutral, in the local development
do {
    let w = 48, h = 48
    var px = [Float](repeating: 0.002, count: w * h * 4) // dark ground (wide range)
    for y in 0..<h / 2 { for x in 0..<w {
        let i = 4 * (y * w + x)
        if x < w / 2 { px[i] = 0.9; px[i + 1] = 1.4; px[i + 2] = 2.4 } else { px[i] = 1.6; px[i + 1] = 1.6; px[i + 2] = 1.6 }
    }}
    let before = px
    _ = Look.localDevelopment(&px, w: w, h: h, iso: 100, highlights: Look.sceneHighlights)
    let sky = log2(px[4 * (4 * w + 4) + 1] / before[4 * (4 * w + 4) + 1])
    let wall = log2(px[4 * (4 * w + 44) + 1] / before[4 * (4 * w + 44) + 1])
    check(sky < wall - 0.5, "sky burn darkens bright blue more than bright neutral (\(sky) vs \(wall) stops)")
}

// 5. Viewfinder: display-referred frames enter revision 2 as scene light
do {
    let frame = patch((0.5, 0.5, 0.5), clip: 1)
    let s = Look.sceneFromDisplay(frame)
    let v = pixels(s)[1]
    check((s.properties[Look.clipKey] as? Double ?? 0) > 1.4 && v > 0.18 && v < 1.44, "viewfinder inverse maps display 0.5 to scene \(v)")
    let out = pixels(Look.apply(Recipe(filter: "editorial"), to: frame, analysis: Look.Analysis(wb: (1, 1, 1), clip: 1)))
    check(out[0].isFinite && (0...1).contains(out[1]), "viewfinder frame renders through a revision 2 look (\(out[1]))")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
