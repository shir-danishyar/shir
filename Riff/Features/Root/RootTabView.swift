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
            playerKeepAlive

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

    /// Keeps the player's web view in the window while Now Playing is closed.
    ///
    /// `NowPlayingView` is a `fullScreenCover`, so mounting the web view only
    /// there left it with no window for the whole time the user was browsing —
    /// which is most of the time, and always the case when the phone is locked
    /// from anywhere but that one screen.
    ///
    /// A web view with no window is not a *visible page* to WebKit, and WebKit
    /// publishes web media to MediaRemote itself, only for a visible page. A
    /// page it rules ineligible has its Now Playing card cleared — without its
    /// audio being paused. That is exactly the reported symptom: music keeps
    /// playing, the lock screen is empty. No amount of `MPNowPlayingInfoCenter`
    /// could have fixed it, because the app was never the one publishing.
    ///
    /// The two mounts are mutually exclusive by construction — a `UIView` has
    /// one superview, so overlapping them would have the cover silently steal
    /// the web view and leave this one blank.
    ///
    /// It is kept at the *same size* Now Playing gives it, and simply covered by
    /// the opaque `TabView` in front. Shrinking it instead — a hidden one-point
    /// parking spot is the obvious idea — resizes the web view every time the
    /// user opens or closes Now Playing, which changes `m.youtube.com`'s viewport
    /// and makes its player re-lay-out in the middle of a song. Same size in both
    /// places means moving between them costs nothing.
    ///
    /// It also must not be `hidden` or zero-alpha: WebKit reads both when it
    /// decides whether a page is visible, so hiding it properly would put us back
    /// where we started.
    @ViewBuilder
    private var playerKeepAlive: some View {
        if playback.isPlayingYouTube, !isShowingNowPlaying {
            YouTubePlayerView(webView: playback.youtubeEngine.webView)
                .aspectRatio(Theme.playerAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
