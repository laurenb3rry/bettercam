import CoreImage
import Foundation
import ImageIO
import os

/// Opt-in capture diagnostics for preview/still calibration (research/v1/redevelopment §8).
/// Off by default; enable with the launch argument `-diagnostic-capture YES` (Xcode scheme). Writes only to
/// Documents/Diagnostics/, never read by the gallery, editor or export. Keeps the newest `limit` captures.
enum Diagnostics {
    static let enabled = UserDefaults.standard.bool(forKey: "diagnostic-capture")
    static let limit = 20
    static let minimumFreeMB = 1500
    static let directory = URL.documentsDirectory.appending(path: "Diagnostics")
    private static let log = Logger(subsystem: "bettercam", category: "diagnostics")
    private static let queue = DispatchQueue(label: "diagnostics", qos: .utility)

    /// Everything known at the shutter, before the still is developed.
    struct Capture {
        var ungraded: CGImage?          // last ISP video frame, after crop/scale, before the look
        var graded: CGImage?            // the same frame as the viewfinder showed it
        var info: [String: Any]         // JSON-safe telemetry
    }

    /// Last viewfinder frame state (video queue).
    struct Frame {
        let ungraded: CGImage, graded: CGImage
        let pts: Double, uptime: TimeInterval
        let info: [String: Any]
    }

    /// Plain JSON-safe copy of ImageIO/AVFoundation values.
    static func plain(_ v: Any?) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues { plain($0) }
        case let a as [Any]: return a.map { plain($0) }
        case let n as NSNumber: return n.doubleValue.isFinite ? n : "\(n)"
        case let s as String: return s
        case nil: return NSNull()
        default: return String(describing: v!)
        }
    }

    /// Called once the still's recipe is final. Runs off the capture path; failures only log.
    static func save(_ capture: Capture, source: URL, libraryID: String, recipe: Recipe, guide: CIImage) {
        queue.async {
            let folder = directory.appending(path: "\(libraryID)")
            let fm = FileManager.default
            guard let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage, free / 1_048_576 > minimumFreeMB else {
                return log.error("diagnostic capture skipped: low storage")
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                // Hard link: the original DNG without a second copy.
                try? fm.linkItem(at: source, to: folder.appending(path: "original.\(source.pathExtension)"))
                var info = capture.info
                info["libraryID"] = libraryID
                info["recipe"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)))
                info["renderer"] = ["description": Look.rendererDescription, "lookVersion": Look.version,
                                    "gradeRevision": Grade.revision, "recipeVersion": Recipe.current, "engine": Recipe.engine]
                info["stillRender"] = ["captureCorrectionEV": recipe.baseExposure, "userEV": recipe.exposure,
                                       "guide": "\(Int(guide.extent.width))x\(Int(guide.extent.height))"]
                if let raw = CIRAWFilter(imageURL: source) {
                    info["stillDecode"] = ["nativeSize": "\(Int(raw.nativeSize.width))x\(Int(raw.nativeSize.height))",
                                           "asShotCCT": raw.neutralTemperature, "asShotTint": raw.neutralTint,
                                           "neutralChromaticity": "\(raw.neutralChromaticity)"]
                }
                for (name, image) in [("preview-ungraded", capture.ungraded), ("preview-graded", capture.graded)] {
                    if let image, let d = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).png") as CFURL,
                                                                           "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, image, nil)
                        CGImageDestinationFinalize(d)
                    }
                }
                // The finished full-resolution photograph, through the production export path.
                let start = ProcessInfo.processInfo.systemUptime
                let ok = Look.writeJPEG(source, recipe: recipe, to: folder.appending(path: "still.jpg"))
                info["stillExport"] = ["ok": ok, "seconds": ProcessInfo.processInfo.systemUptime - start,
                                       "footprintMB": Look.footprintMB()]
                let json = try JSONSerialization.data(withJSONObject: plain(info), options: [.prettyPrinted, .sortedKeys])
                try json.write(to: folder.appending(path: "capture.json"))
                prune()
                log.notice("diagnostic capture saved \(libraryID, privacy: .public)")
            } catch {
                log.error("diagnostic capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func prune() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for old in sorted.dropFirst(limit) { try? fm.removeItem(at: old) }
    }
}
