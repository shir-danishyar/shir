import Foundation

/// Where the audio for a track actually comes from.
///
/// `.youtube` plays inside a `WKWebView` driving m.youtube.com; `.localFile` is
/// a file the user imported, played by AVPlayer. Two engines, one queue — see
/// `PlaybackCoordinator` in the app target.
///
/// A `supportsBackgroundPlayback` property used to live here — YouTube
/// answered `false` while the app aimed at the App Store. Both sources
/// background-play since the 2026-08-04 fork (they get there differently:
/// AVFoundation needs nothing special, YouTube needs the machinery in
/// CLAUDE.md §5 rule 10), so the property distinguished nothing and went.
public enum MediaSource: Codable, Hashable, Sendable {
    case youtube(videoID: String)
    case localFile(fileName: String)
}
