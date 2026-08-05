import XCTest
@testable import RiffKit

final class SearchHistoryTests: XCTestCase {

    func testRecordingPutsTheNewestQueryFirst() {
        var history = SearchHistory()
        history.record("daft punk")
        history.record("ahmad zahir")

        XCTAssertEqual(history.entries, ["ahmad zahir", "daft punk"])
    }

    /// Re-searching something should move it up, not add a second copy.
    func testRecordingAKnownQueryMovesItToTheFront() {
        var history = SearchHistory(entries: ["c", "b", "a"])
        history.record("a")

        XCTAssertEqual(history.entries, ["a", "c", "b"])
    }

    /// Dedupe ignores case, and the casing you just typed wins — the list
    /// should read the way you last wrote it.
    func testDedupeIsCaseInsensitiveAndKeepsTheNewestCasing() {
        var history = SearchHistory()
        history.record("daft punk")
        history.record("Daft Punk")

        XCTAssertEqual(history.entries, ["Daft Punk"])
    }

    func testWhitespaceIsTrimmedAndBlankQueriesAreIgnored() {
        var history = SearchHistory()
        history.record("  spaced out  ")
        history.record("   ")
        history.record("")

        XCTAssertEqual(history.entries, ["spaced out"])
    }

    func testHistoryIsCappedAndDropsTheOldest() {
        var history = SearchHistory()
        for index in 0..<(SearchHistory.limit + 5) {
            history.record("query \(index)")
        }

        XCTAssertEqual(history.entries.count, SearchHistory.limit)
        XCTAssertEqual(history.entries.first, "query \(SearchHistory.limit + 4)")
        XCTAssertFalse(history.entries.contains("query 0"))
    }

    func testInitialisingAboveTheLimitTruncates() {
        let history = SearchHistory(entries: (0..<50).map { "q\($0)" })
        XCTAssertEqual(history.entries.count, SearchHistory.limit)
    }

    func testRemovingIsCaseInsensitive() {
        var history = SearchHistory(entries: ["Daft Punk", "ahmad zahir"])
        history.remove("daft punk")

        XCTAssertEqual(history.entries, ["ahmad zahir"])
    }

    func testNonLatinQueriesRoundTrip() {
        var history = SearchHistory()
        history.record("بنیامین بهادری")
        history.record("سید انور آزاد")

        XCTAssertEqual(history.entries, ["سید انور آزاد", "بنیامین بهادری"])
    }

    // MARK: - Store

    @MainActor
    func testStoreLoadsAndPersists() {
        let persistence = InMemorySearchHistoryPersistence(SearchHistory(entries: ["existing"]))
        let store = SearchHistoryStore(persistence: persistence)

        XCTAssertEqual(store.entries, ["existing"])

        store.record("fresh")
        XCTAssertEqual(store.entries, ["fresh", "existing"])
        XCTAssertEqual(persistence.stored.entries, ["fresh", "existing"])
    }

    /// Searching the same thing twice in a row is common; it should not cost a
    /// write each time.
    @MainActor
    func testRecordingAnUnchangedHistorySkipsTheWrite() {
        let persistence = InMemorySearchHistoryPersistence(SearchHistory(entries: ["only"]))
        let store = SearchHistoryStore(persistence: persistence)

        store.record("only")
        XCTAssertEqual(persistence.saveCount, 0)

        store.record("something else")
        XCTAssertEqual(persistence.saveCount, 1)
    }

    @MainActor
    func testRemovingAndClearingPersist() {
        let persistence = InMemorySearchHistoryPersistence(SearchHistory(entries: ["a", "b"]))
        let store = SearchHistoryStore(persistence: persistence)

        store.remove("a")
        XCTAssertEqual(persistence.stored.entries, ["b"])

        store.clear()
        XCTAssertTrue(persistence.stored.entries.isEmpty)
    }

    /// A corrupt or absent file must never surface an error — history is a
    /// convenience and losing it should be silent.
    func testFilePersistenceRecoversFromMissingAndCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("search-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = FileSearchHistoryPersistence(url: url)
        XCTAssertTrue(persistence.load().entries.isEmpty, "a missing file should read as empty")

        persistence.save(SearchHistory(entries: ["round", "trip"]))
        XCTAssertEqual(FileSearchHistoryPersistence(url: url).load().entries, ["round", "trip"])

        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(persistence.load().entries.isEmpty, "a corrupt file should read as empty")
    }
}
