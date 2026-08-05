import AVFoundation
import RiffKit
import WebKit

/// Plays YouTube by driving `m.youtube.com` as a first-party document.
///
/// The previous version embedded `youtube.com/embed` and talked to it over
/// postMessage. That had to go: a cross-origin iframe is a black box, so no
/// injected script can reach inside it — which rules out both ad stripping and
/// keeping audio alive in the background. Loading the mobile site directly is
/// what makes injection possible at all.
///
/// Four scripts do the work, all at `.atDocumentStart` in `WKContentWorld.page`:
///
/// - `AdStrip.js` deletes the ad inventory before the player parses it
/// - `BackgroundPlay.js` keeps playback alive with the screen off
/// - `PlayerSurface.js` hides YouTube's chrome so this is a player, not a browser
/// - `Bridge.js` exposes `window.__riff` and reports state and progress back
///
/// The content world matters more than anything else here. These scripts patch
/// page globals — `fetch`, `XMLHttpRequest`, `Document.prototype`. In
/// `.defaultClient` they would run, report success, and do nothing, because the
/// page's own globals would be untouched. That failure mode is completely
/// silent, so it is worth being deliberate about.
@MainActor
final class YouTubePlayerEngine: NSObject, PlaybackEngine {
    var onStateChange: ((EngineState) -> Void)?
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onError: ((String) -> Void)?

    /// Exposed so `YouTubePlayerView` can put this very web view on screen.
    /// One instance for the app's lifetime — recreating it would restart the
    /// player every time Now Playing is dismissed.
    private(set) lazy var webView: WKWebView = makeWebView()

    /// True once `Bridge.js` has found `#movie_player` and wired its listeners.
    private var isBridgeReady = false

    /// Commands issued before the bridge is ready, replayed once it is.
    private var pendingCommands: [String] = []

    /// The document has to exist before anything can play. The first track is
    /// loaded by navigating; every track after that is a `loadVideoById` into
    /// the live page, which the Phase 0 spike proved does *not* navigate — so
    /// the audio session survives a track change.
    private var hasLoadedDocument = false
    private var wantsAutoplayOnReady = true

    /// Set immediately before any `webView.load`, consumed by the navigation
    /// policy. Anything arriving without it came from the page itself.
    private var appInitiatedNavigation = false

    private static let messageHandlerName = "riff"
    private static let scriptNames = ["AdStrip", "BackgroundPlay", "PlayerSurface", "Bridge"]

    // MARK: - PlaybackEngine

    func load(_ track: Track, autoplay: Bool) {
        guard let videoID = track.youtubeVideoID else {
            onError?("That track is not a YouTube video.")
            return
        }
        onStateChange?(.buffering)
        activateAudioSession()

        guard hasLoadedDocument else {
            hasLoadedDocument = true
            wantsAutoplayOnReady = autoplay
            appInitiatedNavigation = true
            webView.load(URLRequest(url: Self.watchURL(for: videoID)))
            return
        }

        run(autoplay ? "__riff.load('\(escape(videoID))')" : "__riff.cue('\(escape(videoID))')")
        scheduleUnmute()
    }

    func play() {
        activateAudioSession()
        run("__riff.play()")
        scheduleUnmute()
    }

    func pause() {
        run("__riff.pause()")
    }

    func seek(to time: TimeInterval) {
        run("__riff.seek(\(max(0, time)))")
    }

    func stop() {
        run("__riff.stop()")
        onStateChange?(.idle)
    }

    private static func watchURL(for videoID: String) -> URL {
        URL(string: "https://m.youtube.com/watch?v=\(videoID)")!
    }

    // MARK: - Audio session

