import SwiftUI
import WebKit

/// A host that adopts the engine's web view only once it is itself in a
/// window, so the web view never passes through a window-less moment.
///
/// WebKit treats `window == nil` as "the application entered background"
/// (`WKApplicationStateTrackingView` fires the same `EnteringBackground`
/// media interruption either way), so unparenting a playing web view pauses
/// it — an audible dip on a physical device every time Now Playing was
/// dismissed. Adopting on `didMoveToWindow` makes every handover
/// window→window: the stage steals the view from the offstage host when the
/// cover comes up, and `parkWebView()` returns it when the cover goes away.
final class WebViewAdoptingView: UIView {
    var webViewProvider: (() -> WKWebView)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        adoptIfPossible()
    }

    func adoptIfPossible() {
        guard window != nil, let webView = webViewProvider?(), webView.superview !== self else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }
}

/// Puts the engine's web view on screen inside Now Playing.
///
/// The view is deliberately visible and full size. The IFrame player must be
/// shown at a reasonable size under the YouTube API Services Terms, and hiding
/// it is exactly the shortcut that makes an app unshippable.
struct YouTubePlayerView: UIViewRepresentable {
    let engine: YouTubePlayerEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeUIView(context: Context) -> WebViewAdoptingView {
        let view = WebViewAdoptingView()
        view.webViewProvider = { [weak engine] in engine?.webView ?? WKWebView() }
        return view
    }

    func updateUIView(_ uiView: WebViewAdoptingView, context: Context) {}

    /// The cover is going away; hand the web view back to the offstage host
    /// before this container is torn out of the hierarchy.
    static func dismantleUIView(_ uiView: WebViewAdoptingView, coordinator: Coordinator) {
        uiView.webViewProvider = nil
        coordinator.engine?.parkWebView()
    }

    final class Coordinator {
        weak var engine: YouTubePlayerEngine?
        init(engine: YouTubePlayerEngine) { self.engine = engine }
    }
}

/// The web view's home whenever Now Playing is closed: in the window, sized
/// like the stage, occluded behind the opaque tab UI. Being parented is what
/// keeps WebKit from treating dismissal as backgrounding; being occluded is
/// how it stays invisible, because a near-transparent or 1pt view is treated
/// as hidden and stops the page (CLAUDE.md §9).
struct OffstageYouTubePlayerHost: UIViewRepresentable {
    let engine: YouTubePlayerEngine

    func makeUIView(context: Context) -> WebViewAdoptingView { engine.offstageHost }

    func updateUIView(_ uiView: WebViewAdoptingView, context: Context) {}
}
