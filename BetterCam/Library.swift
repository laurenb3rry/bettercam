import CoreImage
import Foundation

/// The in-app gallery: originals (DNG, or HEIC from a camera without RAW) + recipe + rendered thumbnail, in Documents/Shots.
/// Nothing is ever auto-deleted; originals are written once and never modified (edits live in the recipe JSON).
@MainActor
final class Library: ObservableObject {
    struct Shot: Identifiable, Hashable {
        let id: String
        let version: Date // thumbnail mtime, so the grid refreshes after an edit
    }

    @Published private(set) var shots: [Shot] = []
    /// A save/render problem the user must hear about (shown as an alert by the camera screen).
    @Published var message: String?
    private let dir = URL.documentsDirectory.appending(path: "Shots")
    private let fm = FileManager.default
    private var savingIDs: Set<String> = []

    init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.clearExports()
        reload()
        // Thumbnails that are missing (app quit mid-save), or made by an older look version: re-render in the background.
        // The version is recorded only after all of them are done, so an interrupted pass resumes on the next launch.
        let stale = UserDefaults.standard.integer(forKey: "lookVersion") != Look.version
        let todo = shots.filter { stale || !fm.fileExists(atPath: thumb($0.id).path) }
        Task {
            for shot in todo { await renderThumb(shot.id, recipe(shot.id)) }
            if stale { UserDefaults.standard.set(Look.version, forKey: "lookVersion") }
            if !todo.isEmpty { reload() }
        }
    }

    func raw(_ id: String) -> URL {
        let dng = dir.appending(path: "\(id).dng")
        return fm.fileExists(atPath: dng.path) ? dng : dir.appending(path: "\(id).heic")
    }
    func thumb(_ id: String) -> URL { dir.appending(path: "\(id).jpg") }
    private func recipeURL(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    func add(_ shot: Camera.Shot) async {
        let id = newID(), dst = dir.appending(path: "\(id).\(shot.ext)"), data = shot.data
        savingIDs.insert(id)
        defer { savingIDs.remove(id) }
        // off the main thread (a 48 MP ProRAW is ~100 MB); one retry, then the user is told: never a silent loss
        let err = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try data.write(to: dst, options: .atomic); return nil } catch {
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try data.write(to: dst, options: .atomic); return nil } catch { return error }
            }
        }.value
        if let err { message = "The photo couldn't be saved: \(err.localizedDescription)"; return }
        var r = Recipe(filter: shot.filter, crop: shot.crop)
        r.exposure = min(max(shot.exposure, Recipe.exposureRange.lowerBound), Recipe.exposureRange.upperBound)
        if shot.ext == "dng" { r.baseExposure = -Look.rawCompensation } // provisional (exact for bias 0), refined below
        writeRecipe(r, id) // so a crash before the next line still leaves an openable photo with its look
        r = await Task.detached(priority: .utility) { shot.recipe(for: dst, diagnosticID: id) }.value
        if shot.preview != nil, r.shutterLook == nil {
            message = "The original was saved, but BetterCam couldn't save the viewfinder image."
        }
        writeRecipe(r, id)
        reload()
        await renderThumb(id, r)
        reload()
    }

    /// Import from the photo library. RAW (DNG/ProRAW) is kept as-is; HEIC as-is; anything else (JPEG, PNG) → HEIC.
    func importPhoto(_ data: Data, isRaw: Bool, isHEIC: Bool) async {
        let id = newID()
        savingIDs.insert(id)
        defer { savingIDs.remove(id) }
        let dst = dir.appending(path: "\(id).\(isRaw ? "dng" : "heic")")
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            if isRaw || isHEIC { return (try? data.write(to: dst, options: .atomic)) != nil }
            guard let img = CIImage(data: data, options: [.applyOrientationProperty: true]), let heic = Look.heif(img) else { return false }
            return (try? heic.write(to: dst, options: .atomic)) != nil
        }.value
        guard ok else { message = "A photo couldn't be imported."; return }
        var r = Recipe()
        // imported RAWs weren't shot 1 stop under like ours: undo the decode's compensation (+ ProRAW exposure)
        if isRaw { r.baseExposure = await Task.detached(priority: .utility) { Look.startingExposure(dst, captured: false) }.value }
        writeRecipe(r, id)
        await renderThumb(id, r)
        reload()
    }

    private func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var id = f.string(from: .now), n = 1
        while savingIDs.contains(id) || ["json", "dng", "heic"].contains(where: { fm.fileExists(atPath: dir.appending(path: "\(id).\($0)").path) }) {
            id = f.string(from: .now) + "-\(n)"; n += 1
        }
        return id
    }

    func recipe(_ id: String) -> Recipe {
        (try? Data(contentsOf: recipeURL(id))).flatMap { try? JSONDecoder().decode(Recipe.self, from: $0) } ?? Recipe()
    }

    private func writeRecipe(_ r: Recipe, _ id: String) {
        do { try JSONEncoder().encode(r).write(to: recipeURL(id), options: .atomic) } catch {
            message = "Your edits couldn't be saved: \(error.localizedDescription)"
        }
    }

    /// Edits as they happen (cheap: the JSON only), so nothing is lost if the app is closed mid-edit.
    func store(_ r: Recipe, for id: String) {
        guard fm.fileExists(atPath: raw(id).path), r != recipe(id) else { return }
        writeRecipe(r, id)
    }

    /// Leaving the editor: recipe + a fresh thumbnail if anything changed since the thumbnail was made.
    func save(_ r: Recipe, for id: String) async {
        guard fm.fileExists(atPath: raw(id).path) else { return }
        if r != recipe(id) { writeRecipe(r, id) }
        let t = (try? fm.attributesOfItem(atPath: thumb(id).path)[.modificationDate] as? Date) ?? .distantPast
        let j = (try? fm.attributesOfItem(atPath: recipeURL(id).path)[.modificationDate] as? Date) ?? .distantPast
        guard j > t else { return }
        await renderThumb(id, r)
        reload()
    }

    func delete(_ id: String) {
        try? fm.removeItem(at: Look.shutterURL(for: raw(id)))
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
            autoreleasepool {
                guard let image = Look.renderPhoto(src, recipe: r, maxSide: 600),
                      let data = Look.jpeg(image) else { return }
                try? data.write(to: dst, options: .atomic)
            }
        }.value
    }

    // MARK: - Export files (share sheet)

    static let exportDir = FileManager.default.temporaryDirectory.appending(path: "Exports")
    /// Rendered JPEGs handed to the share sheet are temporary: cleared at launch so they never accumulate.
    static func clearExports() { try? FileManager.default.removeItem(at: exportDir) }
}
