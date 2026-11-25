import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Every edit is a recipe applied to the untouched original, so editing is non-destructive.
struct Recipe: Codable, Equatable {
    static let current = 10
    /// Engine 5: Apple-developed ProRAW/RAW base + one authored look cube (Grade revision 5).
    static let engine = 5

    static let exposureRange = -0.7...0.7     // EV, explicit user adjustment
    static let contrastRange = -0.08...0.08
    static let warmthRange = -0.25...0.25     // ±5% R/B
    static let saturationRange = 0.88...1.12

    var version = Recipe.current
    var engine = Recipe.engine
    var filter = Filter.all[0].id
    var lookRevision = Grade.revision
    var exposure = 0.0
    var contrast = 0.0
    var warmth = 0.0
    var saturation = 1.0
    var crop = 1.0          // zoom crop set at capture (2× = center crop of the main lens)
    var baseExposure = 0.0  // capture exposure-bias compensation for Bayer RAW (ProRAW: 0)
    var grainSeed: UInt32?
    var pendingCaptureExposure: Bool?

    init() {}
    init(filter: String, crop: Double = 1) {
        self.filter = filter
        self.crop = crop
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init()
        crop = try c.decodeIfPresent(Double.self, forKey: .crop) ?? 1
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? "editorial"
        baseExposure = try c.decodeIfPresent(Double.self, forKey: .baseExposure) ?? 0
        lookRevision = try c.decodeIfPresent(Int.self, forKey: .lookRevision) ?? 0
        grainSeed = try? c.decodeIfPresent(UInt32.self, forKey: .grainSeed)
        pendingCaptureExposure = try c.decodeIfPresent(Bool.self, forKey: .pendingCaptureExposure)
        engine = try c.decodeIfPresent(Int.self, forKey: .engine) ?? 1
        guard try c.decodeIfPresent(Int.self, forKey: .version) == Recipe.current else {
            // ponytail: pre-v10 imports stored their −1 compensation in the exposure slider; carry exactly that over
            if let old = try c.decodeIfPresent(Double.self, forKey: .exposure), abs(old + Look.rawCompensation) < 1e-6 {
                baseExposure = old
            }
            return
        }
        exposure = try c.decode(Double.self, forKey: .exposure)
        contrast = try c.decode(Double.self, forKey: .contrast)
        warmth = try c.decode(Double.self, forKey: .warmth)
        saturation = try c.decode(Double.self, forKey: .saturation)
    }

    mutating func resetSliders() { exposure = 0; contrast = 0; warmth = 0; saturation = 1 }

    /// Engine-5 recipes render with the look their versioned id names: revision 6, or an archived revision-5 look.
    /// Older recipes keep their saved thumbnail ("Saved grade") until the owner picks a look; their renderer is
    /// archived at git tag v1-rev4-archive.
    var look: Grade.Look? {
        guard engine == Self.engine else { return nil }
        return Grade.Look(id: filter)
    }
    var profile: Grade.Look? { look }

    var isSilver: Bool { look?.isMono == true }
}

/// Pipeline (stills and viewfinder share `applyLook`):
///   still:   original RAW → developBase (Apple's ProRAW/RAW development, SDR, as-shot WB) ─┐
///   preview: ISP video frame (Core Image colour-managed) → adaptPreview (identity) ─────────┤
///                                                     applyLook (user adjustments + look cube, once)
///                                                     → encodeOutput (Display P3, 8-bit)
enum Look {
    // Core Image converts tagged video and RAW into this extended linear working space.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let context = CIContext(options: [.workingColorSpace: workingSpace])
    static let previewContext = CIContext(options: [.workingColorSpace: workingSpace, .cacheIntermediates: false])
    private static let exportContext = CIContext(options: [.workingColorSpace: workingSpace, .cacheIntermediates: false])
    private static let exportLock = NSLock()
    static let outputSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Bayer RAW is shot this much under (see Camera) to protect highlights; Recipe.baseExposure restores it.
    static let rawCompensation = 1.0
    /// Thumbnail file version: bump when rendering changes without recipe units changing.
    static let version = 51
    static let guideSide: CGFloat = 1200
    /// Logged at launch so the running build is identifiable.
    static var rendererDescription: String {
        "renderer=v1-look-first grade.revision=\(Grade.revision) engine=\(Recipe.engine) thumbs=v\(version) cubes="
            + Grade.Look.active.map { "\($0.rawValue):\(Grade.fingerprint($0))" }.joined(separator: ",")
    }

