// swiftc -O BetterCam/{Look,Filters}.swift checks/parity/main.swift -o /tmp/bettercam-parity
import CoreImage
import Foundation
import ImageIO

let space = Look.workingSpace
let side = 96
let bounds = CGRect(x: 0, y: 0, width: side, height: side)
let scheme = [0.012, 0.032, 0.08, 0.19, 0.36, 0.53, 0.85, 1.8, 2.4]
var raw = [Float](), video = [Float]()
for y in 0..<side {
    for x in 0..<side {
        let value = scheme[x * scheme.count / side] * (0.84 + 0.16 * Double(y) / Double(side))
        let rgb = [value * 1.05, value, value * 0.86]
        raw += rgb.map(Float.init) + [1]
        video += zip(rgb, [1.12, 1, 0.94]).map { Float(min(1, pow($0.0, 0.75) * $0.1)) } + [1]
    }
}
func image(_ p: [Float], white: Double) -> CIImage {
    CIImage(bitmapData: p.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 16,
            size: bounds.size, format: .RGBAf, colorSpace: space).settingProperties([Look.clipKey: white])
}
let sensor = image(raw, white: 2.5), isp = image(video, white: 1)
let analysis = Look.analyze(isp)
guard let match = Look.PreviewMatch(raw: sensor, video: isp, analysis: analysis) else {
    fatalError("Aligned gradients should fit")
}
var r = Recipe(filter: "editorial")
r.previewMatch = match
let payload = try JSONEncoder().encode(r)
precondition(try! JSONDecoder().decode(Recipe.self, from: payload) == r)
let legacy = Recipe(filter: "naturalReference")
precondition(try! JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(legacy)) == legacy)
let flipped = isp.oriented(.upMirrored)
precondition(Look.PreviewMatch(raw: sensor, video: flipped, analysis: analysis) == nil)
let corrected = match.apply(to: sensor)
let target = Look.PreviewMatch.tiles(isp)
let fitted = Look.PreviewMatch.tiles(corrected)
let original = Look.PreviewMatch.tiles(sensor)
var before = 0.0, after = 0.0
var count = 0
for i in stride(from: 1, to: target.count, by: 4) where (0.02...0.8).contains(target[i]) {
    before += abs(log2(original[i] / target[i]))
    after += abs(log2(fitted[i] / target[i]))
    count += 1
}
print(String(format: "Synthetic regional mean absolute error %.3f → %.3f EV (%d tiles)", before / Double(count), after / Double(count), count))
precondition(count > 200 && after < before * 0.45 && after / Double(count) < 0.16)
precondition(fitted[4 * 22 + 1] > fitted[4 * 20 + 1], "Recovered RAW highlights should retain gradation")

// The same lightness appears in both halves of the RAW, but the ISP renders each half differently.
var locallyMapped = [Float]()
for y in 0..<side {
    for x in 0..<side {
        let rawIndex = (y * side + x) * 4
        let gain: Float = y < side / 2 ? 0.72 : 1.18
        locallyMapped += raw[rawIndex..<(rawIndex + 3)].map { min(1, $0 * gain) } + [1]
    }
}
let spatialReference = image(locallyMapped, white: 1)
guard let spatial = Look.PreviewMatch(raw: sensor, video: spatialReference, analysis: Look.analyze(spatialReference)),
      spatial.regionalEV != nil else { fatalError("Missing spatial correction") }
