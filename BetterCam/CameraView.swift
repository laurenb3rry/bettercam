import SwiftUI

struct CameraView: View {
    @StateObject private var camera = Camera()
    @StateObject private var library = Library()
    @AppStorage("lastLens") private var lastLens = ""
    @AppStorage("cameraFilter") private var filterID = Filter.all[0].id
    @State private var showGallery = false
    @State private var showName = false
    @State private var flash = false
    @AppStorage("grid") private var grid = false
    @AppStorage("rawMode") private var rawMode = Camera.Mode.standard.rawValue
    @State private var ev = 0.0          // render exposure, vertical drag on the viewfinder
    @State private var evStart = 0.0
    @State private var blink = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            PreviewView(camera: camera) { camera.focus(at: $0) } // 2× crop is done on the frames (Camera.captureOutput)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // swipe left/right through the film looks, like Instagram story filters; up/down: exposure
                .gesture(DragGesture(minimumDistance: 30).onChanged { g in
                    guard abs(g.translation.height) > abs(g.translation.width) else { return }
                    ev = min(max(evStart - g.translation.height / 250, Recipe.exposureRange.lowerBound), Recipe.exposureRange.upperBound)
                    ev = (ev * 10).rounded() / 10
                }.onEnded { g in
                    evStart = ev
                    guard abs(g.translation.width) > abs(g.translation.height) else { return }
                    let all = Filter.all, i = all.firstIndex { $0.id == filterID } ?? 0
                    let next = g.translation.width < 0 ? min(i + 1, all.count - 1) : max(i - 1, 0)
                    if next != i { filterID = all[next].id }
                })
                .overlay { Color.black.opacity(blink ? 0.6 : 0).allowsHitTesting(false) } // capture feedback
                .overlay(alignment: .bottom) {
                    if ev != 0 { // tap to reset
                        Button { ev = 0; evStart = 0 } label: {
                            Label(String(format: "%+.1f", ev), systemImage: "sun.max")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).frame(height: 30).background(.black.opacity(0.45), in: Capsule())
                        }
                        .padding(10)
                    }
                }
                .overlay { if grid { ThirdsGrid() } }
                .overlay(alignment: .top) { filterBadge }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        if camera.flashAvailable {
                            toggle(flash ? "bolt.fill" : "bolt.slash", on: flash) { flash.toggle() }
                        }
                        toggle("grid", on: grid) { grid.toggle() }
                        formatChip
                    }
                    .padding(10)
                }

            HStack(spacing: 12) {
                if camera.selected?.isFront != true {
                    ForEach(camera.stops) { stop in
                        Button(stop.label) { camera.select(stop) }
                            .font(.footnote.weight(.medium))
                            .frame(width: 48, height: 32)
                            .foregroundStyle(stop == camera.current ? .black : .white)
                            .background(stop == camera.current ? Color.accentColor : .white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(height: 32)

            HStack {
                Button { showGallery = true } label: {
                    Thumb(url: library.shots.first.map { library.thumb($0.id) }, version: library.shots.first?.version,
                      animatedShotID: library.shots.first?.id)
                    .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                Button { camera.capture(flash: flash && camera.flashAvailable) } label: {
                    Circle().fill(.white).frame(width: 66, height: 66)
                        .padding(5).overlay(Circle().stroke(.white, lineWidth: 3))
                        .opacity(camera.busy ? 0.4 : 1)
                }
                .disabled(camera.busy)
                Spacer()
                Button { camera.flip() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .disabled(camera.front == nil)
            }
            .padding(.horizontal, 28)
        }
        .frame(maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showGallery) {
            GalleryView().environmentObject(library) // swipe down = back to camera; the session keeps running
        }
        .onChange(of: filterID, initial: true) { _, id in
            guard Filter.all.contains(where: { $0.id == id }) else {
                filterID = Filter.all[0].id
                camera.filter = filterID
                return
            }
            camera.filter = id
            withAnimation(.easeOut(duration: 0.15)) { showName = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeIn(duration: 0.4)) { showName = false }
            }
        }
        .task {
            camera.onCapture = { shot, data in await library.add(shot, data: data) }
            camera.start(preferred: lastLens, mode: Camera.Mode(rawValue: rawMode) ?? .standard)
        }
        .onChange(of: ev) { _, v in camera.exposure = v }
        .onChange(of: camera.shutterCount) {
            blink = true
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) { blink = false }
        }
        .onChange(of: scenePhase) { _, p in if p == .active { camera.resume() } }
        .onChange(of: camera.current) { _, stop in if let stop { lastLens = stop.id } }
        .onChange(of: rawMode) { _, m in camera.mode = Camera.Mode(rawValue: m) ?? .standard }
        .onChange(of: showGallery) { _, open in camera.paused = open }
        .alert("bettercam", isPresented: Binding { camera.error != nil } set: { if !$0 { camera.error = nil } }) {
            if camera.permissionDenied {
                Button("Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Button("OK") {}
        } message: {
            Text(camera.error ?? "")
        }
        .alert("bettercam", isPresented: Binding { library.message != nil && !showGallery } set: { if !$0 { library.message = nil } }) {
            Button("OK") {}
        } message: {
            Text(library.message ?? "")
        }
    }
}

extension CameraView {
    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.accentColor : .white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.35), in: Circle())
        }
    }

    /// What the next shot will actually be (checked against the file after every shot). Tap to pick the capture format;
    /// the choice is remembered and never changed by the app: an unsupported lens says so on the chip instead.
    private var formatChip: some View {
        Menu {
            Picker("Capture", selection: $rawMode) {
                ForEach(Camera.Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
        } label: {
            Text(camera.format).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 34).background(.black.opacity(0.35), in: Capsule())
        }
    }

    /// Film name flashes when you swipe; the dots always show where you are in the set.
    private var filterBadge: some View {
        VStack(spacing: 6) {
            Text(Filter.named(filterID).name)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .opacity(showName ? 1 : 0)
            HStack(spacing: 6) {
                ForEach(Filter.all) { f in
                    Circle().fill(.white.opacity(f.id == filterID ? 1 : 0.35)).frame(width: 6, height: 6)
                }
            }
        }
        .padding(.top, 14)
        .allowsHitTesting(false)
    }
}

