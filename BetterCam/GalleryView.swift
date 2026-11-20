import os
import Photos
import PhotosUI
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
                            Thumb(url: library.thumb(shot.id)).id(shot.version)
                        }
                    }
                }
            }
            .overlay {
                if library.shots.isEmpty { ContentUnavailableView("No photos yet", systemImage: "camera.aperture") }
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
    @State private var base: CIImage?
    @State private var analysis: Look.Analysis?   // measured once per photo, so sliders stay fast
    @State private var deleted = false
    @State private var image: UIImage?
    @State private var shutterImage: UIImage?
    @State private var tool = Tool.film
    @State private var exporting = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var rendering = false
    @State private var missing = false
    @State private var shareURL: URL?

    enum Tool: String, CaseIterable { case film = "Look", tone = "Tone", color = "Color" }
    @State private var previews: [String: UIImage] = [:]

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if missing { ContentUnavailableView("Can't open this photo", systemImage: "exclamationmark.triangle",
                                                         description: Text("Its original file is missing or unreadable.")) }
                else { ProgressView() }
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
                    slider("Warmth", $recipe.warmth, Recipe.warmthRange)
                    slider("Saturation", $recipe.saturation, Recipe.saturationRange)
                }
            }
            .frame(height: 150, alignment: .top)

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
                .disabled(exporting || missing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: library.raw(id)) {
                        Label(library.raw(id).pathExtension == "dng" ? "Share RAW (DNG)" : "Share original", systemImage: "doc")
                    }
                    Button("Reset edits") { recipe.resetSliders() }
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
        .task {
            recipe = library.recipe(id)
            let url = library.raw(id), r = recipe
            if r.shutterLook != nil {
                shutterImage = UIImage(contentsOfFile: Look.shutterURL(for: url).path)
                if r.usesShutterLook { image = shutterImage }
            }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (CIImage, Look.Analysis)? in
                let t0 = Date()
                guard let (base, matchedAnalysis) = Look.photo(url, recipe: r, maxSide: 1600),
                      let b = Look.materialize(base) else { return nil }
                let a = matchedAnalysis ?? Look.analyze(b, subject: true)
                #if DEBUG
                diag.info("editor load \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s \(Look.decodeReport(b), privacy: .public) mem \(Look.footprintMB(), format: .fixed(precision: 0))MB")
                #endif
                return (b, a)
            }.value
            base = loaded?.0
            analysis = loaded?.1
            missing = loaded == nil
            await render()
            await renderPreviews()
        }
        .onChange(of: recipe) { Task { await render() } }
        .sheet(item: $shareURL) { ShareSheet(url: $0) }
        .onDisappear {
            guard !deleted else { return }
            let r = recipe
            Task { await library.save(r, for: id) }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Filter.all) { f in
                    let on = recipe.filter == f.id
                    Button {
                        if !on { recipe.filter = f.id }
                    } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let p = previews[f.id] { Image(uiImage: p).resizable().scaledToFill() } else { Color.white.opacity(0.08) }
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

    private func renderPreviews() async {
        guard let base, let analysis else { return }
        let crop = recipe.crop, base0 = recipe.baseExposure, match = recipe.previewMatch
        previews = await Task.detached(priority: .utility) {
            let s = 160 / max(base.extent.width, base.extent.height)
            let small = base.transformed(by: CGAffineTransform(scaleX: s, y: s))
            var out: [String: UIImage] = [:]
            for f in Filter.all {
                var r = Recipe(filter: f.id, crop: crop)
                r.baseExposure = base0
                r.previewMatch = match
                out[f.id] = Look.uiImage(Look.apply(r, to: small, analysis: analysis))
            }
            return out
        }.value
    }

    /// One render in flight at a time, always of the *latest* recipe. A slider fires dozens of changes per second;
    /// rendering each one queued them up and the photo crawled through stale values for many seconds.
    private func render() async {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        var r: Recipe
        repeat {
            r = recipe
            let a = analysis
            let t0 = Date()
            if r.usesShutterLook, let shutterImage {
                image = shutterImage
            } else if let base {
                image = await Task.detached(priority: .userInitiated) { Look.uiImage(Look.apply(r, to: base, analysis: a)) }.value
            } else {
                return
            }
            #if DEBUG
            diag.debug("slider render \(Date().timeIntervalSince(t0) * 1000, format: .fixed(precision: 0))ms exposure \(r.exposure)")
            #endif
        } while r != recipe
        if !deleted { library.store(r, for: id) } // settled: keep the edit even if the app is closed now
    }

    /// Export the same appearance as the editor with the original's EXIF/GPS.
    /// The original is only read, never written.
    private func export(share: Bool) async {
        exporting = true
        defer { exporting = false }
        let r = recipe, url = library.raw(id)
        guard FileManager.default.fileExists(atPath: url.path) else { message = "This photo's original file is missing."; return }
        let t0 = Date()
        let data = await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                Look.renderPhoto(url, recipe: r).flatMap { image in
                    Look.jpeg(image.settingProperties(Look.exportProperties(source: url, recipe: r)), quality: 0.95)
                }
            }
        }.value
        diag.info("export \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s \(data?.count ?? 0)B mem \(Look.footprintMB(), format: .fixed(precision: 0))MB")
        guard let data else { message = "Couldn't render this photo. Try again; if it keeps failing, restart the app."; return }
        if share {
            let file = Library.exportDir.appending(path: "bettercam-\(id).jpg")
            do {
                try FileManager.default.createDirectory(at: Library.exportDir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                shareURL = file
            } catch { message = "Couldn't prepare the photo for sharing: \(error.localizedDescription)" }
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow Photos access in Settings › bettercam to export."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            message = "Saved to Photos."
        } catch {
            message = error.localizedDescription
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
