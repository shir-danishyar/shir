import AVFoundation
import MediaPlayer
import Observation
import WebKit

/// Owns the web view, the audio session, and the lock-screen controls.
///
/// This is a spike, so everything is in one type on purpose — the shape of the
/// production code is `YouTubePlayerEngine`, not this.
@MainActor
@Observable
final class SpikeController: NSObject {

    /// Two tracks is all criterion 1 needs: play the first, change to the
    /// second while locked, see whether audio survives.
    struct Track {
        let id: String
        let title: String
    }

    let tracks: [Track] = [
        Track(id: "dQw4w9WgXcQ", title: "Track 1"),
        Track(id: "9bZkp7q19f0", title: "Track 2"),
    ]

    private(set) var log: [String] = []
    private(set) var currentIndex = 0
    private(set) var playerState = "—"
    private(set) var bridgeReady = false

    var currentTrack: Track { tracks[currentIndex] }

    let webView: WKWebView

    override init() {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        // Without this the first play() is rejected as not user-initiated.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        installUserScripts(into: controller)
        webView.navigationDelegate = self

        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: - Script injection

    /// Every script goes into `.page` at `.atDocumentStart`.
    ///
    /// `.defaultClient` would be the safer-sounding choice and is completely
    /// wrong here: these scripts patch `fetch`, `XMLHttpRequest` and
    /// `Document.prototype`, and in an isolated world they would patch copies
    /// the page never touches — running, reporting success, doing nothing.
    private func installUserScripts(into controller: WKUserContentController) {
        // Register the handler in the same world the scripts run in, or their
        // window.webkit.messageHandlers lookup finds nothing.
        controller.add(self, contentWorld: .page, name: "spike")

        for name in ["AdStrip", "BackgroundPlay", "Bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                append("MISSING SCRIPT: \(name).js — check the XcodeGen resource phase")
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
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            append("audio session active (.playback)")
        } catch {
            append("AUDIO SESSION FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Lock screen

    /// The next-track command is the instrument for criterion 1: it lets the
    /// track change be triggered from the lock screen, with the app fully
    /// backgrounded, which is exactly the scenario under test.
    private func configureRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            self?.run("__spike.play()", label: "remote play")
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            self?.run("__spike.pause()", label: "remote pause")
            return .success
        }
        centre.nextTrackCommand.addTarget { [weak self] _ in
            self?.advance(reason: "lock-screen next")
            return .success
        }
        centre.nextTrackCommand.isEnabled = true
        centre.playCommand.isEnabled = true
        centre.pauseCommand.isEnabled = true
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentTrack.title,
            MPMediaItemPropertyArtist: "Background Play Spike",
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
    }

    // MARK: - Actions

    func start() {
        let url = URL(string: "https://m.youtube.com/watch?v=\(currentTrack.id)")!
        append("loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        updateNowPlaying()
    }

    /// Criterion 1. Called from the lock screen while backgrounded.
    func advance(reason: String) {
        currentIndex = (currentIndex + 1) % tracks.count
        append("── \(reason): switching to \(currentTrack.title) (\(currentTrack.id))")
        updateNowPlaying()
        run("__spike.load('\(currentTrack.id)')", label: "load")
        // Give the player a moment, then record what actually happened. This
        // is what we read after unlocking the phone.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.probe(label: "3s after switch")
        }
    }

    func play() {
        run("__spike.play()", label: "play")
    }

    /// Launch with `-autoadvance` to make a simulator run answer the spec's open
    /// question — does `loadVideoById` swap the video in place, or does it
    /// navigate? A navigation would tear down the audio session and sink the
    /// whole design, so it is worth knowing without needing a human to tap.
    private var autoAdvanceRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-autoadvance")
    }

    private func scheduleAutoAdvanceIfRequested() {
        guard autoAdvanceRequested else { return }
        append("auto-advance armed (15s)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            self.probe(label: "before switch")
            self.advance(reason: "auto-advance")
        }
    }

    func probe(label: String) {
        run("__spike.status()", label: "status (\(label))")
    }

    private func run(_ javaScript: String, label: String) {
        // __spike only exists once a document has started loading, so an early
        // probe would otherwise surface as an opaque "JavaScript exception".
        let guarded = "(typeof __spike === 'undefined') ? 'bridge not ready' : \(javaScript)"
        webView.evaluateJavaScript(guarded) { [weak self] result, error in
            Task { @MainActor in
                if let error {
                    self?.append("\(label) ERROR: \(error.localizedDescription)")
                } else {
                    self?.append("\(label): \(result.map { "\($0)" } ?? "nil")")
                }
            }
        }
    }

    // MARK: - Lifecycle hooks

    func didEnterBackground() {
        append("── app backgrounded")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.probe(label: "5s after backgrounding")
        }
    }

    func willEnterForeground() {
        append("── app foregrounded")
        probe(label: "on foreground")
    }

    // MARK: - Logging

    func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let entry = "[\(stamp)] \(line)"
        log.append(entry)
        // Also to the console, so a device run can be watched over the cable.
        print("SPIKE \(entry)")
    }

    func clearLog() { log.removeAll() }
}

// MARK: - Script messages

extension SpikeController: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit always delivers script messages on the main thread, so this
        // is safe — the same assumption Riff's YouTubePlayerEngine already makes.
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String else { return }

            switch kind {
            case "log":
                append("js: \(payload["text"] as? String ?? "")")
            case "state":
                let state = payload["state"] as? String ?? "?"
                playerState = state
                append("js state: \(state) [\(payload["videoId"] as? String ?? "")]")
            case "ready":
                guard !bridgeReady else { return }
                bridgeReady = true
                scheduleAutoAdvanceIfRequested()
            default:
                append("js: unknown message \(payload)")
            }
        }
    }
}

// MARK: - Navigation

extension SpikeController: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            append("navigation finished: \(webView.url?.absoluteString ?? "—")")
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            append("navigation FAILED: \(error.localizedDescription)")
        }
    }
}
