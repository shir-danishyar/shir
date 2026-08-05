import Foundation

/// The JavaScript injected into YouTube pages.
///
/// One place that knows where the scripts live, so the player engine, the
/// search client and the tests cannot drift apart on it. They ship inside
/// ShirKit rather than the app bundle specifically so `ShirKitTests` can load
/// them into a `JSContext` and check them on macOS in milliseconds.
public enum PlayerScripts: String, CaseIterable, Sendable {
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
    /// Order matters: `AdStrip` patches `window.fetch`, so anything injected
    /// after it sees the patched version.
    public static let player: [PlayerScripts] = [.adStrip, .backgroundPlay, .playerSurface, .bridge]

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
