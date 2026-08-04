import Foundation

/// One playable item. Identity is derived from the source so the same YouTube
/// video added from two different playlists resolves to one entry in the library.
public struct Track: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var source: MediaSource
    public var artworkURL: URL?
    public var duration: TimeInterval?
    public var addedAt: Date

    public init(
        id: String,
        title: String,
        artist: String,
        source: MediaSource,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.source = source
        self.artworkURL = artworkURL
        self.duration = duration
        self.addedAt = addedAt
    }

    public static func youtube(
        videoID: String,
        title: String,
        channelTitle: String,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        addedAt: Date = Date()
    ) -> Track {
        Track(
            id: "yt:\(videoID)",
            title: title,
            artist: channelTitle,
            source: .youtube(videoID: videoID),
            artworkURL: artworkURL,
            duration: duration,
            addedAt: addedAt
        )
    }

    public static func localFile(
        fileName: String,
        title: String,
        artist: String,
        duration: TimeInterval? = nil,
        addedAt: Date = Date()
    ) -> Track {
        Track(
            id: "file:\(fileName)",
            title: title,
            artist: artist,
            source: .localFile(fileName: fileName),
            artworkURL: nil,
            duration: duration,
            addedAt: addedAt
        )
    }

    public var youtubeVideoID: String? {
        if case let .youtube(videoID) = source { return videoID }
        return nil
    }

    public var localFileName: String? {
        if case let .localFile(fileName) = source { return fileName }
        return nil
    }
}
