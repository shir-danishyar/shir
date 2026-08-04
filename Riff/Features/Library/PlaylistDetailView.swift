import RiffKit
import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var isRenaming = false
    @State private var draftName = ""

    private var playlist: Playlist? { library.playlist(id: playlistID) }
    private var tracks: [Track] { playlist.map { library.tracks(in: $0) } ?? [] }

    var body: some View {
        List {
            if let playlist {
                Section {
                    header(for: playlist)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if tracks.isEmpty {
                EmptyStateView(
                    icon: "plus.circle",
                    title: "No songs yet",
                    message: "Find music in Search, then use “Add to Playlist”."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, isCurrent: track.id == playback.currentTrack?.id)
                        .contentShape(Rectangle())
                        .onTapGesture { playback.play(tracks, startingAt: index) }
                        .listRowBackground(Theme.surface)
                        .contextMenu { TrackContextMenu(track: track) }
                }
                .onDelete { offsets in
                    for index in offsets {
                        library.remove(trackID: tracks[index].id, fromPlaylist: playlistID)
                    }
                }
                .onMove { offsets, destination in
                    library.moveTracks(inPlaylist: playlistID, fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = playlist?.name ?? ""
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    EditButton()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") { library.renamePlaylist(id: playlistID, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func header(for playlist: Playlist) -> some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.gradient(seed: playlist.artworkSeed))
                .frame(width: 180, height: 180)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.9))
                }

            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            HStack(spacing: 12) {
                Button {
                    playback.play(tracks, startingAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    playback.shufflePlay(tracks)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Shared long-press actions for a track. Kept in one place so search results,
/// playlists and downloads all offer the same options.
struct TrackContextMenu: View {
    let track: Track

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var isChoosingPlaylist = false

    var body: some View {
        Button {
            playback.playNext(track)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            playback.playLast(track)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Menu {
            if library.playlists.isEmpty {
                Text("No playlists yet")
            } else {
                ForEach(library.playlists) { playlist in
                    Button {
                        library.add(track, toPlaylist: playlist.id)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "plus")
        }
    }
}
