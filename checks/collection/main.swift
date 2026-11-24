import CoreImage
import Foundation
import ImageIO

// Compile with Look.swift and Filters.swift. Optional -D BASELINE uses the frozen revision 27 sources.
setbuf(stdout, nil)
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 || (args.count == 2 && args[1] == "self-test") else { fatalError("usage: collection <output-folder> <small|look-id> <DNG…>") }
let folder = URL(fileURLWithPath: args[0], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

#if BASELINE
let ids = ["editorial", "leicaM6", "chroma", "afterHours", "riviera", "sunStudy", "alpine", "natural"]
let prefix = "before-"
#else
let ids = ["editorial", "leicaM6", "chroma", "afterHours", "sunprint", "atmosphere", "monochrome"]
let prefix = ""
precondition(Filter.all.map(\.id) == ids)
for id in ["editorial", "chroma", "afterHours", "riviera", "sunStudy", "alpine", "natural"] {
    let json = """
    {"version":10,"engine":2,"filter":"\(id)","exposure":0.2,"contrast":0.01,"warmth":0.12,
     "saturation":0.9,"crop":2,"baseExposure":-1.2,"grainSeed":8}
    """
    let old = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    precondition(old.filter == id && old.lookRevision == 0 && old.crop == 2 && old.grainSeed == 8
                 && old.exposure == 0.2 && old.contrast == 0.01 && old.warmth == 0.12
                 && old.saturation == 0.9 && old.baseExposure == -1.2)
    precondition(try! JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(old)) == old)
    var updated = old
    updated.lookRevision = Filter.revision
    precondition((old.grade != updated.grade) == ids.contains(id))
}
#endif

#if !BASELINE
if args[1] == "self-test" {
    let rect = CGRect(x: 0, y: 0, width: 640, height: 640)
    func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: Look.workingSpace)!).cropped(to: rect)
    }
    func sample(_ image: CIImage, _ bounds: CGRect) -> [Float] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        Look.context.render(image, toBitmap: &pixels, rowBytes: w * 16, bounds: bounds,
                            format: .RGBAf, colorSpace: Look.outputSpace)
        return pixels
    }
    let analysis = Look.Analysis(wb: (1, 1, 1))
    let red = patch(0.30, 0, 0, rect)
    let green = patch(0, 0.08918, 0, rect) // close to equal Rec.709 luminance as red
    let mono = Recipe(filter: "monochrome")
    let center = CGRect(x: 318, y: 318, width: 1, height: 1)
    let r = sample(Look.apply(mono, to: red, analysis: analysis), center)
    let g = sample(Look.apply(mono, to: green, analysis: analysis), center)
    precondition(abs(r[0] - r[1]) < 0.0005 && abs(r[1] - r[2]) < 0.0005 && r[0] - g[0] > 0.10)
    print("Monochrome equal-luma red/green patch encoded output", r[0], g[0])

    let mid = patch(0.18, 0.18, 0.18, rect)
    let specular = patch(1, 1, 1, CGRect(x: 300, y: 300, width: 40, height: 40))
        .composited(over: mid).cropped(to: rect)
    var chroma = Recipe(filter: "chroma")
    let chromaGrade = chroma.grade
    var noHalation = chromaGrade
    noHalation.bloom = 0
    let on = Look.apply(chromaGrade, to: specular, analysis: analysis)
    let off = Look.apply(noHalation, to: specular, analysis: analysis)
    let edge = CGRect(x: 340, y: 319, width: 1, height: 1)
    let far = CGRect(x: 360, y: 319, width: 1, height: 1)
    let a = sample(on, edge), b = sample(off, edge)
    let c = sample(on, far), d = sample(off, far)
    precondition(a[0] - b[0] > 0.001 && abs(c[0] - d[0]) < 0.0005)
    print("Chroma halation red-channel change at edge / 20 px away", a[0] - b[0], c[0] - d[0])

    let area = CGRect(x: 288, y: 288, width: 64, height: 64)
    chroma.grainSeed = 8
    let first = sample(Look.apply(chroma, to: mid, analysis: analysis), area)
    precondition(first == sample(Look.apply(chroma, to: mid, analysis: analysis), area))
    chroma.grainSeed = 9
    let other = sample(Look.apply(chroma, to: mid, analysis: analysis), area)
    let clean = sample(Look.apply(chromaGrade, to: mid, analysis: analysis), area)
    let squared = stride(from: 0, to: first.count, by: 4).map { pow(first[$0] - clean[$0], 2) }
    let rms = sqrt(squared.reduce(0, +) / Float(squared.count))
    precondition(first != other && rms > 0.001 && rms < 0.04)
    print("Chroma seeded grain encoded red-channel RMS", rms)

    let night = Filter.afterHours.grade
    let dark = night.resolved(sceneEV: 4), daylight = night.resolved(sceneEV: 12)
    precondition(dark.exposure < daylight.exposure && daylight == night)
    print("After Hours darkness exposure delta", dark.exposure - daylight.exposure)
    exit(0)
}
#endif

