import ShirKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var isImportingFiles = false
    @State private var importMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    playlistSection
                    if !library.localTracks.isEmpty { downloadsSection }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, Theme.miniPlayerHeight + 24)
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newPlaylistName = ""
                            isCreatingPlaylist = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                        }
                        Button {
                            isImportingFiles = true
                        } label: {
                            Label("Import Audio Files", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $isCreatingPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") { library.createPlaylist(named: newPlaylistName) }
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("Import", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var playlistSection: some View {
        if library.playlists.isEmpty {
            EmptyStateView(
                icon: "music.note.list",
                title: "No playlists yet",
                message: "Make a playlist, then fill it from Search or from files you import.",
                actionTitle: "Create Playlist"
            ) {
                newPlaylistName = ""
                isCreatingPlaylist = true
            }
            .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Playlists")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.primaryText)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistCard(playlist: playlist, trackCount: playlist.trackIDs.count)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                library.deletePlaylist(id: playlist.id)
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { playlistID in
                PlaylistDetailView(playlistID: playlistID)
            }
        }
    }

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button("Play All") {
                    playback.play(library.localTracks, startingAt: 0)
                }
                .font(.system(size: 14, weight: .medium))
                .tint(Theme.accent)
            }

            Text("These play in the background and on the lock screen.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            VStack(spacing: 0) {
                ForEach(Array(library.localTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, isCurrent: track.id == playback.currentTrack?.id)
                        .padding(.vertical, 6)
                        .onTapGesture {
                            playback.play(library.localTracks, startingAt: index)
                        }
                        .contextMenu {
                            TrackContextMenu(track: track)
                            Button(role: .destructive) {
                                appEnvironment.deleteLocalTrack(track)
                            } label: {
                                Label("Delete File", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task {
                let outcome = await LocalMediaImporter.importFiles(at: urls)
                for track in outcome.tracks { library.upsert(track) }

                if outcome.failures.isEmpty {
                    importMessage = "Added \(outcome.tracks.count) file\(outcome.tracks.count == 1 ? "" : "s")."
                } else {
                    importMessage = """
                    Added \(outcome.tracks.count). Couldn't add:
                    \(outcome.failures.joined(separator: "\n"))
                    """
                }
            }
        case let .failure(error):
            importMessage = error.localizedDescription
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    let trackCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.gradient(seed: playlist.artworkSeed))
                Image(systemName: "music.note")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .aspectRatio(1, contentMode: .fit)

            Text(playlist.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Text("\(trackCount) song\(trackCount == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