/// Rule-of-thirds guide (doc §9: framing changes a photo more than another 3% saturation).
struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Grid/thumbnail tile. Decoded off the main thread and cached (by path + file date), so the gallery scrolls smoothly.
struct Thumb: View {
    let url: URL?
    let version: Date?
    var animatedShotID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loaded: (url: URL, image: UIImage, shotID: String?)?
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func cacheImage(_ image: UIImage, for url: URL, version: Date?) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key(for: url, version: version), cost: cost)
    }

    static func cachedImage(for url: URL, version: Date?) -> UIImage? {
        cache.object(forKey: key(for: url, version: version))
    }

    static func loadImage(for url: URL, version: Date?) async -> UIImage? {
        let key = key(for: url, version: version)
        if let hit = cache.object(forKey: key) { return hit }
        guard version != .distantPast, !Task.isCancelled else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        if let image { cacheImage(image, for: url, version: version) }
        return image
    }

    private static func key(for url: URL, version: Date?) -> NSString {
        "\(url.path)@\(version?.timeIntervalSince1970 ?? 0)" as NSString
    }

    var body: some View {
        let key = url.map { Self.key(for: $0, version: version) }
        Rectangle().fill(.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let shown = animatedShotID != nil ? loaded?.image
                    : key.flatMap({ Self.cache.object(forKey: $0) }) ?? (loaded?.url == url ? loaded?.image : nil) {
                    Image(uiImage: shown).resizable().scaledToFill()
                        .id(loaded?.shotID)
                        .transition(.asymmetric(insertion: .scale(scale: 0.05, anchor: .center), removal: .identity))
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: key) {
                guard let url else { loaded = nil; return }
                let image = await Self.loadImage(for: url, version: version)
                guard !Task.isCancelled else { return }
                if let image {
                    let animate = animatedShotID != nil && !reduceMotion && loaded?.shotID != animatedShotID
                    withAnimation(animate ? .easeOut(duration: 0.18) : nil) { loaded = (url, image, animatedShotID) }
                } else if animatedShotID == nil {
                    loaded = nil
                }
            }
    }
}
