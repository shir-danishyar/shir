import Foundation

/// A user-made playlist. Stores track IDs rather than tracks so a track edited
/// once (retitled, duration filled in) updates everywhere it appears.
public struct Playlist: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var trackIDs: [String]
    public var createdAt: Date
    /// Drives the generated gradient cover so a playlist keeps the same colours.
    public var artworkSeed: Int

    public init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [String] = [],
        createdAt: Date = Date(),
        artworkSeed: Int = Int.random(in: 0..<360)
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = createdAt
        self.artworkSeed = artworkSeed
    }
}

/// The whole persisted state of the app, in one Codable value.
public struct Library: Codable, Sendable {
    public var tracks: [String: Track]
    public var playlists: [Playlist]

    public init(tracks: [String: Track] = [:], playlists: [Playlist] = []) {
        self.tracks = tracks
        self.playlists = playlists
    }

    /// Resolves a playlist's IDs to tracks, dropping any that no longer exist.
    public func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { tracks[$0] }
    }
}
