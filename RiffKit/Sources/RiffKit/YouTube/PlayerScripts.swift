import Foundation

/// The JavaScript injected into YouTube pages.
///
/// One place that knows where the scripts live, so the player engine, the
/// search client and the tests cannot drift apart on it. They ship inside
/// RiffKit rather than the app bundle specifically so `RiffKitTests` can load
/// them into a `JSContext` and check them on macOS in milliseconds.
public enum PlayerScripts: String, CaseIterable, Sendable {
    /// Owns `navigator.mediaSession` so the lock screen shows Riff's track and
    /// its next button advances Riff's queue rather than YouTube's autoplay.
    case mediaSession = "MediaSession"
    /// Deletes YouTube's ad inventory before its player parses it.
    case adStrip = "AdStrip"
    /// Keeps playback alive with the screen off.
    case backgroundPlay = "BackgroundPlay"
    /// Hides YouTube's chrome so the web view is a player, not a browser.
    case playerSurface = "PlayerSurface"
    /// Player commands in, state and progress out.
    case bridge = "Bridge"
    /// Keyless YouTube search, run from inside a first-party page.
    case search = "Search"

    /// The scripts the player web view needs, in injection order.
    ///
    /// Order matters twice. `MediaSession` goes first so it captures the pristine
    /// `MediaSession.prototype` methods before anything can wrap them — the
    /// failure mode otherwise is a silently dead next button. `AdStrip` patches
    /// `window.fetch`, so anything after it sees the patched version.
    public static let player: [PlayerScripts] = [
        .mediaSession, .adStrip, .backgroundPlay, .playerSurface, .bridge,
    ]

    public var source: String {
        get throws {
            guard let url = Bundle.module.url(
                forResource: rawValue,
                withExtension: "js",
                subdirectory: "Scripts"
            ) else {
                throw ScriptError.missing(rawValue)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    public enum ScriptError: LocalizedError {
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case let .missing(name):
                return "Player script \(name).js is missing from the app bundle."
            }
        }
    }
}
