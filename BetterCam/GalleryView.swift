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
    @State private var opened: Library.Shot?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(library.shots) { shot in
                        Button {
                            if selecting {
                                if selected.remove(shot.id) == nil { selected.insert(shot.id) }
                            } else {
                                opened = shot
                            }
                        } label: {
                            Thumb(url: library.thumb(shot.id), version: shot.version)
                                .overlay(alignment: .bottomTrailing) {
                                    if selecting {
                                        Image(systemName: selected.contains(shot.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .background(.black.opacity(0.4), in: Circle())
                                            .padding(6)
                                    }
                                }
                                .task(id: shot.version) { await library.refreshThumbnail(shot.id) }
                        }
                        .buttonStyle(.plain)
                        .disabled(saving)
                        .accessibilityLabel("Photo")
                        .accessibilityAddTraits(selected.contains(shot.id) ? .isSelected : [])
                    }
                }
            }
            .overlay {
                if library.shots.isEmpty, library.processingCaptures == 0 {
                    ContentUnavailableView("No photos yet", systemImage: "camera.aperture")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Button { Task { await saveSelection() } } label: {
                            if saving { ProgressView() }
                            else { Label("Save to Photos", systemImage: "square.and.arrow.up") }
                        }
                        Spacer()
                        Text("\(selected.count) selected").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete selected photos")
                    }
                    .disabled(selected.isEmpty || saving)
                    .padding()
                    .background(.regularMaterial)
                } else if library.processingCaptures > 0 {
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
            .fullScreenCover(item: $opened) { shot in
                PhotoBrowser(id: shot.id).environmentObject(library)
            }
            .interactiveDismissDisabled(saving)
            .alert("Delete \(selected.count) photos?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    let failed = library.delete(selected)
                    selected = failed
                    if failed.isEmpty { selecting = false }
                    else { message = "Couldn't delete \(failed.count) photos." }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also deletes their originals from BetterCam.")
            }
            .alert(message ?? "", isPresented: Binding { message != nil } set: { if !$0 { message = nil } }) {
                Button("OK") {}
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "camera") }.disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button("Cancel") { selected.removeAll(); selecting = false }.disabled(saving)
                    } else {
                        Button("Select") { selecting = true }.disabled(library.shots.isEmpty || importing)
                    }
                }
                if !selecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(selection: $picks, maxSelectionCount: 30, matching: .images) {
                            if importing { ProgressView() }
                            else { Image(systemName: "plus") }
                        }
                        .disabled(importing)
                    }
                }
            }
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    importing = true
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let source = CGImageSourceCreateWithData(data as CFData, nil)
                        let format = source.flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
                        await library.importPhoto(data, format: format)
                    }
                    picks = []
                    importing = false
                }
            }
        }
    }
    private func saveSelection() async {
        guard !saving, !selected.isEmpty else { return }
        saving = true
        defer { saving = false }
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        do {
            try await PhotoExport.authorize()
            for shot in library.shots where selected.contains(shot.id) {
                let recipe = await library.load(shot.id)
                files.append(try await PhotoExport.render(library.raw(shot.id), recipe: recipe))
            }
            guard files.count == selected.count else { throw PhotoExport.Failure.missing }
            try await PhotoExport.save(files)
            selected.removeAll()
            selecting = false
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PhotoBrowser: View {
    @State var id: String
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PhotoView(id: id, close: { dismiss() }, browse: browse)
                .id(id)
        }
    }

    private func browse(_ offset: Int) {
        let shots = library.shots
        guard let index = shots.firstIndex(where: { $0.id == id }),
              shots.indices.contains(index + offset) else { return }
        id = shots[index + offset].id
    }
}

private enum PhotoSwipe {
    case previous, next, close

    init?(translation: CGPoint) {
        let x = translation.x, y = translation.y
        if abs(x) > max(45, abs(y)) {
            self = x < 0 ? .next : .previous
        } else if y > max(45, abs(x)) {
            self = .close
        } else {
            return nil
        }
    }
}

