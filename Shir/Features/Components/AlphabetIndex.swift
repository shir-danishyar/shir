import ShirKit
import SwiftUI

/// Groups tracks into the alphabetical sections the library list is built from.
///
/// Kept as a plain value type with a static function so it can be reasoned
/// about (and tested) without a view. Anything that isn't a letter lands in
/// `#`, which is where non-Latin titles go — a large part of a real library.
struct TrackSection: Identifiable {
    let letter: String
    let tracks: [Track]
    var id: String { letter }

    static func sections(for tracks: [Track]) -> [TrackSection] {
        var buckets: [String: [Track]] = [:]

        for track in tracks {
            buckets[letter(for: track.title), default: []].append(track)
        }

        // "#" sorts before the letters rather than after, matching the reference.
        let letters = buckets.keys.sorted { lhs, rhs in
            if lhs == "#" { return rhs != "#" }
            if rhs == "#" { return false }
            return lhs < rhs
        }

        return letters.map { letter in
            TrackSection(
                letter: letter,
                tracks: buckets[letter, default: []].sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            )
        }
    }

    private static func letter(for title: String) -> String {
        guard let first = title.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return "#"
        }
        // `isLetter` is true for Arabic and Cyrillic too, so restrict to the
        // Latin alphabet the index actually offers.
        let upper = String(first).uppercased()
        guard let scalar = upper.unicodeScalars.first,
              ("A"..."Z").contains(upper), scalar.isASCII else {
            return "#"
        }
        return upper
    }
}

/// The floating letter strip pinned to the right edge.
///
/// A dark pill with accent-coloured letters. It only lists the sections that
/// exist, so a library of five songs shows five letters rather than the whole
/// alphabet greyed out.
struct AlphabetIndexBar: View {
    let letters: [String]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 15)
            }
        }
        .padding(.vertical, 8)
        .background(Theme.indexPill, in: Capsule())
        .contentShape(Capsule())
        // A drag scrubs through letters the way a system index does; a plain
        // tap would mean aiming at a 15pt target.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !letters.isEmpty else { return }
                    let rowHeight: CGFloat = 17
                    let index = Int(value.location.y / rowHeight)
                    guard letters.indices.contains(index) else { return }
                    onSelect(letters[index])
                }
        )
    }
}
