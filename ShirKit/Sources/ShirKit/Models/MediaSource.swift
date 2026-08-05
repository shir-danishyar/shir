import Foundation

/// Where the audio for a track actually comes from.
///
/// `.youtube` plays inside a `WKWebView` driving m.youtube.com; `.localFile` is
/// a file the user imported, played by AVPlayer. Two engines, one queue — see
/// `PlaybackCoordinator` in the app target.
public enum MediaSource: Codable, Hashable, Sendable {
    case youtube(videoID: String)
    case localFile(fileName: String)

    /// Whether this source keeps playing with the screen off.
    ///
    /// Both do, as of the 2026-08-04 move to a personal-device build. YouTube
    /// used to return `false` here, because the app was aiming at the App Store
    /// and backgrounding the IFrame player is the specific behaviour that got
    /// Musi removed. That constraint went away with the distribution target;
    /// see CLAUDE.md §2 for the reasoning and the revert path.
    ///
    /// Keeping the property rather than deleting it: local files reach this
    /// through AVFoundation, which needs nothing special, while YouTube needs
    /// an active `.playback` session and the visibility overrides in
    /// `BackgroundPlay.js`. The distinction still exists — it just no longer
    /// decides whether audio is allowed to continue.
    public var supportsBackgroundPlayback: Bool {
        switch self {
        case .youtube: return true
        case .localFile: return true
        }
    }
}
