import CoreImage
import Foundation

// Same-RAW comparison renders for the revision 2 photographic engine (research/23-photographic-engine-v3.md).
// usage: engine3 <out-folder> <revision> <look-id|recipe|all> <raw…>
//   revision: 1 = rev 27 (Apple ProRAW profile + grade), 2 = scene-referred development
//   recipe: the look saved in the sidecar <raw>.json, if any
// One small render (1200 px long side, the app's guide/editor size) per look. Native exports: --native.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else { fatalError("usage: engine3 <out> <revision> <look|recipe|all> <raw…> [--native]") }
let out = URL(fileURLWithPath: args[0], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let revision = Int(args[1])!
let native = args.contains("--native")
for path in args.dropFirst(3) where path != "--native" {
    let url = URL(fileURLWithPath: path)
    var recipe = Recipe()
    let sidecar = url.deletingPathExtension().appendingPathExtension("json")
    if let d = try? Data(contentsOf: sidecar), let saved = try? JSONDecoder().decode(Recipe.self, from: d) { recipe = saved }
    let saved = recipe.filter
    recipe.lookRevision = revision
    if revision >= 2 || recipe.engine < 2 { recipe.baseExposure = Look.startingExposure(url, captured: true) }
    let ids = args[2] == "all" ? Filter.all.map(\.id) : [args[2] == "recipe" ? saved : args[2]]
    let name = url.deletingPathExtension().lastPathComponent
    let t0 = ProcessInfo.processInfo.systemUptime
    if native {
        for id in ids {
            recipe.filter = id
            let dest = out.appending(path: "\(name)__r\(revision)-\(id)-native.jpg")
            precondition(Look.writeJPEG(url, recipe: recipe, analysis: nil, to: dest))
            print(String(format: "%@ %@ native %.2f s, %.0f MB", name, id, ProcessInfo.processInfo.systemUptime - t0, Look.footprintMB()))
        }
        continue
    }
    guard let (base, analysis) = Look.photo(url, recipe: recipe, maxSide: 1200) else { fatalError("develop failed \(path)") }
    let t1 = ProcessInfo.processInfo.systemUptime
    for id in ids {
        recipe.filter = id
        let img = Look.apply(recipe, to: base, analysis: analysis, source: url)
        try Look.jpeg(img, quality: 0.93)!.write(to: out.appending(path: "\(name)__r\(revision)-\(id).jpg"))
    }
    print(String(format: "%@ base %.2f EV, develop %.2f s, %d looks %.2f s, %.0f MB", name, recipe.baseExposure,
                 t1 - t0, ids.count, ProcessInfo.processInfo.systemUptime - t1, Look.footprintMB()))
    Look.purge()
}
