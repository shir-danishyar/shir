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
            // The engine's web view, kept in the window — sized like the
            // stage but occluded behind the opaque tab UI — whenever Now
            // Playing is closed. Not for *starting* playback (occluded start
            // was measured to fail; the auto-open of Now Playing is that
            // fix), but for *continuing* it: WebKit treats a web view whose
            // window becomes nil as "the application entered background" and
            // pauses the media session, which on a physical device was an
            // audible dip every time the cover was dismissed to the mini
            // player. NowPlayingView takes the view over while the cover is
            // up; dismantling the cover parks it back here — every handover
            // window→window, never through nil.
            // Full size and full opacity on purpose: WebKit treats a
            // near-transparent or 1pt view as invisible and stops the page,
            // so the hiding is done by occlusion — everything above this in
            // the ZStack draws on opaque black.
            GeometryReader { proxy in
                OffstageYouTubePlayerHost(engine: playback.youtubeEngine)
                    .frame(
                        width: proxy.size.width,
                        height: (proxy.size.width / Theme.videoAspectRatio).rounded()
                    )
            }

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
            // The opaque backdrop that occludes the offstage web view, so no
            // screen's own translucency can let the video bleed through.
            .background(Theme.background.ignoresSafeArea())

            if playback.hasActiveTrack {
                MiniPlayerBar { withAnimation(.snappy(duration: 0.3)) { isShowingNowPlaying = true } }
                    // Sits directly above the tab bar rather than over it.
                    .padding(.bottom, 49)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Not a `fullScreenCover`: that presentation style removes the
            // presenting view from the window once it settles, so there would
            // be nothing behind the player for a pull-down to reveal — black,
            // measured on a 200pt probe offset. The layer's own
            // `Theme.background.ignoresSafeArea()` is what covers the status
            // bar and the tab bar, so this must NOT ignore safe areas itself:
            // that would slide the header under the clock.
            if isShowingNowPlaying {
                NowPlayingView(onDismiss: { isShowingNowPlaying = false })
                    // Removal is `.identity` because the exit animation has
                    // already carried the layer off the bottom by the time it
                    // goes away — a removal transition would slide it twice.
                    .transition(.asymmetric(insertion: .move(edge: .bottom),
                                            removal: .identity))
                    .zIndex(1)
                    // The VoiceOver isolation a modal presentation gave for
                    // free. As a sibling layer, the library and the tab bar
                    // stay in the accessibility tree behind the player, so
                    // VoiceOver would otherwise swipe straight into them.
                    //
                    // `.accessibilityHidden` on those views does *not* work
                    // here — measured against a live tree dump: SwiftUI
                    // flattens their children into this same container, where
                    // they escape a modifier attached to their parent.
                    // `isModal` is judged against siblings instead, which is
                    // exactly the relationship that holds. It has to follow
                    // `.contain`, because a trait needs an element to sit on.
                    //
                    // It does not affect XCUITest, which enumerates the whole
                    // snapshot regardless of modality — a UI test that wants
                    // to know the player is up must assert on the player.
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.snappy(duration: 0.25), value: playback.hasActiveTrack)
        // Starting a song opens the player, exactly as the reference app
        // does. It is also what makes playback start at all — see
        // `userPlaybackToken` in PlaybackCoordinator.
        .onChange(of: playback.userPlaybackToken) {
            withAnimation(.snappy(duration: 0.3)) { isShowingNowPlaying = true }
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
