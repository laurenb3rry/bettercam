import SwiftUI

struct CameraView: View {
    @StateObject private var camera = Camera()
    @StateObject private var library = Library()
    @AppStorage("lastLens") private var lastLens = ""
    @AppStorage("cameraFilter") private var filterID = Filter.all[0].id
    @State private var showGallery = false
    @State private var showName = false

    var body: some View {
        VStack(spacing: 20) {
            PreviewView(camera: camera) { camera.focus(at: $0) }
                .scaleEffect(camera.current?.crop ?? 1) // 2× preview = the crop the photo will get
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // swipe left/right through the film looks, like Instagram story filters
                .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                    guard abs(g.translation.width) > abs(g.translation.height) else { return }
                    let all = Filter.all, i = all.firstIndex { $0.id == filterID } ?? 0
                    let next = g.translation.width < 0 ? min(i + 1, all.count - 1) : max(i - 1, 0)
                    if next != i { filterID = all[next].id }
                })
                .overlay(alignment: .top) { filterBadge }

            HStack(spacing: 12) {
                if camera.current?.isFront != true {
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
                    Thumb(url: library.shots.first.map { library.thumb($0.id) })
                        .id(library.shots.first)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                Button { camera.capture() } label: {
                    Circle().fill(.white).frame(width: 66, height: 66)
                        .padding(5).overlay(Circle().stroke(.white, lineWidth: 3))
                        .opacity(camera.busy ? 0.4 : 1)
                }
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
            camera.filter = id
            withAnimation(.easeOut(duration: 0.15)) { showName = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeIn(duration: 0.4)) { showName = false }
            }
        }
        .task {
            camera.onCapture = { shot in Task { @MainActor in await library.add(shot) } }
            camera.start(preferred: lastLens)
        }
        .onChange(of: camera.current) { _, stop in if let stop { lastLens = stop.id } }
        .onChange(of: showGallery) { _, open in camera.paused = open }
        .alert("bettercam", isPresented: Binding { camera.error != nil } set: { if !$0 { camera.error = nil } }) {
            Button("OK") {}
        } message: {
            Text(camera.error ?? "")
        }
    }
}

extension CameraView {
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

struct Thumb: View {
    let url: URL?

    var body: some View {
        Rectangle().fill(.white.opacity(0.08))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url, let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}