for path in args.dropFirst(2) {
    try autoreleasepool {
        let url = URL(fileURLWithPath: path)
        guard let raw = CIRAWFilter(imageURL: url) else { fatalError("Invalid RAW \(path)") }
        let start = ProcessInfo.processInfo.systemUptime
        var recipe = Recipe()
        recipe.baseExposure = Look.startingExposure(url, captured: path.hasPrefix("research/dngs/"))
        let name = url.deletingPathExtension().lastPathComponent
        let base: CIImage
        let analysis: Look.Analysis
        if url.pathExtension.lowercased() == "dng" {
            guard let developed = Look.photo(url, recipe: recipe, maxSide: 1200) else {
                fatalError("Development failed for \(path)")
            }
            (base, analysis) = developed
        } else {
            // Supplemental camera-native RAWs use their Core Image SDR profile as the creative transform input.
            precondition(args[1] == "small")
            raw.scaleFactor = Float(min(1, 1200 / max(raw.nativeSize.width, raw.nativeSize.height)))
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            guard let output = raw.outputImage else { fatalError("Development failed for \(path)") }
            var properties: [String: Any] = [Look.clipKey: 1.0]
            properties[Look.evKey] = Look.sceneEV(url)
            base = output.settingProperties(properties)
            analysis = Look.analyze(base, subject: true)
        }
        print("\(name) native=\(raw.nativeSize) ProRAW=\(Look.isProRAW(url)) EV=\(Look.sceneEV(url) ?? -99) range=\(analysis.localRange)")
        var renderIDs = args[1] == "small" ? ids : [args[1]]
        #if !BASELINE
        if args[1] == "small" { renderIDs += ["riviera", "sunStudy", "alpine", "natural"] }
        #endif
        for id in renderIDs {
            recipe.filter = id
            let dest = folder.appending(path: "\(name)__\(prefix)\(id).jpg")
            let gradeStart = ProcessInfo.processInfo.systemUptime
            if args[1] == "small" {
                let rendered = Look.apply(recipe, to: base, analysis: analysis, source: url)
                guard let data = Look.jpeg(rendered, quality: 0.94) else { fatalError("JPEG failed") }
                try data.write(to: dest)
                #if !BASELINE
                if ["editorial", "chroma", "afterHours", "riviera", "sunStudy", "alpine", "natural"].contains(id) {
                    var historical = recipe
                    historical.lookRevision = 0
                    guard let archived = Look.jpeg(Look.apply(historical, to: base, analysis: analysis, source: url),
                                                   quality: 0.94) else { fatalError("Historical JPEG failed") }
                    try archived.write(to: folder.appending(path: "\(name)__archived-\(id).jpg"))
                }
                #endif
            } else {
                precondition(Look.writeJPEG(url, recipe: recipe, analysis: analysis, to: dest))
                let source = CGImageSourceCreateWithURL(dest as CFURL, nil)!
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                let size = Look.outputSize(url, crop: recipe.crop)!
                precondition(image.width == Int(size.width) && image.height == Int(size.height))
                precondition(image.colorSpace?.name == CGColorSpace.displayP3)
                print("\(id) JPEG \(image.width)x\(image.height), Display P3")
            }
            print(String(format: "  %@ %.2f s, %.0f MB footprint", id,
                         ProcessInfo.processInfo.systemUptime - gradeStart, Look.footprintMB()))
        }
        print(String(format: "  total %.2f s", ProcessInfo.processInfo.systemUptime - start))
        Look.purge()
    }
}
