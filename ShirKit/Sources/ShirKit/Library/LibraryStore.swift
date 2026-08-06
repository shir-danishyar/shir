import Foundation
import Observation

/// The single source of truth for saved tracks and playlists.
///
/// Every mutation writes through to persistence immediately. The library is
/// small enough (a few thousand entries at most) that a full re-encode per edit
/// is cheaper than the bookkeeping a partial-write scheme would need.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var library: Library

    private let persistence: LibraryPersisting

    public init(persistence: LibraryPersisting) {
        self.persistence = persistence
        library = (try? persistence.load()) ?? Library()
    }

    // MARK: - Reads

    public var playlists: [Playlist] { library.playlists }

    public var allTracks: [Track] {
        library.tracks.values.sorted { $0.addedAt > $1.addedAt }
    }

    public var localTracks: [Track] {
        allTracks.filter { $0.localFileName != nil }
    }

    public func playlist(id: UUID) -> Playlist? {
        library.playlists.first { $0.id == id }
    }

    public func tracks(in playlist: Playlist) -> [Track] {
        library.tracks(in: playlist)
    }

    public func track(id: String) -> Track? {
        library.tracks[id]
    }

    /// Playlists that already contain a given track, used to tick rows in the "add to" sheet.
    public func playlistsContaining(trackID: String) -> Set<UUID> {
        Set(library.playlists.filter { $0.trackIDs.contains(trackID) }.map(\.id))
    }

    // MARK: - Track catalogue

    /// Adds a track, or refreshes the stored copy while keeping the original
    /// `addedAt` so library sort order stays stable.
    @discardableResult
    public func upsert(_ track: Track) -> Track {
        var incoming = track
        if let existing = library.tracks[track.id] {
            incoming.addedAt = existing.addedAt
        }
        library.tracks[track.id] = incoming
        persist()
        return incoming
    }

    /// Removes a track from the catalogue and from every playlist referencing it.
    public func deleteTrack(id: String) {
        library.tracks[id] = nil
        for index in library.playlists.indices {
            library.playlists[index].trackIDs.removeAll { $0 == id }
        }
        persist()
    }

    // MARK: - Playlists

    @discardableResult
    public func createPlaylist(named name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
        library.playlists.append(playlist)
        persist()
        return playlist
    }

    public func renamePlaylist(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(ofPlaylist: id) else { return }
        library.playlists[index].name = trimmed
        persist()
    }

    public func deletePlaylist(id: UUID) {
        library.playlists.removeAll { $0.id == id }
        persist()
    }

    /// Appends to a playlist. Duplicates are ignored — adding a song twice is
    /// almost always a mis-tap, not an intent to hear it twice.
    public func add(_ track: Track, toPlaylist playlistID: UUID) {
        let stored = upsert(track)
        guard let index = index(ofPlaylist: playlistID) else { return }
        guard !library.playlists[index].trackIDs.contains(stored.id) else { return }
        library.playlists[index].trackIDs.append(stored.id)
        persist()
    }

    public func remove(trackID: String, fromPlaylist playlistID: UUID) {
        guard let index = index(ofPlaylist: playlistID) else { return }
        library.playlists[index].trackIDs.removeAll { $0 == trackID }
        persist()
    }

    public func moveTracks(inPlaylist playlistID: UUID, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let index = index(ofPlaylist: playlistID) else { return }
        library.playlists[index].trackIDs.moveElements(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    /// Flips membership for a track in one playlist — the "add to playlist" sheet's row action.
    public func toggle(_ track: Track, inPlaylist playlistID: UUID) {
        guard let index = index(ofPlaylist: playlistID) else { return }
        if library.playlists[index].trackIDs.contains(track.id) {
            remove(trackID: track.id, fromPlaylist: playlistID)
        } else {
            add(track, toPlaylist: playlistID)
        }
    }

    // MARK: - Favorites
    //
    // Favorites is a list the user builds by tapping the heart, not a synonym
    // for the catalogue. Playing a song puts it in `tracks` so the queue and
    // history can resolve it later; that must not make it a favorite.

    public var favorites: [Track] { library.favorites }

    public func isFavorite(_ trackID: String) -> Bool {
        library.favoriteTrackIDs.contains(trackID)
    }

    public func addToFavorites(_ track: Track) {
        // Checked before the upsert: `upsert` persists, so doing it first would
        // cost a write even when this call changes nothing.
        guard !library.favoriteTrackIDs.contains(track.id) else { return }
        let stored = upsert(track)
        library.favoriteTrackIDs.insert(stored.id, at: 0)
        persist()
    }

    public func removeFromFavorites(trackID: String) {
        guard library.favoriteTrackIDs.contains(trackID) else { return }
        library.favoriteTrackIDs.removeAll { $0 == trackID }
        persist()
    }

    public func toggleFavorite(_ track: Track) {
        if isFavorite(track.id) {
            removeFromFavorites(trackID: track.id)
        } else {
            addToFavorites(track)
        }
    }

    // MARK: - Internals

    private func index(ofPlaylist id: UUID) -> Int? {
        library.playlists.firstIndex { $0.id == id }
    }

    /// Failures are silent by explicit choice. A `lastError` property lived
    /// here "so the UI can surface it" — nothing ever read it, so it went;
    /// git remembers the plumbing if save errors ever earn UI.
    private func persist() {
        try? persistence.save(library)
    }
}
