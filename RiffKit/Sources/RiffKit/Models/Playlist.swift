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

    /// Songs the user hearted, newest first.
    ///
    /// Favorites is its own list rather than "every track in the catalogue".
    /// A track lands in `tracks` as soon as it is played or added anywhere, and
    /// conflating that with being a favorite meant simply listening to
    /// something filed it under My Favorites.
    public var favoriteTrackIDs: [String]

    public init(
        tracks: [String: Track] = [:],
        playlists: [Playlist] = [],
        favoriteTrackIDs: [String] = []
    ) {
        self.tracks = tracks
        self.playlists = playlists
        self.favoriteTrackIDs = favoriteTrackIDs
    }

    /// Decodes tolerantly, defaulting anything the stored file predates.
    ///
    /// This is not politeness, it is data loss prevention. Swift's synthesized
    /// `Decodable` throws `keyNotFound` for a property that isn't in the JSON,
    /// and `LibraryStore` handles a decode failure by starting from an empty
    /// `Library` — so without this, adding any field to this type silently
    /// deletes every existing user's music the first time they launch.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decodeIfPresent([String: Track].self, forKey: .tracks) ?? [:]
        playlists = try container.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
        favoriteTrackIDs = try container.decodeIfPresent([String].self, forKey: .favoriteTrackIDs) ?? []
    }

    /// Resolves a playlist's IDs to tracks, dropping any that no longer exist.
    public func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { tracks[$0] }
    }

    /// Hearted songs, resolved and in order.
    public var favorites: [Track] {
        favoriteTrackIDs.compactMap { tracks[$0] }
    }
}
