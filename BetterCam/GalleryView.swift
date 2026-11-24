import os
import Photos
import PhotosUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct GalleryView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(library.shots) { shot in
                        NavigationLink(value: shot.id) {
                            Thumb(url: library.thumb(shot.id), version: shot.version)
                                .task(id: shot.version) { await library.refreshThumbnail(shot.id) }
                        }
                    }
                }
            }
            .overlay {
                if library.shots.isEmpty, library.processingCaptures == 0 {
                    ContentUnavailableView("No photos yet", systemImage: "camera.aperture")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if library.processingCaptures > 0 {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Developing photo")
                    }
                    .font(.footnote)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { PhotoView(id: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "camera") }
                }
                ToolbarItem(placement: .topBarTrailing) { // import photos to apply the film looks after the fact
                    PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .images) {
                        if importing { ProgressView() } else { Image(systemName: "plus") }
                    }
                    .disabled(importing)
                }
            }
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    importing = true
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let types = item.supportedContentTypes
                        await library.importPhoto(data,
                                                  isRaw: types.contains { $0.conforms(to: .rawImage) },
                                                  isHEIC: types.first?.conforms(to: .heic) == true)
                    }
                    picks = []
                    importing = false
                }
            }
        }
    }
}

struct PhotoView: View {
    let id: String
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var recipe = Recipe()
    /// The photo's one development (guide-size base + analysis), shared by every look, slider, tile and export.
    @State private var base: Task<(CIImage, Look.Analysis)?, Never>?
    @State private var deleted = false
    @State private var image: UIImage?
    @State private var displayedRecipe: Recipe?
    @State private var fullSize: CGSize?
    @State private var loaded = false
    @State private var tool = Tool.film
    @State private var exporting = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var rendering = false
    @State private var missing = false
    @State private var shareURL: URL?

    enum Tool: String, CaseIterable { case film = "Look", tone = "Tone", color = "Color" }
    @State private var previews: [String: UIImage] = [:]
    @State private var thumbnail: UIImage?
    private var shotVersion: Date? { library.shots.first { $0.id == id }?.version }
    private var quickImage: UIImage? {
        thumbnail ?? Thumb.cachedImage(for: library.thumb(id), version: shotVersion)
    }

