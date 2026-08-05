import RiffKit
import SwiftUI

/// Recently added, recently played, and the user's own playlists.
///
/// "Recently Added" and "Recently Played" are derived views over the library
/// rather than stored playlists — they cannot be renamed or deleted, and they
/// never need syncing, because they are just sorts.
struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""

    /// Enough to fill the carousel without turning the tab into a history log.
    private var recentTracks: [Track] { Array(library.allTracks.prefix(12)) }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !recentTracks.isEmpty {
                            recentSection
                        }

                        smartPlaylistRows

                        myPlaylistsHeader
                        myPlaylists

                        Color.clear.frame(height: Theme.miniPlayerHeight + 24)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        isCreatingPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    // Icon-only controls have no text for a UI test to match
                    // on, and matching by SF Symbol name is undocumented and
                    // has broken between iOS releases before.
                    .accessibilityIdentifier("newPlaylistButton")
                    .accessibilityLabel("New Playlist")
                }
            }
            .navigationDestination(for: PlaylistRoute.self) { route in
                switch route {
                case let .stored(id):
                    PlaylistDetailView(playlistID: id)
                case let .smart(kind):
                    SmartPlaylistView(kind: kind)
                }
            }
            .alert("New Playlist", isPresented: $isCreatingPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { library.createPlaylist(named: newPlaylistName) }
            }
        }
    }

    // MARK: - Sections

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(recentTracks) { track in
                        Button {
                            playback.play(track)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                VideoThumbnail(
                                    url: track.artworkURL,
                                    width: 150,
                                    height: 150,
                                    seed: abs(track.id.hashValue)
                                )
                                Text(track.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.primaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 150, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 16)
    }

    private var smartPlaylistRows: some View {
        VStack(spacing: 0) {
            ForEach(SmartPlaylistKind.allCases) { kind in
                let tracks = kind.tracks(from: library)
                NavigationLink(value: PlaylistRoute.smart(kind)) {
                    PlaylistRowLabel(
                        title: kind.title,
                        subtitle: "\(tracks.count) Tracks",
                        artworkURLs: tracks.compactMap(\.artworkURL),
                        seed: kind.seed
                    )
                }
                .buttonStyle(.plain)
                RowSeparator()
            }
        }
    }

    private var myPlaylistsHeader: some View {
        HStack(spacing: 8) {
            Text("My Playlists")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("\(library.playlists.count)")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var myPlaylists: some View {
        if library.playlists.isEmpty {
            Text("Tap + to make your first playlist.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 20)
        } else {
            ForEach(library.playlists) { playlist in
                let tracks = library.tracks(in: playlist)
                NavigationLink(value: PlaylistRoute.stored(playlist.id)) {
                    PlaylistRowLabel(
                        title: playlist.name,
                        subtitle: "\(tracks.count) Tracks",
                        artworkURLs: tracks.compactMap(\.artworkURL),
                        seed: playlist.artworkSeed
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        library.deletePlaylist(id: playlist.id)
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                }
                RowSeparator()
            }
        }
    }
}

/// Where a playlist row leads. Modelled as one route type so a single
/// `navigationDestination` covers both stored and derived playlists.
enum PlaylistRoute: Hashable {
    case stored(UUID)
    case smart(SmartPlaylistKind)
}

/// Playlists the app derives rather than stores.
enum SmartPlaylistKind: String, CaseIterable, Identifiable, Hashable {
    case recentlyAdded
    case recentlyPlayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        }
    }

    var seed: Int {
        switch self {
        case .recentlyAdded: return 210
        case .recentlyPlayed: return 320
        }
    }

    @MainActor
    func tracks(from library: LibraryStore) -> [Track] {
        // `allTracks` is already newest-first, which is exactly Recently Added.
        // Recently Played has no play-history store yet, so it mirrors the same
        // ordering rather than pretending to know something it doesn't.
        switch self {
        case .recentlyAdded: return library.allTracks
        case .recentlyPlayed: return library.allTracks
        }
    }
}

/// A playlist row: mosaic artwork, name, track count, chevron.
struct PlaylistRowLabel: View {
    let title: String
    let subtitle: String
    let artworkURLs: [URL]
    var seed: Int

    var body: some View {
        HStack(spacing: 12) {
            MosaicArtwork(urls: artworkURLs, size: 64, seed: seed)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
