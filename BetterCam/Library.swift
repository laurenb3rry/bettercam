import CoreImage
import Foundation
import os
import UIKit
import UniformTypeIdentifiers

/// The in-app gallery: originals (DNG, or HEIC from a camera without RAW) + recipe + rendered thumbnail, in Documents/Shots.
/// Nothing is ever auto-deleted; originals are written once and never modified (edits live in the recipe JSON).
@MainActor
final class Library: ObservableObject {
    struct Shot: Identifiable, Hashable {
        let id: String
        let version: Date // thumbnail mtime, so the grid refreshes after an edit
    }

    @Published private(set) var processingCaptures = 0
    @Published private(set) var shots: [Shot] = []
    /// A save/render problem the user must hear about (shown as an alert by the camera screen).
    @Published var message: String?
    private let dir = URL.documentsDirectory.appending(path: "Shots")
    private let fm = FileManager.default
    private static let log = Logger(subsystem: "bettercam", category: "library")
    private var recent: (url: URL, crop: Double, exposure: Double, image: CIImage)?
    private struct DevelopmentKey: Hashable {
        let url: URL
        let crop: Double
        let exposure: Double
    }
    private var developments: [DevelopmentKey: Task<CIImage?, Never>] = [:]
    private var pendingRecipes: [String: Task<Recipe, Never>] = [:]
    private var thumbnailsInFlight: Set<String> = []
    private var savingIDs: Set<String> = []

