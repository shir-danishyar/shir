import SwiftUI

@main
struct SpikeApp: App {
    @State private var controller = SpikeController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear { controller.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.didEnterBackground()
            case .active: controller.willEnterForeground()
            default: break
            }
        }
    }
}
