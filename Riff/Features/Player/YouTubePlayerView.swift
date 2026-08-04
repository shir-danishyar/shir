import SwiftUI
import WebKit

/// Puts the engine's web view on screen.
///
/// The view is deliberately visible and full size. The IFrame player must be
/// shown at a reasonable size under the YouTube API Services Terms, and hiding
/// it is exactly the shortcut that makes an app unshippable.
struct YouTubePlayerView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
