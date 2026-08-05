import RiffKit
import SwiftUI

/// The shared body of every "a pile of songs with a header" screen.
///
/// Playlist detail and the derived playlists render identically — mosaic
/// artwork, title, count and duration, Shuffle Play, then the list. Only the
/// data and the toolbar differ, so the layout lives here once and the two
/// screens supply the rest. Duplicating this was the obvious alternative and
/// would have meant fixing every spacing tweak twice.
struct TrackCollectionView<Toolbar: ToolbarContent>: View {
    let title: String
    let tracks: [Track]
    var seed: Int = 0
    var onDelete: ((IndexSet) -> Void)?
    @ToolbarContentBuilder var toolbar: () -> Toolbar

    @Environment(PlaybackCoordinator.self) private var playback

    private var totalDuration: TimeInterval {
        tracks.compactMap(\.duration).reduce(0, +)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    header

                    if tracks.isEmpty {
                        EmptyStateView(
                            icon: "music.note.list",
                            title: "No songs yet",
                            message: "Add songs from Search, or from a song's ••• menu."
                        )
                        .padding(.top, 30)
                    } else {
                        ShufflePlayButton { playback.shufflePlay(tracks) }

                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                playback.play(tracks, startingAt: index)
                            } label: {
                                TrackRow(
                                    track: track,
                                    isCurrent: playback.currentTrack?.id == track.id
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                TrackContextMenu(track: track)
                                if let onDelete {
                                    Divider()
                                    Button(role: .destructive) {
                                        onDelete(IndexSet(integer: index))
                                    } label: {
                                        Label("Remove from Playlist", systemImage: "minus.circle")
                                    }
                                }
                            }

                            if index < tracks.count - 1 { RowSeparator() }
                        }
                    }

                    Color.clear.frame(height: Theme.miniPlayerHeight + 24)
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(content: toolbar)
    }

    private var header: some View {
        VStack(spacing: 6) {
            MosaicArtwork(
                urls: tracks.compactMap(\.artworkURL),
                size: 170,
                seed: seed
            )
            .padding(.top, 8)

            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 10)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        let count = "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
        guard totalDuration > 0 else { return count }
        return "\(count) · \(Self.formatted(totalDuration))"
    }

    /// "4h 5m" / "12m" — a coarser format than the scrubber's clock, because at
    /// playlist length the seconds are noise.
    private static func formatted(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// A playlist the user made.
struct PlaylistDetailView: View {
    let playlistID: UUID

    @Environment(LibraryStore.self) private var library
    @State private var isRenaming = false
    @State private var draftName = ""

    private var playlist: Playlist? { library.playlist(id: playlistID) }
    private var tracks: [Track] { playlist.map { library.tracks(in: $0) } ?? [] }

    var body: some View {
        TrackCollectionView(
            title: playlist?.name ?? "Playlist",
            tracks: tracks,
            seed: playlist?.artworkSeed ?? 0,
            onDelete: remove
        ) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = playlist?.name ?? ""
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        library.deletePlaylist(id: playlistID)
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.renamePlaylist(id: playlistID, to: draftName) }
        }
    }

    private func remove(at offsets: IndexSet) {
        for index in offsets {
            guard tracks.indices.contains(index) else { continue }
            library.remove(trackID: tracks[index].id, fromPlaylist: playlistID)
        }
    }
}

/// A playlist the app derives — Recently Added and friends. Read-only, so no
/// rename, no delete, no per-row removal.
struct SmartPlaylistView: View {
    let kind: SmartPlaylistKind

    @Environment(LibraryStore.self) private var library

    var body: some View {
        TrackCollectionView(
            title: kind.title,
            tracks: kind.tracks(from: library),
            seed: kind.seed
        ) {
            ToolbarItem(placement: .topBarTrailing) { EmptyView() }
        }
    }
}
