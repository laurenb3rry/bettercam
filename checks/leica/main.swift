import CoreImage
import ImageIO

let args = CommandLine.arguments
guard args.count == 5 else {
    fatalError("usage: render <r26|m6|input|gain-off|editorial> <small|full> <source> <output.jpg>")
}
let mode = args[1], full = args[2] == "full"
let source = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
let started = ProcessInfo.processInfo.systemUptime
let isDNG = source.pathExtension.lowercased() == "dng"
guard ["r26", "m6", "input", "gain-off", "editorial"].contains(mode),
      ["small", "full"].contains(args[2]), !(full && mode == "gain-off") else {
    fatalError("unsupported render mode")
}
let raw = isDNG ? CIRAWFilter(imageURL: source) : nil
if isDNG {
    guard let raw else { fatalError("RAW decoder rejected this DNG") }
    print("native=\(raw.nativeSize), ProRAW=\(Look.isProRAW(source)), baselineExposure=\(raw.baselineExposure), gain=\(raw.localToneMapAmount), boost=\(raw.boostAmount), sharpness=\(raw.sharpnessAmount), noise=\(raw.luminanceNoiseReductionAmount)")
}
var recipe = Recipe(filter: mode == "editorial" ? Filter.editorial.id : Filter.leicaM6.id)
recipe.baseExposure = Look.startingExposure(source, captured: false)
if full && (mode == "m6" || mode == "r26" || mode == "editorial") {
    guard Look.writeJPEG(source, recipe: recipe, analysis: nil, to: output) else { fatalError("export failed") }
} else {
    guard let (base, analysis) = Look.photo(source, recipe: recipe, maxSide: full ? nil : 1200) else {
        fatalError("decode failed")
    }
    let image: CIImage
    switch mode {
    case "input":
        image = analysis.raw ? Look.develop(base, analysis, exposure: recipe.baseExposure) : base
    case "gain-off":
        guard let raw, Look.isProRAW(source) else { fatalError("gain-off needs ProRAW") }
        raw.scaleFactor = Float(min(1, 1200 / max(raw.nativeSize.width, raw.nativeSize.height)))
        raw.localToneMapAmount = 0
        guard let test = raw.outputImage else { fatalError("RAW decode failed") }
        guard test.extent == base.extent else { fatalError("gain comparison is not registered") }
        image = Look.apply(recipe, to: test, analysis: analysis, source: source)
    default:
        image = Look.apply(recipe, to: base, analysis: analysis, source: source)
    }
    guard let jpg = Look.jpeg(image, quality: 0.95) else { fatalError("JPEG failed") }
    try jpg.write(to: output)
}
guard let jpg = CGImageSourceCreateWithURL(output as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(jpg, 0, nil) as? [String: Any] else { fatalError("cannot read output") }
print("\(mode) \(p["PixelWidth"] ?? "?")x\(p["PixelHeight"] ?? "?") \(String(format: "%.2f s", ProcessInfo.processInfo.systemUptime - started))")
