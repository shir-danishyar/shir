import SwiftUI

@main
struct ShirApp: App {
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
            // Both sources keep playing in the background; the hook this calls
            // is deliberately empty. It survives as the single place to
            // reinstate the App Store pause rule — see PlaybackCoordinator.
            if phase == .background {
                environment.playback.applicationDidEnterBackground()
            }
        }
    }
}
