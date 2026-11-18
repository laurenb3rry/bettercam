import SwiftUI

@main
struct BetterCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
    }
}
