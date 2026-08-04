import Foundation
import ShirKit

/// What an engine is currently doing, normalised across the two very different
/// backends (a WKWebView running YouTube's player, and AVPlayer).
enum EngineState: Equatable {
    case idle
    case buffering
    case playing
    case paused
    case ended
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
