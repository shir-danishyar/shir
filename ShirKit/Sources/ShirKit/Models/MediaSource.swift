import Foundation

/// Where the audio for a track actually comes from.
///
/// The two cases are deliberately different products:
/// `.youtube` plays through the official IFrame Player, which means YouTube
/// controls the stream and any advertising in it. `.localFile` is a file the
/// user brought with them, so the app owns playback end to end.
public enum MediaSource: Codable, Hashable, Sendable {
    case youtube(videoID: String)
    case localFile(fileName: String)

    /// Whether this source is allowed to keep playing with the screen off.
    ///
    /// Only owned files qualify. Backgrounding the IFrame player to get
    /// audio-only YouTube playback violates the YouTube API Services Terms,
    /// so the coordinator pauses YouTube tracks on resign-active instead.
    public var supportsBackgroundPlayback: Bool {
        switch self {
        case .youtube: return false
        case .localFile: return true
        }
    }
}
