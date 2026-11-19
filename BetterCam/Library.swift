import CoreImage
import Foundation

/// The in-app gallery: originals (DNG, or HEIC from the selfie camera) + recipe + rendered thumbnail, in Documents/Shots.
/// Nothing is ever auto-deleted.
@MainActor
final class Library: ObservableObject {
    struct Shot: Identifiable, Hashable {
        let id: String
        let version: Date // thumbnail mtime, so the grid refreshes after an edit
    }

    @Published private(set) var shots: [Shot] = []
    private let dir = URL.documentsDirectory.appending(path: "Shots")
    private let fm = FileManager.default

    init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        // The look changed since these thumbnails were made: re-render them in the background.
        if UserDefaults.standard.integer(forKey: "lookVersion") != Look.version {
            UserDefaults.standard.set(Look.version, forKey: "lookVersion")
            Task {
                for shot in shots { await renderThumb(shot.id, recipe(shot.id)) }
                reload()
            }
        }
    }

    func raw(_ id: String) -> URL {
        let dng = dir.appending(path: "\(id).dng")
        return fm.fileExists(atPath: dng.path) ? dng : dir.appending(path: "\(id).heic")
    }
    func thumb(_ id: String) -> URL { dir.appending(path: "\(id).jpg") }
    private func recipeURL(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    func add(_ shot: Camera.Shot) async {
        let id = newID()
        do { try shot.data.write(to: dir.appending(path: "\(id).\(shot.ext)")) } catch { return }
        let r = Recipe(filter: shot.filter, crop: shot.crop)
        try? JSONEncoder().encode(r).write(to: recipeURL(id))
        await renderThumb(id, r)
        reload()
    }

    /// Import from the photo library. RAW (DNG/ProRAW) is kept as-is; HEIC as-is; anything else (JPEG, PNG) → HEIC.
    func importPhoto(_ data: Data, isRaw: Bool, isHEIC: Bool) async {
        let id = newID()
        let dst = dir.appending(path: "\(id).\(isRaw ? "dng" : "heic")")
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            if isRaw || isHEIC { return (try? data.write(to: dst)) != nil }
            guard let img = CIImage(data: data, options: [.applyOrientationProperty: true]), let heic = Look.heif(img) else { return false }
            return (try? heic.write(to: dst)) != nil
        }.value
        guard ok else { return }
        var r = Recipe()
        // ponytail: imported RAWs weren't shot 1 stop under like ours; undo the decode's compensation
        if isRaw { r.baseExposure = -Look.rawCompensation }
        try? JSONEncoder().encode(r).write(to: recipeURL(id))
        await renderThumb(id, r)
        reload()
    }

    private func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var id = f.string(from: .now), n = 1
        while fm.fileExists(atPath: dir.appending(path: "\(id).json").path) { id = f.string(from: .now) + "-\(n)"; n += 1 }
        return id
    }

    func recipe(_ id: String) -> Recipe {
        (try? Data(contentsOf: recipeURL(id))).flatMap { try? JSONDecoder().decode(Recipe.self, from: $0) } ?? Recipe()
    }

    func save(_ r: Recipe, for id: String) async {
        guard fm.fileExists(atPath: raw(id).path), r != recipe(id) else { return }
        try? JSONEncoder().encode(r).write(to: recipeURL(id))
        await renderThumb(id, r)
        reload()
    }

    func delete(_ id: String) {
        for ext in ["dng", "heic", "jpg", "json"] { try? fm.removeItem(at: dir.appending(path: "\(id).\(ext)")) }
        reload()
    }

    private func reload() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        shots = files
            .filter { ["dng", "heic"].contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted(by: >)
            .map { id in
                let mtime = (try? fm.attributesOfItem(atPath: thumb(id).path)[.modificationDate] as? Date) ?? .distantPast
                return Shot(id: id, version: mtime)
            }
    }

    private func renderThumb(_ id: String, _ r: Recipe) async {
        let src = raw(id), dst = thumb(id)
        await Task.detached(priority: .utility) { // background: must not compete with the editor
            guard let base = Look.decode(src, crop: r.crop, maxSide: 600), let data = Look.jpeg(Look.apply(r, to: base)) else { return }
            try? data.write(to: dst)
        }.value
    }
}