    static func captureBias(_ url: URL) -> Double {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return 0 }
        return exif[kCGImagePropertyExifExposureBiasValue as String] as? Double ?? 0
    }

    private static func centerCrop(_ img: CIImage, _ crop: Double) -> CIImage {
        guard crop > 1 else { return img }
        let e = img.extent
        let w = (e.width / crop).rounded(), h = (e.height / crop).rounded()
        let x = (e.midX - w / 2).rounded(), y = (e.midY - h / 2).rounded()
        return img.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    /// Render once to memory (half float, unclipped) so slider changes only re-run the look.
    static func materialize(_ img: CIImage) -> CIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: workingSpace)
            .map { CIImage(cgImage: $0).settingProperties(img.properties) }
    }

    static func isProRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
              let make = tiff[kCGImagePropertyTIFFMake as String] as? String,
              let model = tiff[kCGImagePropertyTIFFModel as String] as? String,
              let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any] else { return false }
        return make.caseInsensitiveCompare("Apple") == .orderedSame &&
            model.hasPrefix("iPhone") && dng["CFAPlaneColor"] == nil
    }

    /// developBase: Apple's own RAW development through CIRAWFilter, pinned to SDR. Defaults kept on purpose
    /// (boost, local tone map, gamut mapping, noise reduction, ProRAW fusion): side-by-side they beat every custom
    /// scene-linear development we built. As-shot white balance; no exposure normalisation; no look.
    /// Output: extended linear sRGB, display-referred, ≈[0, 1].
    static func developBase(_ url: URL, crop: Double, exposure: Double = 0, maxSide: CGFloat? = nil) -> CIImage? {
        let type = UTType(filenameExtension: url.pathExtension)
        guard url.pathExtension.lowercased() == "raw" || type?.conforms(to: .rawImage) == true else {
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
            return maxSide.map { fit(centerCrop(image, crop), $0) } ?? centerCrop(image, crop)
        }
        guard crop.isFinite, crop >= 1, exposure.isFinite, abs(exposure) < 8, let raw = CIRAWFilter(imageURL: url) else { return nil }
        if let maxSide {
            let side = max(raw.nativeSize.width, raw.nativeSize.height)
            raw.scaleFactor = Float(min(1, maxSide * crop / side))
        }
        raw.extendedDynamicRangeAmount = 0
        raw.exposure = Float(exposure)
        return raw.outputImage.map { centerCrop($0, crop) }
    }

    static func photo(_ url: URL, recipe: Recipe) -> CIImage? {
        guard recipe.look != nil,
              let decoded = developBase(url, crop: recipe.crop, exposure: recipe.baseExposure, maxSide: guideSide) else { return nil }
        return materialize(decoded)
    }

    static func normalizeCapture(_ recipe: Recipe, source: URL) -> Recipe {
        guard recipe.pendingCaptureExposure == true else { return recipe }
        var normalized = recipe
        normalized.baseExposure = isProRAW(source) ? 0 : -captureBias(source)
        normalized.pendingCaptureExposure = nil
        return normalized
    }

    static func fit(_ img: CIImage, _ side: CGFloat) -> CIImage {
        let scale = min(1, side / max(img.extent.width, img.extent.height))
        return img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// adaptPreview: Apple's processed video and Apple's developed ProRAW are both display-referred renderings
    /// of the same ISP; Core Image already linearises the video by its attached primaries, transfer function and
    /// YCbCr matrix. No measured pair justifies a correction, so the adapter is the identity (see report).
    static func adaptPreview(_ frame: CIImage) -> CIImage { frame }

    /// User adjustments, explicit and pointwise, in linear light: exposure (with a soft shoulder so +EV never
    /// hard-clips), warmth, saturation and contrast about middle grey. All defaults are exactly the identity.
    private static let adjust = CIColorKernel(source: """
    kernel vec4 adjust(__sample px, float gain, float warmth, float saturation, float contrast) {
        if (px.a <= 0.0) return px;
        vec3 c = px.rgb / px.a;
        c *= gain * vec3(exp2(0.3 * warmth), 1.0, exp2(-0.3 * warmth));
        float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
        c = vec3(y) + saturation * (c - vec3(y));
        if (y > 0.000001) {
            float t = y;
            if (contrast != 0.0) t = 0.18 * pow(y / 0.18, 1.0 + 2.5 * contrast);
            if (gain > 1.0 && t > 0.8) t = 0.8 + 0.2 * (1.0 - exp(-(t - 0.8) / 0.2));
            c *= t / y;
        }
        return vec4(c * px.a, px.a);
    }
    """)

    /// applyLook: the only creative operation, identical for viewfinder, gallery, editor and export.
    static func applyLook(_ look: Grade.Look, to image: CIImage, exposure: Double, contrast: Double,
                          warmth: Double, saturation: Double) -> CIImage? {
        guard exposure.isFinite, abs(exposure) < 8, contrast.isFinite, warmth.isFinite, saturation.isFinite else { return nil }
        var img = image
        let mono = look == .silver
        let w = mono ? 0 : warmth, s = mono ? 1 : saturation
        if exposure != 0 || contrast != 0 || w != 0 || s != 1 {
            guard let adjusted = adjust?.apply(extent: img.extent, arguments: [img, exp2(exposure), w, s, contrast]) else { return nil }
            img = adjusted
        }
        return Grade.apply(look, to: img)
    }

    /// Still/gallery/editor/export entry point. `image` is the developed base (Recipe.baseExposure already applied).
    static func apply(_ recipe: Recipe, to image: CIImage) -> CIImage? {
        guard let look = recipe.look else { return nil }
        return applyLook(look, to: image, exposure: recipe.exposure, contrast: recipe.contrast,
                         warmth: recipe.warmth, saturation: recipe.saturation)
    }

    static func shutterURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("png")
    }

    static func previewURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("isp.tiff")
    }

    static func writeJPEG(_ url: URL, recipe: Recipe, to destination: URL) -> Bool {
        exportLock.withLock {
            autoreleasepool {
                guard recipe.look != nil, let base = developBase(url, crop: recipe.crop, exposure: recipe.baseExposure),
                      let image = apply(recipe, to: base) else { return false }
                let metadata = exportProperties(source: url, recipe: recipe, renderedFrom: url.pathExtension.lowercased())
                defer { exportContext.clearCaches() }
                if image.extent.width * image.extent.height > 8_000_000 {
                    return tiledJPEG(image, metadata: metadata, to: destination)
                }
                do {
                    try exportContext.writeJPEGRepresentation(of: image.settingProperties(metadata), to: destination,
                        colorSpace: outputSpace,
                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95])
                    return true
                } catch { return false }
            }
        }
    }

    /// The same full-source rendering used by export, restricted to the requested editor region.
    static func renderDetail(_ url: URL, recipe: Recipe, rect: CGRect, scale: CGFloat) -> CGImage? {
        exportLock.withLock {
            autoreleasepool {
                guard recipe.look != nil, let base = developBase(url, crop: recipe.crop, exposure: recipe.baseExposure),
                      let image = apply(recipe, to: base) else { return nil }
                let region = rect.intersection(base.extent).integral
                guard !region.isEmpty else { return nil }
                let tile = image.cropped(to: region)
                    .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                    .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": min(1, scale)])
                defer { exportContext.clearCaches() }
                return exportContext.createCGImage(tile, from: tile.extent.integral, format: .RGBA8, colorSpace: outputSpace)
            }
        }
    }

    static func outputSize(_ url: URL, crop: Double) -> CGSize? {
        developBase(url, crop: crop)?.extent.size
    }

    private static func tiledJPEG(_ image: CIImage, metadata: [String: Any], to url: URL) -> Bool {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard let raster = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: outputSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        // One final 8-bit raster. Keep wide, high-precision filter intermediates local to each strip.
        for row in stride(from: 0, to: height, by: 1024) {
            let rows = min(1024, height - row)
            let bounds = CGRect(x: extent.minX, y: extent.minY + CGFloat(row),
                                width: CGFloat(width), height: CGFloat(rows))
            let ok = autoreleasepool {
                guard let tile = exportContext.createCGImage(image, from: bounds, format: .RGBA8,
                                                             colorSpace: outputSpace) else { return false }
                raster.draw(tile, in: CGRect(x: 0, y: row, width: width, height: rows))
                return true
            }
            guard ok else { return false }
        }
        guard let final = raster.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImage(destination, final, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func purge() {
        context.clearCaches()
        previewContext.clearCaches()
    }

    #if canImport(UIKit)
    static func uiImage(_ img: CIImage) -> UIImage? {
        context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: outputSpace).map(UIImage.init)
    }
    #endif

    /// Metadata for exported files: lens/exposure EXIF and GPS from the original, plus the look and its exact settings,
    /// so a photo can be re-rendered later. Orientation and pixel sizes are dropped (the render is already upright).
    static func exportProperties(source: URL, recipe: Recipe, renderedFrom: String) -> [String: Any] {
        let src = CGImageSourceCreateWithURL(source as CFURL, nil)
        let orig = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        var exif = orig[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = nil
        exif[kCGImagePropertyExifPixelYDimension as String] = nil
        exif[kCGImagePropertyExifColorSpace as String] = nil
        let origTIFF = orig[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let settings = (try? encoder.encode(recipe)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var tiff: [String: Any] = [
            kCGImagePropertyTIFFSoftware as String: "bettercam render \(version)",
            kCGImagePropertyTIFFImageDescription as String: "look=\(recipe.filter) source=\(renderedFrom) \(settings)",
        ]
        for k in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime] {
            tiff[k as String] = origTIFF[k as String]
        }
        var props: [String: Any] = [kCGImagePropertyExifDictionary as String: exif, kCGImagePropertyTIFFDictionary as String: tiff]
        props[kCGImagePropertyGPSDictionary as String] = orig[kCGImagePropertyGPSDictionary as String]
        return props
    }

    static func jpeg(_ img: CIImage, quality: Double = 0.85, renderer: CIContext = context) -> Data? {
        renderer.jpegRepresentation(of: img, colorSpace: outputSpace,
                                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }

    static func heif(_ img: CIImage) -> Data? {
        context.heifRepresentation(of: img, format: .RGBA8, colorSpace: outputSpace, options: [:])
    }

    // MARK: - Diagnostics (research/11-phase2-capture.md §1: device validation of the decode)

    /// Process memory as Xcode's gauge shows it (phys_footprint), MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

}
