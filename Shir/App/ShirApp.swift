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
            // Local audio keeps going in the background; YouTube is paused here
            // deliberately. See PlaybackCoordinator for why.
            if phase == .background {
                environment.playback.applicationDidEnterBackground()
            }
        }
    }
}
