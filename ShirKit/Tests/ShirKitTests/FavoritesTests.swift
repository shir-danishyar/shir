import XCTest
@testable import ShirKit

@MainActor
final class FavoritesTests: XCTestCase {

    private func makeStore() -> (LibraryStore, InMemoryLibraryPersistence) {
        let persistence = InMemoryLibraryPersistence()
        return (LibraryStore(persistence: persistence), persistence)
    }

    private func track(_ id: String) -> Track {
        .youtube(videoID: id, title: "Song \(id)", channelTitle: "Channel")
    }

    /// The bug this whole model change exists to fix: playing a song puts it in
    /// the catalogue so the queue can resolve it, and that must not file it
    /// under My Favorites.
    func testUpsertingATrackDoesNotMakeItAFavorite() {
        let (store, _) = makeStore()
        store.upsert(track("a"))

        XCTAssertFalse(store.isFavorite("yt:a"))
        XCTAssertTrue(store.favorites.isEmpty)
        XCTAssertEqual(store.allTracks.count, 1, "it should still be in the catalogue")
    }

    func testAddingToFavoritesAlsoAddsToTheCatalogue() {
        let (store, _) = makeStore()
        store.addToFavorites(track("a"))

        XCTAssertTrue(store.isFavorite("yt:a"))
        XCTAssertEqual(store.favorites.map(\.id), ["yt:a"])
        XCTAssertNotNil(store.track(id: "yt:a"))
    }

    func testFavoritesAreNewestFirst() {
        let (store, _) = makeStore()
        store.addToFavorites(track("a"))
        store.addToFavorites(track("b"))

        XCTAssertEqual(store.favorites.map(\.id), ["yt:b", "yt:a"])
    }

    func testAddingTheSameFavoriteTwiceIsANoOp() {
        let (store, persistence) = makeStore()
        store.addToFavorites(track("a"))
        let writes = persistence.saveCount

        store.addToFavorites(track("a"))

        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(persistence.saveCount, writes, "a duplicate should not cost a write")
    }

    func testTogglingFlipsMembershipBothWays() {
        let (store, _) = makeStore()
        let song = track("a")

        store.toggleFavorite(song)
        XCTAssertTrue(store.isFavorite(song.id))

        store.toggleFavorite(song)
        XCTAssertFalse(store.isFavorite(song.id))
        XCTAssertNotNil(store.track(id: song.id), "unfavoriting keeps it in the catalogue")
    }

    func testFavoritesSurviveAReload() {
        let persistence = InMemoryLibraryPersistence()
        let store = LibraryStore(persistence: persistence)
        store.addToFavorites(track("a"))

        let reloaded = LibraryStore(persistence: persistence)
        XCTAssertEqual(reloaded.favorites.map(\.id), ["yt:a"])
    }

    /// Adding a field to `Library` used to be a data-loss bug: the synthesized
    /// decoder throws `keyNotFound`, and `LibraryStore` reacts to a decode
    /// failure by starting empty. A library saved before favorites existed must
    /// still load with all its music.
    func testALibraryFileWithoutFavoritesStillLoads() throws {
        let json = """
        {
          "tracks": {
            "yt:a": {
              "id": "yt:a", "title": "Old song", "artist": "Old artist",
              "source": { "youtube": { "videoID": "a" } },
              "addedAt": "2026-01-01T00:00:00Z"
            }
          },
          "playlists": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: Data(json.utf8))

        XCTAssertEqual(library.tracks.count, 1, "the music must survive")
        XCTAssertTrue(library.favoriteTrackIDs.isEmpty)
    }

    /// A favorite whose track was deleted from the catalogue must not crash or
    /// leave a hole — it just stops resolving.
    func testDeletingATrackRemovesItFromTheFavoritesList() {
        let (store, _) = makeStore()
        store.addToFavorites(track("a"))
        store.addToFavorites(track("b"))

        store.deleteTrack(id: "yt:a")

        XCTAssertEqual(store.favorites.map(\.id), ["yt:b"])
    }
}