let encoded = try JSONEncoder().encode(spatial)
var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
oldJSON["regionalEV"] = nil
let oldMatch = try JSONDecoder().decode(Look.PreviewMatch.self, from: JSONSerialization.data(withJSONObject: oldJSON))
let refTiles = Look.PreviewMatch.tiles(spatialReference)
let oldTiles = Look.PreviewMatch.tiles(oldMatch.apply(to: sensor))
let newTiles = Look.PreviewMatch.tiles(spatial.apply(to: sensor))
func meanRegionalError(_ pixels: [Double]) -> Double {
    let ev = stride(from: 1, to: refTiles.count, by: 4).compactMap { i -> Double? in
        let row = i / (24 * 4)
        guard row < 9 || row > 14, (0.03...0.65).contains(refTiles[i]) else { return nil }
        return abs(log2(pixels[i] / refTiles[i]))
    }
    return ev.reduce(0, +) / Double(ev.count)
}
let oldError = meanRegionalError(oldTiles), newError = meanRegionalError(newTiles)
print(String(format: "Regional tone correction %.3f → %.3f EV", oldError, newError))
precondition(newError < oldError * 0.55, "Regional tone should follow the corresponding preview area")

// The pre-look fit cannot see this display-side contrast and color difference.
let graded = Look.apply(r.grade, to: isp, analysis: analysis)
let lower = CGRect(x: 0, y: 0, width: side, height: side / 2)
let upper = CGRect(x: 0, y: side / 2, width: side, height: side / 2)
let displayReference = Look.transformed(graded.cropped(to: lower), [[0.68, 0, 0], [0, 0.75, 0], [0, 0, 0.83]])
    .composited(over: Look.scaled(graded.cropped(to: upper), 1.13))
    .cropped(to: graded.extent)
var displayMatch = match
displayMatch.matchDisplay(still: graded, preview: displayReference)
guard displayMatch.displayEV != nil else { fatalError("Missing display match") }
let saved = try JSONDecoder().decode(Look.PreviewMatch.self, from: JSONEncoder().encode(displayMatch))
let displayBefore = Look.PreviewMatch.tiles(graded)
let displayAfter = Look.PreviewMatch.tiles(saved.applyDisplay(to: graded))
let displayTarget = Look.PreviewMatch.tiles(displayReference)
func displayError(_ pixels: [Double]) -> Double {
    let errors = displayTarget.indices.compactMap { i -> Double? in
        let row = i / (24 * 4)
        guard row < 8 || row > 15, i % 4 != 3, (0.02...0.85).contains(displayTarget[i]) else { return nil }
        return abs(log2(max(0.004, pixels[i]) / displayTarget[i]))
    }
    return errors.reduce(0, +) / Double(errors.count)
}
let beforeDisplayError = displayError(displayBefore), afterDisplayError = displayError(displayAfter)
print(String(format: "Finished preview RGB matching %.3f → %.3f EV", beforeDisplayError, afterDisplayError))
precondition(afterDisplayError < 0.08 && afterDisplayError < beforeDisplayError * 0.4)

// The as-shot render must work even when RAW matching has no usable fit.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("original.heic")
    try Look.heif(sensor)!.write(to: source)
    let frame = Look.context.createCGImage(displayReference, from: bounds, format: .RGBA8, colorSpace: Look.outputSpace)!
    try Look.saveShutterFrame(frame, for: source)
    var shot = Recipe(filter: "editorial")
    shot.shutterLook = .init(filter: shot.filter, exposure: shot.exposure)
    shot = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(shot))
    let target = CIImage(cgImage: frame.cropping(to: CGRect(x: 12, y: 0, width: 72, height: 96))!)
    let expected = Look.PreviewMatch.tiles(target)
    let asShot = Look.renderPhoto(source, recipe: shot)!
    precondition(asShot.extent.size == target.extent.size)
    let error = zip(expected, Look.PreviewMatch.tiles(asShot)).map { abs($0 - $1) }.max()!
    precondition(error < 0.002, "The saved frame should preserve the viewfinder colors: \(error)")
    precondition(Look.renderPhoto(source, recipe: shot, maxSide: 48)?.extent.size == CGSize(width: 36, height: 48))
    let jpeg = Look.jpeg(asShot, quality: 0.95)!
    let jpegImage = CIImage(data: jpeg)!
    precondition(jpegImage.extent.size == asShot.extent.size)
    let sourceJPEG = CGImageSourceCreateWithData(jpeg as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(sourceJPEG, 0, nil) as? [String: Any]
    precondition(properties?[kCGImagePropertyProfileName as String] as? String == "Display P3")
    let errors = zip(expected, Look.PreviewMatch.tiles(jpegImage)).map { abs($0 - $1) }.sorted()
    precondition(errors[errors.count * 95 / 100] < 0.03)
    shot.warmth = 0.1
    precondition(!shot.usesShutterLook && Look.renderPhoto(source, recipe: shot)?.extent.size == bounds.size)
    shot.resetSliders()
    precondition(shot.usesShutterLook)
    try FileManager.default.removeItem(at: Look.shutterURL(for: source))
    precondition(Look.renderPhoto(source, recipe: shot)?.extent.size == bounds.size)
    print("Shutter frame, P3 JPEG, edits, and missing-frame fallback passed")
}

