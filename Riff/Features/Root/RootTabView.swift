import RiffKit
import SwiftUI

struct RootTabView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var isShowingNowPlaying = false

    var body: some View {
        @Bindable var playback = playback

        ZStack(alignment: .bottom) {
            TabView {
                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }

            if playback.hasActiveTrack {
                MiniPlayerBar { isShowingNowPlaying = true }
                    // Sits directly above the tab bar rather than over it.
                    .padding(.bottom, 49)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: playback.hasActiveTrack)
        .fullScreenCover(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
        }
        .alert(
            "Playback problem",
            isPresented: Binding(
                get: { playback.errorMessage != nil },
                set: { if !$0 { playback.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) { playback.clearError() }
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }
}
