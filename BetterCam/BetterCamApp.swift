import SwiftUI

@main
struct BetterCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Look.purge() }
        }
    }
}
