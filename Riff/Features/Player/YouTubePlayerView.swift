import SwiftUI
import WebKit

/// Puts the engine's web view on screen.
///
/// Mounted in exactly two places, never both at once: full size in
/// `NowPlayingView`, and one point in `RootTabView` the rest of the time. The
/// second mount is not cosmetic — see `RootTabView.playerKeepAlive`. A `UIView`
/// has a single superview, so a third mount would silently blank one of these.
///
/// The old rule that this had to stay visible at a reasonable size was an
/// obligation of the IFrame player under YouTube's API Services Terms. Both went
/// with the App Store target; see CLAUDE.md §4.
struct YouTubePlayerView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
