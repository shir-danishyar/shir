import Foundation
import ShirKit
import WebKit

/// Plays YouTube tracks through the official IFrame Player API inside a WKWebView.
///
/// This is the only sanctioned way for a third-party app to play YouTube
/// content. Three rules follow from the YouTube API Services Terms and are
/// enforced here rather than left to the UI:
///
/// - The player is never hidden or given zero size. `NowPlayingView` shows it.
/// - Ads, overlays and the stream itself are untouched. The app talks to the
///   player only through `loadVideoById` / `playVideo` / `pauseVideo` / `seekTo`.
/// - Audio does not continue in the background. `PlaybackCoordinator` pauses
///   YouTube tracks when the app leaves the foreground.
@MainActor
final class YouTubePlayerEngine: NSObject, PlaybackEngine {
    var onStateChange: ((EngineState) -> Void)?
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onError: ((String) -> Void)?

    /// Exposed so `YouTubePlayerView` can put the very same web view on screen.
    /// One instance for the app's lifetime — recreating it would restart the
    /// player every time the Now Playing sheet is dismissed.
    private(set) lazy var webView: WKWebView = makeWebView()

    private var isPlayerReady = false
    /// Commands issued before the IFrame API finishes loading, replayed on ready.
    private var pendingCommands: [String] = []
    private var pendingTrackID: String?

    private static let messageHandlerName = "shir"

    // MARK: - PlaybackEngine

    func load(_ track: Track, autoplay: Bool) {
        guard let videoID = track.youtubeVideoID else {
            onError?("That track is not a YouTube video.")
            return
        }
        pendingTrackID = videoID
        onStateChange?(.buffering)
        let function = autoplay ? "loadVideoById" : "cueVideoById"
        run("player.\(function)({videoId: '\(escape(videoID))'});")
    }

    func play() { run("player.playVideo();") }

    func pause() { run("player.pauseVideo();") }

    func seek(to time: TimeInterval) {
        run("player.seekTo(\(max(0, time)), true);")
    }

    func stop() {
        run("player.stopVideo();")
        onStateChange?(.idle)
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.add(self, name: Self.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Keep the video in the page instead of handing it to the fullscreen
        // AVPlayerViewController, which would hide our own controls.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        // The IFrame API validates the embedding origin, so the HTML has to be
        // served as though it came from youtube.com.
        webView.loadHTMLString(Self.playerHTML, baseURL: URL(string: "https://www.youtube.com"))
        return webView
    }

    private func run(_ javaScript: String) {
        guard isPlayerReady else {
            pendingCommands.append(javaScript)
            return
        }
        webView.evaluateJavaScript(javaScript) { [weak self] _, error in
            // Commands fired while the player swaps videos can fail harmlessly;
            // only surface a failure that leaves playback stuck.
            guard let error, (error as NSError).code != WKError.javaScriptExceptionOccurred.rawValue else { return }
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

    // MARK: - Player page

    /// Minimal host page for the IFrame API. `controls: 0` hides YouTube's own
    /// chrome because the app draws its transport controls, but the video
    /// surface itself stays visible and full size.
    private static let playerHTML = """
    <!DOCTYPE html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
          #player { position: absolute; inset: 0; width: 100%; height: 100%; }
        </style>
      </head>
      <body>
        <div id="player"></div>
        <script>
          var player;
          var progressTimer;

          function post(payload) {
            window.webkit.messageHandlers.shir.postMessage(payload);
          }

          function startProgressUpdates() {
            stopProgressUpdates();
            progressTimer = setInterval(function () {
              if (!player || !player.getCurrentTime) { return; }
              post({
                event: 'progress',
                position: player.getCurrentTime() || 0,
                duration: player.getDuration() || 0
              });
            }, 500);
          }

          function stopProgressUpdates() {
            if (progressTimer) { clearInterval(progressTimer); progressTimer = null; }
          }

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              height: '100%',
              width: '100%',
              playerVars: {
                playsinline: 1,
                controls: 0,
                rel: 0,
                modestbranding: 1,
                fs: 0,
                iv_load_policy: 3,
                origin: 'https://www.youtube.com'
              },
              events: {
                onReady: function () { post({ event: 'ready' }); },
                onStateChange: function (e) {
                  if (e.data === YT.PlayerState.PLAYING) { startProgressUpdates(); }
                  else if (e.data !== YT.PlayerState.BUFFERING) { stopProgressUpdates(); }
                  post({ event: 'state', value: e.data });
                },
                onError: function (e) { post({ event: 'error', value: e.data }); }
              }
            });
          }

          var tag = document.createElement('script');
          tag.src = 'https://www.youtube.com/iframe_api';
          document.body.appendChild(tag);
        </script>
      </body>
    </html>
    """
}

// MARK: - JS bridge

extension YouTubePlayerEngine: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit always delivers script messages on the main thread, so this
        // asserts the isolation it already has rather than hopping — hopping
        // would reorder player events against each other.
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            handle(event: event, body: body)
        }
    }

    private func handle(event: String, body: [String: Any]) {
        switch event {
        case "ready":
            isPlayerReady = true
            flushPendingCommands()

        case "state":
            guard let raw = body["value"] as? Int else { return }
            onStateChange?(Self.state(fromYouTubeCode: raw))

        case "progress":
            let position = body["position"] as? Double ?? 0
            let duration = body["duration"] as? Double ?? 0
            onProgress?(position, duration)

        case "error":
            let code = body["value"] as? Int ?? -1
            onStateChange?(.idle)
            onError?(Self.message(forErrorCode: code))

        default:
            break
        }
    }

    /// YouTube's `PlayerState` constants.
    private static func state(fromYouTubeCode code: Int) -> EngineState {
        switch code {
        case 0: return .ended
        case 1: return .playing
        case 2: return .paused
        case 3: return .buffering
        case 5: return .paused   // cued
        default: return .idle    // -1, unstarted
        }
    }

    /// The two codes that matter most are 101 and 150: the uploader has
    /// disabled embedding, so the video simply cannot be played here.
    private static func message(forErrorCode code: Int) -> String {
        switch code {
        case 2: return "YouTube rejected that video ID."
        case 5: return "This video can't be played in an embedded player."
        case 100: return "That video is private or has been removed."
        case 101, 150: return "The uploader doesn't allow this video to play outside YouTube."
        default: return "YouTube couldn't play that video (error \(code))."
        }
    }
}