    /// Activated lazily rather than at launch, so the app doesn't interrupt
    /// whatever else is playing until a song actually starts.
    ///
    /// This is what lets WebKit media keep running with the screen off, in
    /// combination with `UIBackgroundModes: audio` and the visibility overrides
    /// in `BackgroundPlay.js`. All three are required; any one missing and
    /// playback stops at lock.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            onError?("Could not start audio: \(error.localizedDescription)")
        }
    }

    /// YouTube starts every video muted — WebKit only permits unattended
    /// autoplay when the media is silent — and then waits for a tap on its own
    /// overlay. A music app must never sit there muted, and a freshly loaded
    /// video can come back muted, so this is re-asserted after every load.
    private func scheduleUnmute() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.run("__riff.unmute()")
        }
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        // Registered in the same world the scripts run in, or their
        // window.webkit.messageHandlers lookup finds nothing.
        controller.add(self, contentWorld: .page, name: Self.messageHandlerName)

        for name in Self.scriptNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                // A missing script is a build-configuration error — .js needs an
                // explicit resources build phase in project.yml — and it
                // degrades to "the ads came back" rather than a crash, so it is
                // worth being loud about.
                assertionFailure("Missing bundled script \(name).js")
                onError?("Player script \(name).js is missing from the app bundle.")
                continue
            }
            controller.addUserScript(
                WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                    in: .page
                )
            )
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = self

        // A player surface, not a browser. Beyond being the right product
        // shape, this removes a hard crash: tapping YouTube's search box threw
        // an uncaught UIKit exception from UIGestureGraph during touch
        // delivery, because WKWebView's gesture recognizers and YouTube's
        // formed a conflicting edge.
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.allowsBackForwardNavigationGestures = false

        return webView
    }

    private func run(_ javaScript: String) {
        guard isBridgeReady else {
            pendingCommands.append(javaScript)
            return
        }
        webView.evaluateJavaScript(javaScript) { [weak self] _, error in
            guard let error,
                  (error as NSError).code != WKError.javaScriptExceptionOccurred.rawValue
            else { return }
            Task { @MainActor in self?.onError?(error.localizedDescription) }
        }
    }

    private func flushPendingCommands() {
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands { run(command) }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: - Script messages

extension YouTubePlayerEngine: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit always delivers script messages on the main thread, so this
        // asserts isolation it already has rather than hopping — hopping would
        // reorder player events against each other.
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String else { return }
            handle(kind: kind, payload: payload)
        }
    }

    private func handle(kind: String, payload: [String: Any]) {
        switch kind {
        case "ready":
            guard !isBridgeReady else { return }
            isBridgeReady = true
            // The document was navigated for the first track; the page
            // autoplays it, so only an explicit pause needs sending.
            if !wantsAutoplayOnReady { run("__riff.pause()") }
            scheduleUnmute()
            flushPendingCommands()

        case "state":
            guard let name = payload["state"] as? String else { return }
            onStateChange?(Self.engineState(named: name))

        case "progress":
            let position = payload["position"] as? Double ?? 0
            let duration = payload["duration"] as? Double ?? 0
            onProgress?(position, duration)

        case "error":
            let code = payload["code"] as? Int ?? -1
            onStateChange?(.idle)
            onError?(Self.message(forErrorCode: code))

        case "log":
            #if DEBUG
            if let text = payload["text"] as? String { print("RIFF js: \(text)") }
            #endif

        default:
            break
        }
    }

    private static func engineState(named name: String) -> EngineState {
        switch name {
        case "playing": return .playing
        case "paused": return .paused
        case "buffering": return .buffering
        case "ended": return .ended
        default: return .idle
        }
    }

    private static func message(forErrorCode code: Int) -> String {
        switch code {
        case 2: return "That video ID isn't valid."
        case 5: return "This video can't be played here."
        case 100: return "That video was removed or made private."
        case 101, 150: return "The uploader doesn't allow this video to play outside YouTube."
        default: return "YouTube couldn't play that track."
        }
    }
}

// MARK: - Navigation

extension YouTubePlayerEngine: WKNavigationDelegate {

    /// Only navigations the app started are allowed through.
    ///
    /// Disabling user interaction stops taps, but YouTube can still navigate
    /// *itself* — an interstitial, a sign-in bounce, an app-store redirect. Any
    /// of those tears down the document and the audio session with it, which is
    /// the one thing this design cannot survive. Track changes are unaffected,
    /// because `loadVideoById` swaps in place without navigating.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(.allow)   // subframes are the player's own business
                return
            }
            if appInitiatedNavigation {
                appInitiatedNavigation = false
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.onStateChange?(.idle)
            self.onError?("Couldn't reach YouTube: \(error.localizedDescription)")
        }
    }
}