    private var canExport: Bool {
        !exporting && !deleted && image != nil && displayedRecipe == recipe
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let image, let shown = displayedRecipe {
                    ZoomableImage(image: image, fullSize: fullSize, token: shown, detail: detail)
                } else if missing {
                    ContentUnavailableView("Can't open this photo", systemImage: "exclamationmark.triangle",
                                           description: Text("Its original file is missing or unreadable."))
                } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                switch tool {
                case .film:
                    filterStrip
                case .tone:
                    slider("Exposure", $recipe.exposure, Recipe.exposureRange)
                    slider("Contrast", $recipe.contrast, Recipe.contrastRange)
                case .color:
                    if recipe.selectedFilter.grade.monochrome {
                        Text("Color adjustments are available with color looks.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        slider("Warmth", $recipe.warmth, Recipe.warmthRange)
                        slider("Saturation", $recipe.saturation, Recipe.saturationRange)
                    }
                }
            }
            .frame(height: 150, alignment: .top)
            .disabled(!loaded || exporting)
            if let fullSize {
                Text("\(Int(fullSize.width)) × \(Int(fullSize.height)) · \(library.raw(id).pathExtension == "dng" ? "RAW" : "HEIC")")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await export(share: false) } } label: { Label("Save to Photos", systemImage: "photo.badge.arrow.down") }
                    Button { Task { await export(share: true) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                } label: {
                    if exporting { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                }
                .disabled(!canExport)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: library.raw(id)) {
                        Label(library.raw(id).pathExtension == "dng" ? "Share RAW (DNG)" : "Share original", systemImage: "doc")
                    }
                    Button("Reset edits") { recipe.resetSliders() }.disabled(!loaded || exporting)
                    if loaded {
                        // previous = revision 1 (Apple ProRAW profile + rev 27 grade); current = revision 2 engine
                        Button(recipe.lookRevision < Filter.revision ? "Use current rendering" : "Use previous rendering") {
                            recipe.lookRevision = recipe.lookRevision < Filter.revision ? Filter.revision : 1
                        }.disabled(exporting)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .alert("Delete this photo?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                deleted = true
                library.delete(id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The RAW original is removed too.")
        }
        .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {
            Button("OK") {}
        }
        .task(id: shotVersion) {
            let image = await Thumb.loadImage(for: library.thumb(id), version: shotVersion)
            if !Task.isCancelled { thumbnail = image }
        }
        .task {
            let start = ProcessInfo.processInfo.systemUptime
            recipe = await library.load(id)
            guard !Task.isCancelled else { return }
            loaded = true
            let url = library.raw(id), crop = recipe.crop
            let size = Task.detached(priority: .userInitiated) { Look.outputSize(url, crop: crop) }
            async let tiles: Void = renderPreviews()
            await render()
            if image != nil { diag.info("gallery open to image \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms") }
            fullSize = await size.value
            await tiles
        }
        .onChange(of: recipe) { old, new in
            guard loaded, !deleted else { return }
            if Look.sceneReferred(old) != Look.sceneReferred(new) { base = nil } // another development, not another grade
            library.store(recipe, for: id)
            let start = ProcessInfo.processInfo.systemUptime
            let changed = recipe
            Task {
                await render()
                if image != nil, displayedRecipe == changed {
                    diag.info("edit to image \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
                }
            }
        }
        .sheet(item: $shareURL) { ShareSheet(url: $0) }
        .onDisappear {
            base = nil // release the development; the thumbnail pass re-reads the recipe
            guard loaded, !deleted else { return }
            library.store(recipe, for: id)
            Task { await library.refreshThumbnail(id) }
        }
    }

    private func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
        }
    }

    /// VSCO-style strip: each tile shows *this* photo in that film look. Tap to apply.
    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !Filter.all.contains(recipe.selectedFilter) {
                Text("\(recipe.selectedFilter.name) · Saved look")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Filter.all) { f in
                        let on = recipe.selectedFilter == f
                        Button {
                            if !on {
                                var updated = recipe
                                updated.filter = f.id
                                updated.lookRevision = Filter.revision
                                recipe = updated
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let p = previews[f.id] ?? quickImage ?? image { Image(uiImage: p).resizable().scaledToFill() } else { Color.white.opacity(0.08) }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.accentColor : .clear, lineWidth: 2))
                                Text(f.name).font(.caption2).foregroundStyle(on ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The development, once per open photo (look-independent: changing the look never re-decodes).
    private func developed() async -> (CIImage, Look.Analysis)? {
        if let base { return await base.value }
        let url = library.raw(id), r = recipe
        let task = Task { await library.developed(url, recipe: r) }
        base = task
        return await task.value
    }

    private func renderPreviews() async {
        var r = recipe
        let url = library.raw(id)
        r.lookRevision = Filter.revision // the picker always shows the current looks, so their development
        let current = Look.sceneReferred(r) == Look.sceneReferred(recipe)
        guard let (base, analysis) = current ? await developed() : await library.developed(url, recipe: r) else { return }
        var tile = r
        tile.resetSliders()
        let small = Look.fit(base, 160)
        for filter in Filter.all {
            guard !Task.isCancelled, !deleted else { return }
            tile.filter = filter.id
            let recipe = tile
            let thumbnail = await Task.detached(priority: .utility) {
                Look.uiImage(Look.apply(recipe, to: small, analysis: analysis, source: url))
            }.value
            guard !Task.isCancelled, !deleted else { return }
            previews[filter.id] = thumbnail
        }
    }

    /// Only the latest recipe's finished image is ever shown: a render overtaken by a newer edit is dropped.
    private func render() async {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        let url = library.raw(id)
        while !deleted {
            let r = recipe
            var rendered: UIImage?
            if let (base, analysis) = await developed() {
                guard r == recipe else { continue }
                rendered = await Task.detached(priority: .userInitiated) {
                    Look.uiImage(Look.apply(r, to: base, analysis: analysis, source: url))
                }.value
            }
            guard r == recipe else { continue }
            guard !deleted else { return }
            image = rendered
            missing = rendered == nil
            displayedRecipe = rendered == nil ? nil : r
            return
        }
    }

    /// Native-resolution pixels for the zoomed region (`rect` in output pixels, top-left origin), same recipe and analysis.
    private func detail(_ rect: CGRect, _ scale: CGFloat) async -> UIImage? {
        guard let r = displayedRecipe, let full = fullSize, let (_, analysis) = await developed() else { return nil }
        let url = library.raw(id)
        let ci = CGRect(x: rect.minX, y: full.height - rect.maxY, width: rect.width, height: rect.height)
        return await Task.detached(priority: .userInitiated) {
            Look.renderDetail(url, recipe: r, analysis: analysis, rect: ci, scale: scale).map { UIImage(cgImage: $0) }
        }.value
    }

    /// Save to Photos and Share: the finished photograph developed from the original at native resolution, with the
    /// editor's own analysis, so it is the rendering on screen. The original is only read, never written.
    private func export(share: Bool) async {
        guard canExport else { return }
        exporting = true
        defer { exporting = false }
        let t0 = Date()
        let r = recipe, url = library.raw(id)
        guard FileManager.default.fileExists(atPath: url.path) else { message = "This photo's original file is missing."; return }
        let analysis = await developed()?.1
        let file = Library.exportDir.appending(path: "bettercam-\(id)-\(UUID().uuidString).jpg")
        let written = await Task.detached(priority: .userInitiated) {
            do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { return false }
            return Look.writeJPEG(url, recipe: r, analysis: analysis, to: file)
        }.value
        guard written else {
            try? FileManager.default.removeItem(at: file)
            message = "Couldn't render the photo. Try again."
            return
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        diag.info("export JPEG ready in \(Date().timeIntervalSince(t0)) s, \(size) bytes, footprint \(Look.footprintMB()) MB")
        if share {
            shareURL = file
            return
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow Photos access in Settings › bettercam to export."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            message = "Saved to Photos."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The finished photograph, pinch- and double-tap-zoomable. Beyond the display image's own resolution it asks for the
/// visible region at native resolution and lays it exactly over the same spot, so zooming shows real sensor detail in
/// the same color and tone. A new `token` (recipe) drops the old detail.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let fullSize: CGSize?
    let token: Recipe
    let detail: (CGRect, CGFloat) async -> UIImage?

    func makeUIView(context: Context) -> ZoomView { ZoomView() }
    func updateUIView(_ v: ZoomView, context: Context) {
        v.fullSize = fullSize
        v.detail = detail
        v.show(image, token: token)
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        let content = UIView(), base = UIImageView(), tile = UIImageView()
        var fullSize: CGSize?
        var detail: ((CGRect, CGFloat) async -> UIImage?)?
        private var token: Recipe?
        private var request: Task<Void, Never>?
        private var laidOut = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1; maximumZoomScale = 10
            showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            base.contentMode = .scaleAspectFit
            tile.contentMode = .scaleToFill
            tile.isHidden = true
            content.addSubview(base); content.addSubview(tile); addSubview(content)
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
            tap.numberOfTapsRequired = 2
            addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { fatalError() }

        func show(_ image: UIImage, token: Recipe) {
            if base.image !== image { base.image = image }
            if token != self.token { self.token = token; clearTile(); refreshDetail() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != laidOut, zoomScale == 1 else { return }
            laidOut = bounds.size
            content.frame = CGRect(origin: .zero, size: bounds.size)
            base.frame = content.bounds
            contentSize = bounds.size
            clearTile()
        }

        /// Where the photo sits inside `content` (aspect fit).
        private var imageRect: CGRect {
            let b = content.bounds, s = base.image?.size ?? b.size
            guard s.width > 0, s.height > 0 else { return b }
            let k = min(b.width / s.width, b.height / s.height)
            let w = s.width * k, h = s.height * k
            return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { refreshDetail() }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { refreshDetail() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { refreshDetail() } }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            if zoomScale > 1 { setZoomScale(1, animated: true); return }
            let p = g.location(in: content), size = CGSize(width: bounds.width / 4, height: bounds.height / 4)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }

        private func clearTile() {
            request?.cancel()
            tile.image = nil
            tile.isHidden = true
        }

        private func refreshDetail() {
            request?.cancel()
            guard let full = fullSize, let detail, let img = base.image else { return }
            let r = imageRect, screen = window?.screen.scale ?? 3
            // only once the display image itself runs out of pixels
            guard zoomScale * r.width * screen > img.size.width * img.scale * 1.1 else { tile.isHidden = true; return }
            let visible = convert(bounds, to: content).intersection(r)
            guard !visible.isEmpty, r.width > 0 else { return }
            let k = full.width / r.width
            let native = CGRect(x: (visible.minX - r.minX) * k, y: (visible.minY - r.minY) * k,
                                width: visible.width * k, height: visible.height * k)
            let scale = min(1, visible.width * zoomScale * screen / native.width)
            let token = self.token
            request = Task { @MainActor [weak self] in
                guard let im = await detail(native, scale), !Task.isCancelled, let self, token == self.token else { return }
                self.tile.image = im
                self.tile.frame = visible
                self.tile.isHidden = false
            }
        }
    }
}

private let diag = Logger(subsystem: "bettercam", category: "diag")

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// System share sheet for the rendered JPEG (AirDrop, Messages, Save to Files…).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