    init() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.clearExports()
        reload()
    }

    func raw(_ id: String) -> URL {
        let dng = dir.appending(path: "\(id).dng")
        if fm.fileExists(atPath: dng.path) { return dng }
        let nativeRAW = dir.appending(path: "\(id).raw")
        return fm.fileExists(atPath: nativeRAW.path) ? nativeRAW : dir.appending(path: "\(id).heic")
    }
    func thumb(_ id: String) -> URL {
        let current = currentThumb(id)
        if recipe(id).profile != nil, fm.fileExists(atPath: current.path) { return current }
        for version in [33, 32, 31, 29, 28, 27, 25, 24] {
            let previous = dir.appending(path: "\(id).v\(version).jpg")
            if fm.fileExists(atPath: previous.path) { return previous }
        }
        return dir.appending(path: "\(id).jpg")
    }

    private func currentThumb(_ id: String) -> URL {
        dir.appending(path: "\(id).v\(Look.version).jpg")
    }
    private func recipeURL(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    func add(_ shot: Camera.Shot, data: Data) async {
        let id = newID(), dst = dir.appending(path: "\(id).\(shot.ext)")
        savingIDs.insert(id)
        processingCaptures += 1
        // off the main thread (a 48 MP ProRAW is ~100 MB); one retry, then the user is told: never a silent loss
        let err = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try data.write(to: dst, options: .atomic); return nil } catch {
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try data.write(to: dst, options: .atomic); return nil } catch { return error }
            }
        }.value
        if let err {
            processingCaptures -= 1
            savingIDs.remove(id)
            message = "The photo couldn't be saved: \(err.localizedDescription)"
            return
        }
        let persisted = ProcessInfo.processInfo.systemUptime
        Self.log.info("capture \(shot.captureID) DNG delivery to disk \((persisted - shot.delivered) * 1000) ms")
        let provisional = shot.provisionalRecipe
        writeRecipe(provisional, id)
        let captureID = shot.captureID
        let normalization = Task {
            defer {
                pendingRecipes[id] = nil
                savingIDs.remove(id)
                processingCaptures -= 1
            }
            let result = await Self.develop(priority: .veryHigh) {
                let recipe = Look.normalizeCapture(provisional, source: dst)
                guard let guide = Look.photo(dst, recipe: recipe),
                      let image = Look.apply(recipe, to: Look.fit(guide, 600)),
                      let jpeg = Look.jpeg(image) else { return nil as (Recipe, CIImage, Data, UIImage?)? }
                return (recipe, guide, jpeg, UIImage(data: jpeg)?.preparingForDisplay())
            }
            guard fm.fileExists(atPath: dst.path) else { return provisional }
            guard let (recipe, guide, jpeg, prepared) = result else {
                message = "The original was saved, but its thumbnail couldn't be rendered."
                return provisional
            }
            guard writeRecipe(recipe, id) else { return provisional }
            if let diagnostic = shot.diagnostic { Diagnostics.save(diagnostic, source: dst, libraryID: id, recipe: recipe, guide: guide) }
            if publishThumbnail(jpeg, for: id, prepared: prepared) {
                if shots.first?.id == id { recent = (dst, recipe.crop, recipe.baseExposure, guide) }
                Self.log.info("capture \(captureID) disk to thumbnail published \((ProcessInfo.processInfo.systemUptime - persisted) * 1000) ms")
            } else {
                message = "The original was saved, but its thumbnail couldn't be saved."
            }
            return recipe
        }
        pendingRecipes[id] = normalization
        let version = Date.distantPast
        if let preview = shot.preview {
            Thumb.cacheImage(UIImage(cgImage: preview), for: thumb(id), version: version)
        }
        updateShot(Shot(id: id, version: version))
        Self.log.info("capture \(shot.captureID) disk to gallery entry \((ProcessInfo.processInfo.systemUptime - persisted) * 1000) ms")
    }

    /// Import from the photo library. RAW (DNG/ProRAW) is kept as-is; HEIC as-is; anything else (JPEG, PNG) → HEIC.
    func importPhoto(_ data: Data, format: UTType?) async {
        let id = newID()
        savingIDs.insert(id)
        defer { savingIDs.remove(id) }
        let isRaw = format?.conforms(to: .rawImage) == true
        let ext = format?.preferredFilenameExtension == "dng" ? "dng" : (isRaw ? "raw" : "heic")
        let dst = dir.appending(path: "\(id).\(ext)")
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            if isRaw || format?.conforms(to: .heic) == true { return (try? data.write(to: dst, options: .atomic)) != nil }
            guard let img = CIImage(data: data, options: [.applyOrientationProperty: true]), let heic = Look.heif(img) else { return false }
            return (try? heic.write(to: dst, options: .atomic)) != nil
        }.value
        guard ok else { message = "A photo couldn't be imported."; return }
        let r = Recipe()
        writeRecipe(r, id)
        let rendered = await renderThumb(id, r)
        savingIDs.remove(id)
        if !rendered {
            reload()
            message = "The original was imported, but it couldn't be developed."
        }
    }

    private func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        var id = f.string(from: .now), n = 1
        while savingIDs.contains(id) || ["json", "dng", "raw", "heic"].contains(where: { fm.fileExists(atPath: dir.appending(path: "\(id).\($0)").path) }) {
            id = f.string(from: .now) + "-\(n)"; n += 1
        }
        return id
    }

    func load(_ id: String) async -> Recipe {
        if let pending = pendingRecipes[id] { _ = await pending.value }
        let recipe = recipe(id)
        guard recipe.profile != nil, recipe.pendingCaptureExposure == true else { return recipe }
        let url = raw(id)
        let normalized = await Self.develop { Look.normalizeCapture(recipe, source: url) }
        guard self.recipe(id) == recipe, fm.fileExists(atPath: url.path) else { return self.recipe(id) }
        return writeRecipe(normalized, id) ? normalized : recipe
    }

    /// Heavy background development (thumbnails, migration, new captures) runs one job at a time: a burst of 48 MP
    /// shots queues instead of decoding several originals at once.
    private static let developQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "bettercam.develop"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static func develop<T>(priority: Operation.QueuePriority = .normal, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let operation = BlockOperation {
                continuation.resume(returning: autoreleasepool { work() })
            }
            operation.queuePriority = priority
            developQueue.addOperation(operation)
        }
    }

    func recipe(_ id: String) -> Recipe {
        if let data = try? Data(contentsOf: recipeURL(id)),
           let recipe = try? JSONDecoder().decode(Recipe.self, from: data) { return recipe }
        // An original without a readable recipe must never acquire a new look silently.
        var legacy = Recipe(filter: "editorial")
        legacy.engine = 0
        legacy.lookRevision = 0
        return legacy
    }

    @discardableResult
    private func writeRecipe(_ r: Recipe, _ id: String) -> Bool {
        do {
            try JSONEncoder().encode(r).write(to: recipeURL(id), options: .atomic)
            return true
        } catch {
            message = "Your edits couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func store(_ r: Recipe, for id: String) -> Bool {
        let previous = recipe(id)
        guard r.profile != nil, fm.fileExists(atPath: raw(id).path) else { return false }
        guard r != previous else { return true }
        if previous.profile == nil {
            do {
                for (source, suffix) in [(recipeURL(id), "v0.json"), (thumb(id), "v0.jpg")] {
                    let backup = dir.appending(path: "\(id).\(suffix)")
                    if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: backup.path) {
                        try Data(contentsOf: source).write(to: backup, options: .atomic)
                    }
                }
            } catch {
                message = "Couldn’t preserve the previous grade: \(error.localizedDescription)"
                return false
            }
        }
        return writeRecipe(r, id)
    }

    /// Leaving the editor: refresh the thumbnail from the saved recipe.
    func refreshThumbnail(_ id: String) async {
        guard !Task.isCancelled else { return }
        guard fm.fileExists(atPath: raw(id).path) else { return }
        guard recipe(id).profile != nil, !savingIDs.contains(id), thumbnailNeedsRefresh(id),
              thumbnailsInFlight.insert(id).inserted else { return }
        defer { thumbnailsInFlight.remove(id) }
        _ = await renderThumb(id, await load(id))
    }

    private func thumbnailNeedsRefresh(_ id: String) -> Bool {
        guard let thumbnailDate = (try? fm.attributesOfItem(atPath: currentThumb(id).path))?[.modificationDate] as? Date else {
            return true
        }
        let recipeDate = (try? fm.attributesOfItem(atPath: recipeURL(id).path))?[.modificationDate] as? Date
        return (recipeDate ?? .distantPast) > thumbnailDate
    }

    func delete(_ ids: Set<String>) -> Set<String> {
        var failed: Set<String> = []
        for id in ids {
            let original = raw(id)
            do {
                if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
            } catch {
                failed.insert(id)
                continue
            }
            if recent?.url == original { recent = nil }
            try? fm.removeItem(at: currentThumb(id))
            for version in [50, 33, 32, 31, 29, 28, 27, 25, 24] where version != Look.version {
                try? fm.removeItem(at: dir.appending(path: "\(id).v\(version).jpg"))
            }
            try? fm.removeItem(at: Look.shutterURL(for: original))
            try? fm.removeItem(at: Look.previewURL(for: original))
            for ext in ["jpg", "json", "engine1.json", "v0.json", "v0.jpg", "photographic-r3.jpg"] {
                try? fm.removeItem(at: dir.appending(path: "\(id).\(ext)"))
            }
        }
        reload()
        return failed
    }

    private func reload() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let published = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        shots = files
            .filter { ["dng", "raw", "heic"].contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !savingIDs.contains($0) || published[$0] != nil }
            .sorted(by: >)
            .map { id in
                if savingIDs.contains(id), let shot = published[id] { return shot }
                let mtime = (try? fm.attributesOfItem(atPath: thumb(id).path)[.modificationDate] as? Date) ?? .distantPast
                return Shot(id: id, version: mtime)
            }
    }

    func developed(_ url: URL, recipe: Recipe, priority: Operation.QueuePriority = .high) async -> CIImage? {
        guard recipe.profile != nil else { return nil }
        let key = DevelopmentKey(url: url, crop: recipe.crop, exposure: recipe.baseExposure)
        if let recent, recent.url == url, recent.crop == recipe.crop, recent.exposure == recipe.baseExposure {
            return recent.image
        }
        if let task = developments[key] { return await task.value }
        let task = Task { await Self.develop(priority: priority) { Look.photo(url, recipe: recipe) } }
        developments[key] = task
        let photo = await task.value
        if let photo, shots.first?.id == url.deletingPathExtension().lastPathComponent {
            recent = (url, recipe.crop, recipe.baseExposure, photo)
        }
        developments[key] = nil
        return photo
    }

    private func renderThumb(_ id: String, _ recipe: Recipe) async -> Bool {
        let src = raw(id)
        guard fm.fileExists(atPath: src.path), let base = await developed(src, recipe: recipe, priority: .low),
              !Task.isCancelled else { return false }
        let data = await Self.develop(priority: .low) {
            Look.apply(recipe, to: Look.fit(base, 600)).flatMap { Look.jpeg($0) }
        }
        guard let data, fm.fileExists(atPath: src.path), recipe == self.recipe(id) else { return false }
        return publishThumbnail(data, for: id)
    }

    private func publishThumbnail(_ data: Data, for id: String, prepared: UIImage? = nil) -> Bool {
        let dst = currentThumb(id)
        guard (try? data.write(to: dst, options: .atomic)) != nil else { return false }
        let date = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        if let prepared { Thumb.cacheImage(prepared, for: dst, version: date) }
        updateShot(Shot(id: id, version: date))
        return true
    }

    private func updateShot(_ shot: Shot) {
        if let i = shots.firstIndex(where: { $0.id == shot.id }) {
            shots[i] = shot
        } else if savingIDs.contains(shot.id) {
            shots.insert(shot, at: shots.firstIndex { $0.id < shot.id } ?? shots.endIndex)
        }
    }

    // MARK: - Export files (share sheet)

    static let exportDir = FileManager.default.temporaryDirectory.appending(path: "Exports")
    /// Rendered JPEGs handed to the share sheet are temporary: cleared at launch so they never accumulate.
    static func clearExports() { try? FileManager.default.removeItem(at: exportDir) }
}
