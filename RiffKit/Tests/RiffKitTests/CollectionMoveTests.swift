import XCTest
@testable import RiffKit

/// The reimplementation of SwiftUI's move semantics is load-bearing for both
/// playlist reordering and queue reordering, so it is pinned down directly.
final class CollectionMoveTests: XCTestCase {
    func testMovingFirstElementToEnd() {
        var items = ["a", "b", "c", "d"]
        items.moveElements(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(items, ["b", "c", "d", "a"])
    }

    func testMovingLastElementToFront() {
        var items = ["a", "b", "c", "d"]
        items.moveElements(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(items, ["d", "a", "b", "c"])
    }

    func testMovingIntoTheMiddle() {
        var items = ["a", "b", "c", "d"]
        items.moveElements(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(items, ["b", "a", "c", "d"])
    }

    func testMovingMultipleNonAdjacentElements() {
        var items = ["a", "b", "c", "d", "e"]
        items.moveElements(fromOffsets: IndexSet([0, 2]), toOffset: 5)
        XCTAssertEqual(items, ["b", "d", "e", "a", "c"])
    }

    func testMovingToSamePositionIsANoOp() {
        var items = ["a", "b", "c"]
        items.moveElements(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        XCTAssertEqual(items, ["a", "b", "c"])
    }

    func testOutOfRangeOffsetsAreIgnored() {
        var items = ["a", "b"]
        items.moveElements(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        XCTAssertEqual(items, ["a", "b"])
    }

    func testEmptyCollectionIsUnchanged() {
        var items: [String] = []
        items.moveElements(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        XCTAssertTrue(items.isEmpty)
    }
}
