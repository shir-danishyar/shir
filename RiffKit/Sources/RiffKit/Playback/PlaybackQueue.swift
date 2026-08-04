import Foundation

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// The play order and cursor. Pure value semantics, no playback engine
/// knowledge, so every transition is testable without audio hardware.
///
/// Shuffle keeps `sourceOrder` untouched and reorders `items`. Turning shuffle
/// off restores the original order and re-points the cursor at whatever is
/// currently playing, which is what a listener expects — the current song
/// should not change just because they toggled a mode.
public struct PlaybackQueue: Codable, Equatable, Sendable {
    public private(set) var items: [Track] = []
    public private(set) var currentIndex: Int?
    public private(set) var isShuffled: Bool = false
    public var repeatMode: RepeatMode = .off

    private var sourceOrder: [Track] = []

    public init() {}

    public var current: Track? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Tracks lined up after the current one, for the Up Next list.
    public var upNext: [Track] {
        guard let currentIndex, currentIndex + 1 < items.count else { return [] }
        return Array(items[(currentIndex + 1)...])
    }

    // MARK: - Loading

    /// Replaces the queue. When shuffle is on, the chosen track is moved to the
    /// front and the rest are shuffled behind it.
    public mutating func load<G: RandomNumberGenerator>(
        _ tracks: [Track],
        startingAt index: Int,
        using generator: inout G
    ) {
        sourceOrder = tracks
        guard !tracks.isEmpty else {
            items = []
            currentIndex = nil
            return
        }
        let start = min(max(index, 0), tracks.count - 1)
        if isShuffled {
            items = Self.shuffled(tracks, pinning: start, using: &generator)
            currentIndex = 0
        } else {
            items = tracks
            currentIndex = start
        }
    }

    public mutating func load(_ tracks: [Track], startingAt index: Int = 0) {
        var generator = SystemRandomNumberGenerator()
        load(tracks, startingAt: index, using: &generator)
    }

    public mutating func clear() {
        items = []
        sourceOrder = []
        currentIndex = nil
    }

    // MARK: - Cursor movement

    /// Advances for a natural end-of-song.
    ///
    /// `.one` repeats the current track, `.all` wraps to the start, `.off`
    /// stops at the end and reports nil so the coordinator can halt playback.
    @discardableResult
    public mutating func advanceAtEndOfTrack() -> Track? {
        guard let currentIndex, !items.isEmpty else { return nil }
        if repeatMode == .one { return items[currentIndex] }
        return step(to: currentIndex + 1, wrapping: repeatMode == .all)
    }

    /// Advances for an explicit tap on Next.
    ///
    /// Deliberately ignores `.one` — a user pressing Next wants the next song,
    /// not the same one again. It still wraps, because reaching the end of a
    /// queue via the button feels broken if nothing happens.
    @discardableResult
    public mutating func skipForward() -> Track? {
        guard let currentIndex, !items.isEmpty else { return nil }
        return step(to: currentIndex + 1, wrapping: true)
    }

    @discardableResult
    public mutating func skipBackward() -> Track? {
        guard let currentIndex, !items.isEmpty else { return nil }
        return step(to: currentIndex - 1, wrapping: true)
    }

    @discardableResult
    public mutating func jump(to index: Int) -> Track? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return items[index]
    }

    private mutating func step(to index: Int, wrapping: Bool) -> Track? {
        if items.indices.contains(index) {
            currentIndex = index
            return items[index]
        }
        guard wrapping else { return nil }
        let wrapped = index < 0 ? items.count - 1 : 0
        currentIndex = wrapped
        return items[wrapped]
    }

    // MARK: - Editing

    /// Inserts right after the current track.
    public mutating func playNext(_ track: Track) {
        guard let currentIndex else {
            items.append(track)
            sourceOrder.append(track)
            self.currentIndex = 0
            return
        }
        items.insert(track, at: currentIndex + 1)
        sourceOrder.append(track)
    }

    public mutating func playLast(_ track: Track) {
        items.append(track)
        sourceOrder.append(track)
        if currentIndex == nil { currentIndex = 0 }
    }

    /// Removes a track, keeping the cursor on the same song wherever possible.
    public mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removed = items.remove(at: index)
        sourceOrder.removeAll { $0.id == removed.id }

        guard let cursor = currentIndex else { return }
        if items.isEmpty {
            currentIndex = nil
        } else if index < cursor {
            currentIndex = cursor - 1
        } else if index == cursor {
            currentIndex = min(cursor, items.count - 1)
        }
    }

    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let playing = current
        items.moveElements(fromOffsets: offsets, toOffset: destination)
        if let playing, let index = items.firstIndex(where: { $0.id == playing.id }) {
            currentIndex = index
        }
    }

    // MARK: - Shuffle

    public mutating func toggleShuffle<G: RandomNumberGenerator>(using generator: inout G) {
        if isShuffled {
            isShuffled = false
            guard let playing = current else {
                items = sourceOrder
                currentIndex = sourceOrder.isEmpty ? nil : 0
                return
            }
            items = sourceOrder
            currentIndex = items.firstIndex { $0.id == playing.id } ?? 0
        } else {
            isShuffled = true
            guard let cursor = currentIndex else {
                items = sourceOrder.shuffled(using: &generator)
                return
            }
            items = Self.shuffled(items, pinning: cursor, using: &generator)
            currentIndex = 0
        }
    }

    public mutating func toggleShuffle() {
        var generator = SystemRandomNumberGenerator()
        toggleShuffle(using: &generator)
    }

    /// Moves `pinned` to the front and shuffles everything after it.
    private static func shuffled<G: RandomNumberGenerator>(
        _ tracks: [Track],
        pinning pinned: Int,
        using generator: inout G
    ) -> [Track] {
        guard tracks.indices.contains(pinned) else { return tracks.shuffled(using: &generator) }
        var rest = tracks
        let head = rest.remove(at: pinned)
        return [head] + rest.shuffled(using: &generator)
    }
}
