import AVFoundation
import OSLog
import RiffKit
import WebKit

/// The two `WKPreferences` accessors that govern whether a `<video>` must be in
/// a visible page to hold the Now Playing card.
///
/// Declared as a protocol and reached with `unsafeBitCast` rather than
/// `perform(_:with:)` because the setter takes a `BOOL`: `perform` passes an
/// object pointer, so it can only ever spell `true`, and the value this needs to
/// write is `false`.
@objc private protocol NowPlayingVisibilitySPI {
    @objc(_setRequiresPageVisibilityForVideoToBeNowPlayingForTesting:)
    func setRequiresPageVisibilityForVideoToBeNowPlaying(_ enabled: Bool)

    @objc(_requiresPageVisibilityForVideoToBeNowPlayingForTesting)
    var requiresPageVisibilityForVideoToBeNowPlaying: Bool { get }
}

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

    /// Why these are `os_log` rather than `print`: the failures they describe are
    /// only reproducible on a locked physical device, where there is no Xcode
    /// console to read. Streaming
    /// `subsystem == "com.shirhussain.riff"` alongside
    /// `subsystem == "com.apple.WebKit" AND category == "Media"` is what turns
    /// "the lock screen is blank" into a diagnosis.
    static let log = Logger(subsystem: "com.shirhussain.riff", category: "nowplaying")
    var onStateChange: ((EngineState) -> Void)?
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onError: ((String) -> Void)?

    /// Lock-screen and Control Center presses, forwarded from `MediaSession.js`.
    ///
    /// Not part of `PlaybackEngine`: `LocalAudioEngine`'s remote commands arrive
    /// natively through `MPRemoteCommandCenter` and work correctly, so giving it
    /// a no-op property would imply a symmetry that does not exist.
    var onRemoteCommand: ((RemoteCommand) -> Void)?

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

    /// The track most recently handed to the player, so its metadata can be
    /// pushed again once a navigation has rebuilt the document.
    private var loadedTrack: Track?

    /// Set immediately before any `webView.load`, consumed by the navigation
    /// policy. Anything arriving without it came from the page itself.
    private var appInitiatedNavigation = false

    private static let messageHandlerName = "riff"

    // MARK: - PlaybackEngine

    func load(_ track: Track, autoplay: Bool) {
        guard let videoID = track.youtubeVideoID else {
            onError?("That track is not a YouTube video.")
            return
        }
        onStateChange?(.buffering)
        activateAudioSession()
        loadedTrack = track

        guard hasLoadedDocument else {
            hasLoadedDocument = true
            wantsAutoplayOnReady = autoplay
            appInitiatedNavigation = true
            webView.load(URLRequest(url: Self.watchURL(for: videoID)))
            return
        }

        run(autoplay ? "__riff.load('\(escape(videoID))')" : "__riff.cue('\(escape(videoID))')")
        pushNowPlayingMetadata()
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

        for script in PlayerScripts.player {
            do {
                controller.addUserScript(
                    WKUserScript(
                        source: try script.source,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false,
                        in: .page
                    )
                )
            } catch {
                // A missing script degrades to "the ads came back" rather than
                // a crash, so it is worth being loud about.
                assertionFailure("\(error)")
                onError?(error.localizedDescription)
            }
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        Self.allowNowPlayingWhileHidden(configuration.preferences)

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

    // MARK: - Lock screen

    /// Pushes Riff's own track metadata into the page's media session.
    ///
    /// This is what the lock screen actually renders for a YouTube track.
    /// `MediaSession.js` locks `navigator.mediaSession.metadata`, so without this
    /// the card is blank — and without the lock, YouTube would put the
    /// advertiser's name and artwork there during a pre-roll.
    ///
    /// `run(_:)` queues until the bridge is ready, so calling this during a
    /// navigation is safe; it replays on "ready".
    func pushNowPlayingMetadata() {
        guard let track = loadedTrack else { return }
        let arguments = [track.title, track.artist, "", track.artworkURL?.absoluteString ?? ""]
            .map(Self.jsString)
            .joined(separator: ", ")
        run("window.__riffMedia && __riffMedia.setMetadata(\(arguments))")
    }

    /// Encodes a string as a JavaScript literal.
    ///
    /// Deliberately not `escape(_:)`, which handles quotes and backslashes only.
    /// That is enough for an 11-character video id and nowhere near enough for a
    /// track title arriving from YouTube search: a newline or a U+2028 in a title
    /// would produce a syntax error, and the metadata push would fail silently,
    /// leaving a blank lock screen with no other symptom.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
    }

    // MARK: - Now Playing eligibility

    /// Lets a `<video>` keep its Now Playing card while its page is not visible.
    ///
    /// WebKit carries a behaviour restriction —
    /// `RequirePageVisibilityForVideoToBeNowPlaying` — that makes a `<video>`
    /// ineligible to be the Now Playing session whenever WebKit considers its
    /// page hidden, which a locked screen always is. An ineligible session has
    /// its card *cleared* without its audio being paused, which is precisely the
    /// symptom this app had: the music kept playing and the lock screen was
    /// empty.
    ///
    /// Nothing in the page can escape it. There is no `removeBehaviorRestriction`
    /// call site for the flag anywhere in WebCore; user gestures cannot clear it
    /// (`removeBehaviorRestrictionsAfterFirstUserGesture` masks against an
    /// allowlist that excludes it); and it cannot be dodged by making the media
    /// audio-only, because both `isVideo()` and `presentationType()` are decided
    /// by the tag name, not by whether a video track exists.
    ///
    /// So the only lever is this preference, and it is SPI. That is a trade this
    /// build can make and a shipping one could not — see CLAUDE.md §4.
    ///
    /// **`responds(to:)` cannot answer whether the feature is present.** Both
    /// accessors are declared unconditionally with their bodies inside
    /// `#if ENABLE(REQUIRES_PAGE_VISIBILITY_FOR_NOW_PLAYING)`, so a WebKit built
    /// without it still answers YES and then silently does nothing. Writing
    /// `true` and reading it back is the only way to tell a live setting from a
    /// stub — and it doubles as the diagnostic for which build this is.
    private static func allowNowPlayingWhileHidden(_ preferences: WKPreferences) {
        let setter = NSSelectorFromString("_setRequiresPageVisibilityForVideoToBeNowPlayingForTesting:")
        let getter = NSSelectorFromString("_requiresPageVisibilityForVideoToBeNowPlayingForTesting")
        guard preferences.responds(to: setter), preferences.responds(to: getter) else {
            #if DEBUG
            Self.log.notice("visibility preference absent — WebKit predates iOS 18.4")
            #endif
            return
        }

        let spi = unsafeBitCast(preferences, to: NowPlayingVisibilitySPI.self)
        spi.setRequiresPageVisibilityForVideoToBeNowPlaying(true)
        guard spi.requiresPageVisibilityForVideoToBeNowPlaying else {
            #if DEBUG
            Self.log.notice("visibility preference is a stub — restriction not in this build")
            #endif
            return
        }

        spi.setRequiresPageVisibilityForVideoToBeNowPlaying(false)
        #if DEBUG
        Self.log.notice("visibility restriction was live, now disabled")
        #endif
    }

    // MARK: - Diagnostics

    /// Whether WebKit currently owns a Now Playing session for this page, plus
    /// the two things that decide it.
    ///
    /// This exists because the failure it diagnoses is otherwise invisible.
    /// WebKit publishes web media to MediaRemote itself and only for a page it
    /// considers *visible*; a page it rules ineligible has its card cleared
    /// without its audio being paused. The symptom is therefore "music plays,
    /// lock screen is empty", which looks like a missing `MPNowPlayingInfoCenter`
    /// call and is not one. A WKWebView with no window is not a visible page.
    ///
    /// `_hasActiveNowPlayingSession` is SPI, so it is read through
    /// `responds(to:)` and degrades to `nil`. Diagnostic only — never a control
    /// path, and never consulted outside DEBUG.
    func nowPlayingDiagnostics() -> String {
        let key = "_hasActiveNowPlayingSession"
        let session = webView.responds(to: NSSelectorFromString(key))
            ? String(describing: webView.value(forKey: key) as? Bool ?? false)
            : "unavailable"
        return "session=\(session) window=\(webView.window != nil) superview=\(webView.superview != nil)"
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
            pushNowPlayingMetadata()
            flushPendingCommands()

        case "state":
            guard let name = payload["state"] as? String else { return }
            #if DEBUG
            Self.log.notice("\(name, privacy: .public) \(self.nowPlayingDiagnostics(), privacy: .public)")
            #endif
            onStateChange?(Self.engineState(named: name))

        case "progress":
            let position = payload["position"] as? Double ?? 0
            let duration = payload["duration"] as? Double ?? 0
            onProgress?(position, duration)

        case "error":
            let code = payload["code"] as? Int ?? -1
            onStateChange?(.idle)
            onError?(Self.message(forErrorCode: code))

        case "remote":
            guard let action = payload["action"] as? String else { return }
            switch action {
            case "next": onRemoteCommand?(.next)
            case "previous": onRemoteCommand?(.previous)
            case "play": onRemoteCommand?(.play)
            case "pause": onRemoteCommand?(.pause)
            case "seek": onRemoteCommand?(.seek(payload["time"] as? Double ?? 0))
            default: break
            }

        case "log":
            #if DEBUG
            if let text = payload["text"] as? String { Self.log.debug("js: \(text, privacy: .public)") }
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
