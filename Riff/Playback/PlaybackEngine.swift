import Foundation
import RiffKit

/// What an engine is currently doing, normalised across the two very different
/// backends (a WKWebView running YouTube's player, and AVPlayer).
enum EngineState: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case ended
}

/// A lock-screen or Control Center press that arrived through the page's media
/// session rather than through `MPRemoteCommandCenter`.
///
/// WebKit owns MediaRemote for this app's origin whenever web media is playing,
/// so for YouTube tracks this — not `MPRemoteCommandCenter` — is the path a
/// button press actually takes. See `MediaSession.js`.
enum RemoteCommand: Equatable {
    case play
    case pause
    case next
    case previous
    case seek(TimeInterval)
}

/// Callbacks an engine reports upward. Modelled as closures rather than a
/// delegate protocol so `PlaybackCoordinator` can wire both engines to the same
/// handlers without a per-engine adapter.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onStateChange: ((EngineState) -> Void)? { get set }
    /// (position, duration) in seconds.
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func load(_ track: Track, autoplay: Bool)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}
