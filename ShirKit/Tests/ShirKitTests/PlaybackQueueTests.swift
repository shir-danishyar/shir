import XCTest
@testable import ShirKit

/// Fixed-sequence generator so shuffle assertions are deterministic.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeTracks(_ count: Int) -> [Track] {
    (0..<count).map { index in
        Track.youtube(videoID: "v\(index)", title: "Song \(index)", channelTitle: "Artist \(index)")
    }
}

final class PlaybackQueueTests: XCTestCase {
    func testEmptyQueueHasNoCurrentTrack() {
        let queue = PlaybackQueue()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.upNext, [])
    }

    func testLoadStartsAtRequestedIndex() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(5), startingAt: 2)
        XCTAssertEqual(queue.current?.id, "yt:v2")
        XCTAssertEqual(queue.upNext.map(\.id), ["yt:v3", "yt:v4"])
    }

    func testLoadClampsOutOfRangeStartIndex() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 99)
        XCTAssertEqual(queue.current?.id, "yt:v2")

        queue.load(makeTracks(3), startingAt: -4)
        XCTAssertEqual(queue.current?.id, "yt:v0")
    }

    func testAdvanceStopsAtEndWhenRepeatIsOff() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(2), startingAt: 1)
        XCTAssertNil(queue.advanceAtEndOfTrack())
        XCTAssertEqual(queue.current?.id, "yt:v1", "cursor should stay put when playback stops")
    }

    func testAdvanceWrapsWhenRepeatingAll() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 2)
        queue.repeatMode = .all
        XCTAssertEqual(queue.advanceAtEndOfTrack()?.id, "yt:v0")
    }

    func testAdvanceRepeatsSameTrackWhenRepeatingOne() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 1)
        queue.repeatMode = .one
        XCTAssertEqual(queue.advanceAtEndOfTrack()?.id, "yt:v1")
        XCTAssertEqual(queue.current?.id, "yt:v1")
    }

    func testSkipForwardIgnoresRepeatOne() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 0)
        queue.repeatMode = .one
        XCTAssertEqual(queue.skipForward()?.id, "yt:v1", "an explicit Next should move on, not replay")
    }

    func testSkipForwardWrapsEvenWithRepeatOff() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 2)
        XCTAssertEqual(queue.skipForward()?.id, "yt:v0")
    }

    func testSkipBackwardWrapsToEnd() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 0)
        XCTAssertEqual(queue.skipBackward()?.id, "yt:v2")
    }

    func testPlayNextInsertsDirectlyAfterCurrent() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 0)
        let extra = Track.youtube(videoID: "x", title: "Interrupt", channelTitle: "A")
        queue.playNext(extra)
        XCTAssertEqual(queue.items.map(\.id), ["yt:v0", "yt:x", "yt:v1", "yt:v2"])
        XCTAssertEqual(queue.current?.id, "yt:v0", "inserting must not move the cursor")
    }

    func testPlayLastAppends() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(2), startingAt: 0)
        queue.playLast(Track.youtube(videoID: "x", title: "Last", channelTitle: "A"))
        XCTAssertEqual(queue.items.last?.id, "yt:x")
    }

    func testPlayNextOnEmptyQueueStartsPlayback() {
        var queue = PlaybackQueue()
        queue.playNext(Track.youtube(videoID: "x", title: "Only", channelTitle: "A"))
        XCTAssertEqual(queue.current?.id, "yt:x")
    }

    func testRemovingBeforeCursorKeepsSameTrackPlaying() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(4), startingAt: 2)
        queue.remove(at: 0)
        XCTAssertEqual(queue.current?.id, "yt:v2")
    }

    func testRemovingCurrentTrackMovesToNextOne() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(4), startingAt: 1)
        queue.remove(at: 1)
        XCTAssertEqual(queue.current?.id, "yt:v2")
    }

    func testRemovingLastRemainingTrackClearsCursor() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(1), startingAt: 0)
        queue.remove(at: 0)
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isEmpty)
    }

    func testRemovingFinalTrackWhileItPlaysClampsCursor() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 2)
        queue.remove(at: 2)
        XCTAssertEqual(queue.current?.id, "yt:v1")
    }

    func testMoveKeepsCursorOnPlayingTrack() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(4), startingAt: 0)
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(queue.items.last?.id, "yt:v0")
        XCTAssertEqual(queue.current?.id, "yt:v0", "the song playing must not change when reordering")
    }

    func testShufflePinsCurrentTrackToFront() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(10), startingAt: 4)
        var generator = SeededGenerator(seed: 42)
        queue.toggleShuffle(using: &generator)

        XCTAssertTrue(queue.isShuffled)
        XCTAssertEqual(queue.current?.id, "yt:v4", "shuffling must not interrupt the current song")
        XCTAssertEqual(queue.items.count, 10)
        XCTAssertEqual(Set(queue.items.map(\.id)).count, 10, "shuffle must not drop or duplicate tracks")
    }

    func testUnshuffleRestoresOriginalOrderAndKeepsCurrentTrack() {
        var queue = PlaybackQueue()
        let tracks = makeTracks(8)
        queue.load(tracks, startingAt: 5)
        var generator = SeededGenerator(seed: 7)
        queue.toggleShuffle(using: &generator)
        queue.toggleShuffle(using: &generator)

        XCTAssertFalse(queue.isShuffled)
        XCTAssertEqual(queue.items.map(\.id), tracks.map(\.id))
        XCTAssertEqual(queue.current?.id, "yt:v5")
    }

    func testLoadingWhileShuffledPinsChosenTrack() {
        var queue = PlaybackQueue()
        queue.load(makeTracks(6), startingAt: 0)
        var generator = SeededGenerator(seed: 3)
        queue.toggleShuffle(using: &generator)
        queue.load(makeTracks(6), startingAt: 3, using: &generator)

        XCTAssertEqual(queue.current?.id, "yt:v3")
        XCTAssertEqual(Set(queue.items.map(\.id)).count, 6)
    }

    func testRepeatModeCyclesThroughAllStates() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testQueueSurvivesRoundTripEncoding() throws {
        var queue = PlaybackQueue()
        queue.load(makeTracks(3), startingAt: 1)
        queue.repeatMode = .all

        let data = try JSONEncoder().encode(queue)
        let restored = try JSONDecoder().decode(PlaybackQueue.self, from: data)

        XCTAssertEqual(restored.current?.id, "yt:v1")
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertEqual(restored.items.map(\.id), queue.items.map(\.id))
    }
}
