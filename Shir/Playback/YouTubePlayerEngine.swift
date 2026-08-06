import AVFoundation
import os
import ShirKit
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
/// - `Bridge.js` exposes `window.__shir` and reports state and progress back
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

    /// Answers pauses the app never asked for — most importantly WebKit's own:
    /// it force-pauses every video session when the app backgrounds
    /// (`BackgroundProcessPlaybackRestricted` — C++ app state, so no injected
    /// visibility override can reach it, and it fires whether or not the web
    /// view is mounted). The counter is to immediately play again.
    ///
    /// This is also what Brave's iOS browser ships (brave-core
    /// `ios/browser/web/media/resources/media_backgrounding.ts`): they track
    /// intent with a `userHitPause` flag where this tracks `wantsPlayback`,
    /// and replay in-page where this replays over the bridge. WebKit offers no
    /// API that lifts the restriction — the only exempt paths are PiP, AirPlay
    /// and CarPlay — so a sub-second dip at backgrounding is inherent to every
    /// implementation of this, theirs included.
    ///
    /// The when-to-answer judgement is `AutoResumePolicy` in ShirKit, where it
    /// is unit-tested; this file only wires it to WebKit.
    private var resumePolicy = AutoResumePolicy()

    private static let messageHandlerName = "shir"

    override init() {
        super.init()
        observeAudioSession()
    }

    /// Field diagnostics, deliberately sparse — only rare events, never the
    /// 500ms progress stream. Works on a sideloaded device too:
    /// `log stream --predicate 'subsystem == "shir.probe"'`.
    private static let probeLog = Logger(subsystem: "shir.probe", category: "engine")

    // MARK: - PlaybackEngine

    func load(_ track: Track, autoplay: Bool) {
        guard let videoID = track.youtubeVideoID else {
            onError?("That track is not a YouTube video.")
            return
        }
        onStateChange?(.buffering)
        activateAudioSession()
        resumePolicy.noteLoad(autoplay: autoplay)

        guard hasLoadedDocument else {
            hasLoadedDocument = true
            wantsAutoplayOnReady = autoplay
            appInitiatedNavigation = true
            Self.probeLog.log("first load: navigating, inWindow \(self.webView.window != nil, privacy: .public)")
            webView.load(URLRequest(url: Self.watchURL(for: videoID)))
            return
        }

        run(autoplay ? "__shir.load('\(escape(videoID))')" : "__shir.cue('\(escape(videoID))')")
        scheduleUnmute()
    }

    func play() {
        resumePolicy.notePlay()
        activateAudioSession()
        run("__shir.play()")
        scheduleUnmute()
    }

    func pause() {
        resumePolicy.notePause()
        run("__shir.pause()")
    }

    func seek(to time: TimeInterval) {
        run("__shir.seek(\(max(0, time)))")
    }

    func stop() {
        resumePolicy.notePlaybackEnded()
        run("__shir.stop()")
        onStateChange?(.idle)
    }

    private static func watchURL(for videoID: String) -> URL {
        URL(string: "https://m.youtube.com/watch?v=\(videoID)")!
    }

    // MARK: - Audio session

    /// Activated lazily rather than at launch, so the app doesn't interrupt
    /// whatever else is playing until a song actually starts.
    ///
    /// One of the four legs background audio stands on, with
    /// `UIBackgroundModes: audio`, the visibility overrides in
    /// `BackgroundPlay.js`, and the auto-resume below — CLAUDE.md §5 rule 10
    /// keeps the list. Any one missing and playback stops at home press or
    /// lock.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            onError?("Could not start audio: \(error.localizedDescription)")
        }
    }

    /// Tells `resumePolicy` who paused, so it can answer WebKit without also
    /// answering iOS.
    ///
    /// Delivery is on `.main` and handled synchronously rather than hopped
    /// through a `Task`, because ordering is the whole point: the interruption
    /// or route change has to be recorded *before* the page's own `paused`
    /// message arrives, or the resume fires against a session iOS just took
    /// away. `assumeIsolated` is safe here for the same reason it is on the
    /// script-message path — the notification is already on the main queue.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            Self.probeLog.log("audio interruption began")
            resumePolicy.noteInterruptionBegan()
        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let resuming = resumePolicy.noteInterruptionEnded(
                shouldResume: options.contains(.shouldResume)
            )
            Self.probeLog.log("audio interruption ended, resuming \(resuming, privacy: .public)")
            if resuming { play() }
        @unknown default:
            break
        }
    }

    /// Headphones out, or a Bluetooth device gone. iOS pauses and means it —
    /// answering that pause would play the song aloud in whatever room the
    /// user is standing in.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable
        else { return }

        Self.probeLog.log("output device disconnected")
        resumePolicy.noteOutputDeviceDisconnected()
    }

    /// YouTube starts every video muted — WebKit only permits unattended
    /// autoplay when the media is silent — and then waits for a tap on its own
    /// overlay. A music app must never sit there muted, and a freshly loaded
    /// video can come back muted, so this is re-asserted after every load.
    private func scheduleUnmute() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.run("__shir.unmute()")
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
            Self.probeLog.log("bridge ready")
            isBridgeReady = true
            // The document was navigated for the first track. Do not trust
            // the page to autoplay it: it does when the web view is the
            // visible stage, and it does not when the view sits occluded
            // behind the tab UI — measured as "bridge ready, then silence".
            // Commanding play() works in both postures.
            if wantsAutoplayOnReady {
                play()
            } else {
                run("__shir.pause()")
            }
            scheduleUnmute()
            flushPendingCommands()

        case "state":
            guard let name = payload["state"] as? String else { return }
            if name == "playing" { resumePolicy.notePlaying() }
            // The track finished. If the queue has more, the coordinator
            // starts the next one and `load` re-arms; if it does not, nothing
            // should be resumed — a page that autonavigates to a
            // recommendation must not resurrect playback minutes later.
            if name == "ended" { resumePolicy.notePlaybackEnded() }
            // A pause nobody asked for is an interruption — most importantly
            // WebKit's own EnteringBackground pause of video sessions, which
            // arrives while this process is still awake. Answering it with an
            // immediate play() is what keeps audio running past a home press;
            // the resumed audio then keeps the app alive in the background.
            // The pause is forwarded either way: if the resume fails, the UI
            // must not claim to be playing; if it succeeds, the following
            // "playing" corrects the state a beat later.
            onStateChange?(Self.engineState(named: name))
            if name == "paused", resumePolicy.shouldResumeAfterUnrequestedPause() {
                Self.probeLog.log("auto-resume")
                play()
            }

        case "progress":
            let position = payload["position"] as? Double ?? 0
            let duration = payload["duration"] as? Double ?? 0
            onProgress?(position, duration)

        case "error":
            let code = payload["code"] as? Int ?? -1
            Self.probeLog.log("player error \(code, privacy: .public)")
            // Stop wanting audio before reporting: a halted player still emits
            // a paused state, and answering that would have the engine
            // reactivating the audio session — stealing it from whatever the
            // user switched to — while Shir's own UI says nothing is playing.
            resumePolicy.notePlaybackEnded()
            onStateChange?(.idle)
            onError?(Self.message(forErrorCode: code))

        case "log":
            #if DEBUG
            if let text = payload["text"] as? String { print("SHIR js: \(text)") }
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
    ///
    /// The flag is cleared on *commit*, not on first use. A server redirect —
    /// a consent gate, a region bounce — arrives here as a second decision for
    /// the same load, and consuming the flag on the first one cancelled it,
    /// leaving the engine with `hasLoadedDocument` set and no document: every
    /// later track then ran `loadVideoById` against nothing and buffered
    /// forever behind a bridge that could never become ready. Once the
    /// document commits, the page's own navigations are blocked as before.
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
            decisionHandler(appInitiatedNavigation ? .allow : .cancel)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            Self.probeLog.log("navigation committed, inWindow \(self.webView.window != nil, privacy: .public)")
            appInitiatedNavigation = false
        }
    }

    /// A first load that never arrived must not leave the engine believing it
    /// has a document, or YouTube stays broken until the app is killed.
    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.resetForRetry()
            self.onStateChange?(.idle)
            self.onError?("Couldn't reach YouTube: \(error.localizedDescription)")
        }
    }

    /// Returns the engine to its pre-load state so the next `load` navigates
    /// afresh instead of talking to a document that does not exist.
    private func resetForRetry() {
        hasLoadedDocument = false
        appInitiatedNavigation = false
        isBridgeReady = false
        pendingCommands.removeAll()
        resumePolicy.notePlaybackEnded()
    }
}
