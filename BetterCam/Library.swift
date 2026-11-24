import CoreImage
import Foundation
import os
import UIKit

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
    private var recent: (url: URL, crop: Double, exposure: Double, scene: Bool, image: CIImage, analysis: Look.Analysis)?
    private struct DevelopmentKey: Hashable {
        let url: URL
        let crop: Double
        let exposure: Double
        let scene: Bool
    }
    private var developments: [DevelopmentKey: Task<(CIImage, Look.Analysis)?, Never>] = [:]
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
        return fm.fileExists(atPath: dng.path) ? dng : dir.appending(path: "\(id).heic")
    }
    func thumb(_ id: String) -> URL {
        let current = currentThumb(id)
        if fm.fileExists(atPath: current.path) { return current }
        for version in [28, 27, 25, 24] {
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
                Look.captureDevelopment(dst, recipe: provisional).map { recipe, guide, analysis in
                    let image = Look.apply(recipe, to: Look.fit(guide, 600), analysis: analysis, source: dst)
                    let jpeg = Look.jpeg(image)
                    return (recipe, guide, analysis, jpeg, jpeg.flatMap { UIImage(data: $0)?.preparingForDisplay() })
                }
            }
            guard fm.fileExists(atPath: dst.path) else { return provisional }
            guard let (recipe, guide, analysis, jpeg, prepared) = result else {
                message = "The original was saved, but its thumbnail couldn't be rendered."
                return provisional
            }
            writeRecipe(recipe, id)
            if let jpeg, publishThumbnail(jpeg, for: id, prepared: prepared) {
                if shots.first?.id == id { recent = (dst, recipe.crop, recipe.baseExposure, Look.sceneReferred(recipe), guide, analysis) }
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
        if isRaw { r.baseExposure = -Look.rawCompensation }
        writeRecipe(r, id)
        let rendered = await renderThumb(id, r)
        savingIDs.remove(id)
        if !rendered { reload() }
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

    /// The recipe, migrated to the current engine if needed (once, saved). Engine 1 recipes keep their look, sliders, crop
    /// and grain; a fitted preview match is replaced by the file's own exposure normalization. The engine 1 JSON is kept
    /// beside the original (`<id>.engine1.json`), so nothing about the old rendering is lost.
    func load(_ id: String) async -> Recipe {
        if let pending = pendingRecipes[id] { return await pending.value }
        var r = recipe(id)
        let url = raw(id)
        guard r.engine < Recipe.engine || r.pendingCaptureExposure == true,
              fm.fileExists(atPath: url.path) else { return r }
        if r.engine < Recipe.engine {
            let backup = dir.appending(path: "\(id).engine1.json")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: recipeURL(id), to: backup) }
        }
        if r.needsExposure || r.pendingCaptureExposure == true {
            let original = r
            let exposure = await Self.develop {
                guard url.pathExtension == "dng", !Look.isProRAW(url) else { return 0.0 }
                return -Look.rawCompensation - Look.captureBias(url)
            }
            let current = recipe(id)
            guard current == original else { return current }
            r.baseExposure = exposure
        }
        // Engine 3: revision 2 develops ProRAW from scene light, so it needs the file's exposure normalization (Apple's
        // metering, Look.proRAWExposure). Revision ≤ 1 ignores baseExposure for ProRAW, so old renderings don't change.
        if r.engine < 3, url.pathExtension.lowercased() == "dng" {
            let original = r
            let exposure = await Self.develop { Look.isProRAW(url) ? Look.startingExposure(url, captured: true) : nil }
            let current = recipe(id)
            guard current.lookRevision == original.lookRevision, current.filter == original.filter else { return current }
            if let exposure { r.baseExposure = exposure }
        }
        guard fm.fileExists(atPath: url.path) else { return r }
        r.pendingCaptureExposure = nil
        r.needsExposure = false
        r.engine = Recipe.engine
        writeRecipe(r, id)
        return r
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

    /// Leaving the editor: refresh the thumbnail from the saved recipe.
    func refreshThumbnail(_ id: String) async {
        guard !Task.isCancelled else { return }
        guard fm.fileExists(atPath: raw(id).path) else { return }
        guard !savingIDs.contains(id), thumbnailNeedsRefresh(id),
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

    func delete(_ id: String) {
        if recent?.url == raw(id) { recent = nil }
        try? fm.removeItem(at: currentThumb(id))
        for version in [28, 27, 25, 24] { try? fm.removeItem(at: dir.appending(path: "\(id).v\(version).jpg")) }
        try? fm.removeItem(at: Look.shutterURL(for: raw(id)))
        try? fm.removeItem(at: Look.previewURL(for: raw(id)))
        for ext in ["dng", "heic", "jpg", "json", "engine1.json"] { try? fm.removeItem(at: dir.appending(path: "\(id).\(ext)")) }
        reload()
    }

    private func reload() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let published = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) })
        shots = files
            .filter { ["dng", "heic"].contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !savingIDs.contains($0) || published[$0] != nil }
            .sorted(by: >)
            .map { id in
                if savingIDs.contains(id), let shot = published[id] { return shot }
                let mtime = (try? fm.attributesOfItem(atPath: thumb(id).path)[.modificationDate] as? Date) ?? .distantPast
                return Shot(id: id, version: mtime)
            }
    }

    func developed(_ url: URL, recipe: Recipe, priority: Operation.QueuePriority = .high) async -> (CIImage, Look.Analysis)? {
        let scene = Look.sceneReferred(recipe)
        let key = DevelopmentKey(url: url, crop: recipe.crop, exposure: recipe.baseExposure, scene: scene)
        if let recent, recent.url == url, recent.crop == recipe.crop, recent.exposure == recipe.baseExposure, recent.scene == scene {
            return (recent.image, recent.analysis)
        }
        if let task = developments[key] { return await task.value }
        guard !Task.isCancelled else { return nil }
        let task = Task { await Self.develop(priority: priority) { Look.photo(url, recipe: recipe, maxSide: Look.guideSide) } }
        developments[key] = task
        let photo = await task.value
        if let (base, analysis) = photo, shots.first?.id == url.deletingPathExtension().lastPathComponent {
            recent = (url, recipe.crop, recipe.baseExposure, scene, base, analysis)
        }
        developments[key] = nil
        return photo
    }

    private func renderThumb(_ id: String, _ recipe: Recipe) async -> Bool {
        let src = raw(id)
        guard fm.fileExists(atPath: src.path), let (base, analysis) = await developed(src, recipe: recipe, priority: .low), !Task.isCancelled else { return false }
        let data = await Self.develop(priority: .low) {
            Look.jpeg(Look.apply(recipe, to: Look.fit(base, 600), analysis: analysis, source: src))
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
