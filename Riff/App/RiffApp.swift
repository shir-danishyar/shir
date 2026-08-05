import SwiftUI

@main
struct RiffApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(environment)
                .environment(environment.library)
                .environment(environment.playback)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            // Both sources keep playing in the background now. The hook is kept
            // because it is where the YouTube pause goes back if this app is
            // ever pointed at the App Store again — see PlaybackCoordinator.
            if phase == .background {
                environment.playback.applicationDidEnterBackground()
            }
        }
    }
}