struct PhotoView: View {
    let id: String
    let close: () -> Void
    let browse: (Int) -> Void
    @EnvironmentObject private var library: Library
    @State private var recipe = Recipe()
    /// The photo's one development (guide-size base + analysis), shared by every look, slider, tile and export.
    @State private var base: Task<CIImage?, Never>?
    @State private var deleted = false
    @State private var image: UIImage?
    @State private var displayedRecipe: Recipe?
    @State private var fullSize: CGSize?
    @State private var loaded = false
    @State private var tool = Tool.film
    @State private var exporting = false
    @State private var savedRecipe: Recipe?
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

    private var regradeExposure: Double {
        // Engine 3 included a fixed +1 EV in RAW decode, paired with the saved normalization.
        recipe.engine == 3 && library.raw(id).pathExtension == "dng" ? recipe.baseExposure + Look.rawCompensation : 0
    }

    private var canExport: Bool {
        recipe.profile != nil && !exporting && !deleted && image != nil && displayedRecipe == recipe
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let photo = image ?? quickImage {
                    ZoomableImage(image: photo, fullSize: displayedRecipe == nil ? nil : fullSize,
                                  token: displayedRecipe, detail: detail, swipe: swipe)
                } else {
                    Group {
                        if loaded, recipe.profile == nil {
                            ContentUnavailableView("Saved grade unavailable", systemImage: "photo",
                                description: Text("Choose a V1 look to develop the original."))
                        } else if missing {
                            ContentUnavailableView("Can't open this photo", systemImage: "exclamationmark.triangle",
                                description: Text("Its original file is missing or unreadable."))
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onEnded {
                        if let direction = PhotoSwipe(translation: CGPoint(x: $0.translation.width, y: $0.translation.height)) {
                            swipe(direction)
                        }
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                switch tool {
                case .film:
                    filterStrip
                case .tone:
                    Group {
                        slider("Exposure", $recipe.exposure, Recipe.exposureRange)
                        slider("Contrast", $recipe.contrast, Recipe.contrastRange)
                    }.disabled(recipe.profile == nil)
                case .color:
                    if recipe.profile == nil {
                        Text("Choose a V1 look to edit this photo.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if recipe.isSilver {
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
                Text("\(Int(fullSize.width)) × \(Int(fullSize.height)) · \(library.raw(id).pathExtension == "heic" ? "HEIC" : "RAW")")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: close) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back to Gallery")
                    .disabled(exporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await export(share: false) } } label: {
                    if exporting { ProgressView() }
                    else { Image(systemName: savedRecipe == recipe ? "checkmark" : "square.and.arrow.up") }
                }
                .accessibilityLabel(savedRecipe == recipe ? "Saved to Photos" : "Save to Photos")
                .disabled(!canExport || savedRecipe == recipe)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await export(share: true) } } label: {
                        Label("Share edited photo…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!canExport)
                    ShareLink(item: library.raw(id)) {
                        Label(library.raw(id).pathExtension == "dng" ? "Share RAW (DNG)" : "Share original", systemImage: "doc")
                    }
                    Button("Reset edits") { recipe.resetSliders() }
                        .disabled(!loaded || exporting || recipe.profile == nil)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .alert("Delete this photo?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if library.delete([id]).isEmpty {
                    deleted = true
                    close()
                } else {
                    message = "Couldn't delete this photo."
                }
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
            guard new.profile != nil else { return }
            if old.profile == nil { base = nil }
            guard library.store(new, for: id) else {
                recipe = library.recipe(id)
                return
            }
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
            if recipe.profile == nil {
                Text("Saved grade · Choose a V1 look to regrade")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Filter.all) { f in
                        let on = recipe.profile != nil && recipe.filter == f.id
                        Button {
                            if !on {
                                var updated = recipe
                                if recipe.profile == nil {
                                    updated = Recipe(filter: f.id, crop: recipe.crop)
                                    updated.baseExposure = regradeExposure
                                } else {
                                    updated.filter = f.id
                                }
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
    private func developed() async -> CIImage? {
        if let base { return await base.value }
        let url = library.raw(id), r = recipe
        let task = Task { await library.developed(url, recipe: r) }
        base = task
        return await task.value
    }

    private func renderPreviews() async {
        let url = library.raw(id)
        var tile = recipe.profile == nil ? Recipe(filter: Filter.all[0].id, crop: recipe.crop) : recipe
        if recipe.profile == nil { tile.baseExposure = regradeExposure }
        tile.resetSliders()
        guard let base = await library.developed(url, recipe: tile) else { return }
        let small = Look.fit(base, 160)
        for filter in Filter.all {
            guard !Task.isCancelled, !deleted else { return }
            tile.filter = filter.id
            let recipe = tile
            let thumbnail = await Task.detached(priority: .utility) {
                Look.apply(recipe, to: small).flatMap(Look.uiImage)
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
        while !deleted {
            let r = recipe
            var rendered: UIImage?
            if r.profile != nil, let base = await developed() {
                guard r == recipe else { continue }
                rendered = await Task.detached(priority: .userInitiated) {
                    Look.apply(r, to: base).flatMap(Look.uiImage)
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
        guard let r = displayedRecipe, let full = fullSize else { return nil }
        let url = library.raw(id)
        let ci = CGRect(x: rect.minX, y: full.height - rect.maxY, width: rect.width, height: rect.height)
        return await Task.detached(priority: .userInitiated) {
            Look.renderDetail(url, recipe: r, rect: ci, scale: scale).map { UIImage(cgImage: $0) }
        }.value
    }

    private func swipe(_ direction: PhotoSwipe) {
        guard !exporting else { return }
        switch direction {
        case .previous: browse(-1)
        case .next: browse(1)
        case .close: close()
        }
    }

    private func export(share: Bool) async {
        guard canExport else { return }
        exporting = true
        defer { exporting = false }
        let r = recipe, url = library.raw(id)
        do {
            if !share { try await PhotoExport.authorize() }
            let file = try await PhotoExport.render(url, recipe: r)
            if share {
                shareURL = file
            } else {
                defer { try? FileManager.default.removeItem(at: file) }
                try await PhotoExport.save([file])
                savedRecipe = r
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

@MainActor private enum PhotoExport {
    enum Failure: LocalizedError {
        case legacy
        case missing, render, permission

        var errorDescription: String? {
            switch self {
            case .legacy: "Choose a V1 look before exporting a photo with a saved V0 grade."
            case .missing: "An original photo file is missing."
            case .render: "Couldn't render the photo. Try again."
            case .permission: "Allow Photos access in Settings › bettercam to export."
            }
        }
    }

    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.permission }
    }

    static func render(_ url: URL, recipe: Recipe) async throws -> URL {
        let file = Library.exportDir.appending(path: "bettercam-\(UUID().uuidString).jpg")
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard recipe.profile != nil else { throw Failure.legacy }
            guard fm.fileExists(atPath: url.path) else { throw Failure.missing }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Look.writeJPEG(url, recipe: recipe, to: file) else {
                try? fm.removeItem(at: file)
                throw Failure.render
            }
            return file
        }.value
    }

    static func save(_ files: [URL]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
        }
    }
}

/// The finished photograph, pinch- and double-tap-zoomable. Beyond the display image's own resolution it asks for the
/// visible region at native resolution and lays it exactly over the same spot, so zooming shows real sensor detail in
/// the same color and tone. A new `token` (recipe) drops the old detail.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let fullSize: CGSize?
    let token: Recipe?
    let detail: (CGRect, CGFloat) async -> UIImage?
    let swipe: (PhotoSwipe) -> Void

    func makeUIView(context: Context) -> ZoomView { ZoomView() }
    func updateUIView(_ v: ZoomView, context: Context) {
        v.fullSize = fullSize
        v.detail = detail
        v.swipe = swipe
        v.show(image, token: token)
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let content = UIView(), base = UIImageView(), tile = UIImageView()
        var fullSize: CGSize?
        var detail: ((CGRect, CGFloat) async -> UIImage?)?
        var swipe: ((PhotoSwipe) -> Void)?
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
            let browse = UIPanGestureRecognizer(target: self, action: #selector(navigate))
            browse.maximumNumberOfTouches = 1
            browse.delegate = self
            addGestureRecognizer(browse)
            panGestureRecognizer.require(toFail: browse)
        }
        required init?(coder: NSCoder) { fatalError() }

        func show(_ image: UIImage, token: Recipe?) {
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

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer !== panGestureRecognizer, gestureRecognizer is UIPanGestureRecognizer {
                return zoomScale <= minimumZoomScale + 0.001
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        @objc private func navigate(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, let direction = PhotoSwipe(translation: gesture.translation(in: self)) else { return }
            swipe?(direction)
        }

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
