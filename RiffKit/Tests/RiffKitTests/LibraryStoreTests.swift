import XCTest
@testable import RiffKit

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func makeStore() -> (LibraryStore, InMemoryLibraryPersistence) {
        let persistence = InMemoryLibraryPersistence()
        return (LibraryStore(persistence: persistence), persistence)
    }

    func testCreatingPlaylistPersistsIt() {
        let (store, persistence) = makeStore()
        let playlist = store.createPlaylist(named: "Late Night")

        XCTAssertEqual(store.playlists.map(\.name), ["Late Night"])
        XCTAssertEqual(persistence.stored.playlists.first?.id, playlist.id)
    }

    func testBlankPlaylistNameFallsBackToDefault() {
        let (store, _) = makeStore()
        store.createPlaylist(named: "   ")
        XCTAssertEqual(store.playlists.first?.name, "New Playlist")
    }

    func testAddingSameTrackTwiceDoesNotDuplicate() {
        let (store, _) = makeStore()
        let playlist = store.createPlaylist(named: "Gym")
        let track = Track.youtube(videoID: "abc", title: "Track", channelTitle: "Artist")

        store.add(track, toPlaylist: playlist.id)
        store.add(track, toPlaylist: playlist.id)

        XCTAssertEqual(store.playlist(id: playlist.id)?.trackIDs, ["yt:abc"])
    }

    func testUpsertKeepsOriginalAddedDate() {
        let (store, _) = makeStore()
        let original = Date(timeIntervalSince1970: 1_000)
        store.upsert(Track.youtube(videoID: "a", title: "Old", channelTitle: "A", addedAt: original))

        store.upsert(Track.youtube(videoID: "a", title: "New title", channelTitle: "A", addedAt: Date()))

        let stored = store.track(id: "yt:a")
        XCTAssertEqual(stored?.title, "New title")
        XCTAssertEqual(stored?.addedAt, original, "re-adding must not reshuffle library sort order")
    }

    func testDeletingTrackRemovesItFromEveryPlaylist() {
        let (store, _) = makeStore()
        let first = store.createPlaylist(named: "One")
        let second = store.createPlaylist(named: "Two")
        let track = Track.youtube(videoID: "abc", title: "Track", channelTitle: "Artist")
        store.add(track, toPlaylist: first.id)
        store.add(track, toPlaylist: second.id)

        store.deleteTrack(id: track.id)

        XCTAssertNil(store.track(id: track.id))
        XCTAssertTrue(store.playlist(id: first.id)?.trackIDs.isEmpty ?? false)
        XCTAssertTrue(store.playlist(id: second.id)?.trackIDs.isEmpty ?? false)
    }

    func testDeletingPlaylistLeavesTracksInLibrary() {
        let (store, _) = makeStore()
        let playlist = store.createPlaylist(named: "Temp")
        store.add(Track.youtube(videoID: "abc", title: "Track", channelTitle: "Artist"), toPlaylist: playlist.id)

        store.deletePlaylist(id: playlist.id)

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertNotNil(store.track(id: "yt:abc"))
    }

    func testReorderingPlaylistPersistsNewOrder() {
        let (store, persistence) = makeStore()
        let playlist = store.createPlaylist(named: "Mix")
        for track in makeTracks(3) { store.add(track, toPlaylist: playlist.id) }

        store.moveTracks(inPlaylist: playlist.id, fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(persistence.stored.playlists[0].trackIDs, ["yt:v1", "yt:v2", "yt:v0"])
    }

    func testTogglingMembershipAddsThenRemoves() {
        let (store, _) = makeStore()
        let playlist = store.createPlaylist(named: "Mix")
        let track = Track.youtube(videoID: "abc", title: "Track", channelTitle: "Artist")

        store.toggle(track, inPlaylist: playlist.id)
        XCTAssertEqual(store.playlistsContaining(trackID: track.id), [playlist.id])

        store.toggle(track, inPlaylist: playlist.id)
        XCTAssertTrue(store.playlistsContaining(trackID: track.id).isEmpty)
    }

    func testResolvingPlaylistSkipsMissingTracks() {
        var library = Library()
        library.playlists = [Playlist(name: "Mix", trackIDs: ["yt:a", "yt:missing"])]
        library.tracks["yt:a"] = Track.youtube(videoID: "a", title: "Present", channelTitle: "A")
        let store = LibraryStore(persistence: InMemoryLibraryPersistence(library))

        let resolved = store.tracks(in: store.playlists[0])
        XCTAssertEqual(resolved.map(\.id), ["yt:a"])
    }

    func testStoreReloadsPreviouslySavedLibrary() {
        let persistence = InMemoryLibraryPersistence()
        let first = LibraryStore(persistence: persistence)
        let playlist = first.createPlaylist(named: "Persisted")
        first.add(Track.youtube(videoID: "abc", title: "Track", channelTitle: "Artist"), toPlaylist: playlist.id)

        let second = LibraryStore(persistence: persistence)
        XCTAssertEqual(second.playlists.map(\.name), ["Persisted"])
        XCTAssertEqual(second.tracks(in: second.playlists[0]).map(\.id), ["yt:abc"])
    }

    func testFilePersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persistence = FileLibraryPersistence(url: url)
        XCTAssertTrue(try persistence.load().playlists.isEmpty, "a missing file should read as an empty library")

        var library = Library()
        library.playlists = [Playlist(name: "Saved", trackIDs: ["yt:a"])]
        library.tracks["yt:a"] = Track.youtube(videoID: "a", title: "Song", channelTitle: "Artist", duration: 210)
        try persistence.save(library)

        let reloaded = try persistence.load()
        XCTAssertEqual(reloaded.playlists.first?.name, "Saved")
        XCTAssertEqual(reloaded.tracks["yt:a"]?.duration, 210)
        XCTAssertEqual(reloaded.tracks["yt:a"]?.source, .youtube(videoID: "a"))
    }
}
