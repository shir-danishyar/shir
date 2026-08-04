import Foundation

public extension RangeReplaceableCollection where Index == Int {
    /// Reorders elements the way SwiftUI's `onMove` reports them.
    ///
    /// SwiftUI ships its own `move(fromOffsets:toOffset:)`, but it lives in
    /// SwiftUI rather than the standard library. Reimplementing it here keeps
    /// the queue and library logic free of any UI framework, so both stay
    /// testable on any platform.
    ///
    /// `destination` is an insertion point in the *pre-move* collection, so
    /// moving element 0 to the end of a four-item list means `toOffset: 4`.
    ///
    /// Named `moveElements` rather than `move` because SwiftUI's version is
    /// visible anywhere SwiftUI is imported, and two candidates on the same
    /// type make every call site ambiguous.
    mutating func moveElements(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filter { indices.contains($0) }
        guard !valid.isEmpty else { return }

        let moved = valid.map { self[$0] }
        // How many extracted elements sat before the insertion point — the
        // destination shifts back by that much once they are pulled out.
        let removedBefore = valid.filter { $0 < destination }.count
        // Qualified because inside a Collection extension these resolve to
        // Sequence.min()/max() rather than the global functions.
        let insertionIndex = Swift.max(0, Swift.min(destination - removedBefore, count - moved.count))

        for index in valid.sorted(by: >) {
            remove(at: index)
        }
        insert(contentsOf: moved, at: startIndex + insertionIndex)
    }
}
