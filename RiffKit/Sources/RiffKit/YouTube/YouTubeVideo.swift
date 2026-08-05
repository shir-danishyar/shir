import Foundation

/// A search result, before it becomes a library `Track`.
///
/// Kept separate from `Track` because a search result is a candidate, not
/// something the user owns — converting only happens when they save or play it.
public struct YouTubeVideo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public var duration: TimeInterval?

    public init(
        id: String,
        title: String,
        channelTitle: String,
        thumbnailURL: URL?,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
    }

    public var track: Track {
        .youtube(
            videoID: id,
            title: title,
            channelTitle: channelTitle,
            artworkURL: thumbnailURL,
            duration: duration
        )
    }

    /// The stable, unsigned thumbnail for a video id.
    ///
    /// Search responses carry thumbnail URLs with expiring `sqp`/`rs` signature
    /// parameters. Those must never reach the library, because the library is
    /// persisted and the signature outlives nothing. This form does not expire.
    public static func thumbnailURL(forVideoID id: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}