let paths = CommandLine.arguments.dropFirst().filter { $0 != "--full-bayer" }
for path in paths {
    autoreleasepool {
        let url = URL(fileURLWithPath: path)
        guard let small = Look.decode(url, maxSide: 360, normalizeForPreview: true),
              let legacy = Look.decode(url, maxSide: 360),
              let raw = CIRAWFilter(imageURL: url) else { fatalError(path) }
        let video = legacy.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: Look.scaled(small, 0.65)
        ]).cropped(to: small.extent).settingProperties([Look.clipKey: 1])
        let a = Look.analyze(video)
        guard var m = Look.PreviewMatch(raw: small, video: video, analysis: a) else { fatalError("Fit failed for \(path)") }
        var r = Recipe(filter: "editorial")
        let normalized = m.apply(to: small)
        m.matchDisplay(still: Look.apply(r.grade, to: normalized, analysis: m.analysis(for: normalized)),
                       preview: Look.apply(r.grade, to: video, analysis: a))
        precondition(m.displayEV != nil, "Display fit failed for \(path)")
        r.previewMatch = m
        guard let (thumb, ta) = Look.photo(url, recipe: r, maxSide: 600),
              let (editor, ea) = Look.photo(url, recipe: r, maxSide: 900),
              let jpg = Look.jpeg(Look.apply(r, to: editor, analysis: ea), quality: 0.95),
              let exported = CIImage(data: jpg) else { fatalError("Render failed for \(path)") }
        let t = Look.PreviewMatch.tiles(Look.apply(r, to: thumb, analysis: ta))
        let e = Look.PreviewMatch.tiles(exported)
        let errors = zip(t, e).enumerated().filter { $0.offset % 4 != 3 }.map { abs($0.element.0 - $0.element.1) }.sorted()
        let p95 = errors[errors.count * 95 / 100]
        precondition(p95 < 0.05, "Gallery/export mismatch for \(path): \(p95)")
        print("\(url.lastPathComponent) \(Look.isProRAW(url) ? "ProRAW" : "Bayer") \(raw.nativeSize) baseline=\(raw.baselineExposure) gallery/JPEG p95 linear RGB error \(p95)")
        if path == paths.first, CommandLine.arguments.contains("--full-bayer"), !Look.isProRAW(url),
           max(raw.nativeSize.width, raw.nativeSize.height) <= 4032 {
            guard let (full, fa) = Look.photo(url, recipe: r),
                  let data = Look.jpeg(Look.apply(r, to: full, analysis: fa), quality: 0.95),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                  let w = p[kCGImagePropertyPixelWidth as String] as? Int,
                  let h = p[kCGImagePropertyPixelHeight as String] as? Int else { fatalError("Full Bayer export failed") }
            precondition(Double(w * h) == raw.nativeSize.width * raw.nativeSize.height)
            precondition(p[kCGImagePropertyProfileName as String] as? String == "Display P3")
            print("Full Bayer JPEG \(w)×\(h), Display P3, \(data.count) bytes")
        }
    }
}
