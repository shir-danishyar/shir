import ShirKit
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
            // The engine's web view, kept in the window — full-size but
            // invisible behind the opaque tab UI — whenever Now Playing is
            // closed. This is not decoration; both properties were measured:
            // playback cannot START outside a window (a never-parented web
            // view runs no page media at all — zero bridge messages), and a
            // 1pt host is no better, because m.youtube.com will not build a
            // player into a 1px CSS viewport (navigation commits, bridge
            // never comes up). Full-size-but-invisible is the shape that
            // works, and it is why tapping a search result plays immediately
            // instead of sitting cued until the cover is opened. Audio
            // *continues* fine unparented once audible; starting is what
            // needs this. NowPlayingView takes the view over while the cover
            // is up, so exactly one parent owns it at a time.
            // Full opacity on purpose: WebKit treats a near-transparent view
            // as invisible and stops the page, so the hiding is done by
            // occlusion — everything above this in the ZStack draws on opaque
            // black.

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
        // Starting a song opens the player, exactly as the reference app
        // does. It is also what makes playback start at all — see
        // `userPlaybackToken` in PlaybackCoordinator.
        .onChange(of: playback.userPlaybackToken) {
            isShowingNowPlaying = true
        }
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
        .onAppear {
            applyBarAppearance()
            // Test seam: a track cannot *start* unless the stage is mounted
            // (WebKit suspends silent elements in a hidden page, and every
            // track starts muted), and the cover is the only mount point —
            // so BackgroundPlaybackTests needs it open without a tap.
            if UserDefaults.standard.bool(forKey: "autoOpenNowPlaying") {
                isShowingNowPlaying = true
            }
        }
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
