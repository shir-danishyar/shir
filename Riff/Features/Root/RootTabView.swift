import RiffKit
import SwiftUI

/// Four tabs, a mini player, and a full-screen Now Playing — the shape the
/// reference app uses, and the reason its navigation never feels lost: every
/// screen is at most two taps from playback.
struct RootTabView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var isShowingNowPlaying = false
    @State private var selection: Tab = .favorites

    enum Tab: Hashable {
        case favorites, playlists, search, more
    }

    var body: some View {
        @Bindable var playback = playback

        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                FavoritesView()
                    .tabItem { Label("My Favorites", systemImage: "heart.fill") }
                    .tag(Tab.favorites)
                PlaylistsView()
                    .tabItem { Label("Playlists", systemImage: "music.note") }
                    .tag(Tab.playlists)
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)
                MoreView()
                    .tabItem { Label("More", systemImage: "ellipsis") }
                    .tag(Tab.more)
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
        .tint(Theme.accent)
        .onAppear(perform: applyBarAppearance)
    }

    /// SwiftUI's `TabView` and `NavigationStack` still defer to UIKit's
    /// appearance proxies for the opaque dark bars this design needs. Without
    /// this both bars turn translucent over black content and lose their edge.
    private func applyBarAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.surfaceRaised)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.surface)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
