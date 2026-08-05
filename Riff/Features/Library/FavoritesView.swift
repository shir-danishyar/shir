import RiffKit
import SwiftUI

/// The songs you hearted, alphabetised, with a letter index down the right
/// edge.
///
/// This is a list you build deliberately, not everything the app has ever
/// touched — playing a song from Search does not put it here.
///
/// This is a plain `ScrollView` rather than a `List` on purpose. The reference
/// draws full-bleed black rows with hairlines inset under the text and a
/// floating index pill — all of which means fighting `List`'s insets,
/// backgrounds and separators on every row. Laying it out directly is less code
/// and gives exact control, and the row count here is small enough that
/// `LazyVStack` handles it comfortably.
struct FavoritesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

    private var tracks: [Track] { library.favorites }
    private var sections: [TrackSection] { TrackSection.sections(for: tracks) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                Theme.background.ignoresSafeArea()

                if tracks.isEmpty {
                    EmptyStateView(
                        icon: "heart",
                        title: "No songs yet",
                        message: "Tap the heart on a song, or use + in Search, to add it here."
                    )
                } else {
                    trackList
                    indexBar
                }
            }
            .navigationTitle("My Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ShufflePlayButton { playback.shufflePlay(tracks) }

                    ForEach(sections) { section in
                        Section {
                            ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                                Button {
                                    play(track)
                                } label: {
                                    TrackRow(
                                        track: track,
                                        isCurrent: playback.currentTrack?.id == track.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TrackContextMenu(track: track) }

                                if index < section.tracks.count - 1 { RowSeparator() }
                            }
                        } header: {
                            SectionHeaderBar(title: section.letter).id(section.letter)
                        }
                    }

                    // Clearance so the last row isn't trapped under the mini
                    // player and the tab bar.
                    Color.clear.frame(height: Theme.miniPlayerHeight + 24)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollTarget) { _, letter in
                guard let letter else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(letter, anchor: .top)
                }
            }
        }
    }

    @State private var scrollTarget: String?

    private var indexBar: some View {
        AlphabetIndexBar(letters: sections.map(\.letter)) { letter in
            scrollTarget = nil          // re-trigger even for the same letter
            scrollTarget = letter
        }
        .padding(.trailing, 2)
        .padding(.top, 120)
    }

    /// Plays the whole library from the tapped song, so Next continues down the
    /// list rather than stopping — the behaviour a music app is expected to
    /// have, and the reason the flat `tracks` array is used rather than the
    /// section's slice.
    private func play(_ track: Track) {
        let ordered = sections.flatMap(\.tracks)
        guard let index = ordered.firstIndex(where: { $0.id == track.id }) else { return }
        playback.play(ordered, startingAt: index)
    }
}
