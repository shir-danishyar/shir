import ShirKit
import SwiftUI

/// Shared long-press actions for a track. Kept in one place so search results,
/// favorites and playlists all offer the same options.
struct TrackContextMenu: View {
    let track: Track

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackCoordinator.self) private var playback

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

        Divider()

        Button(role: .destructive) {
            library.deleteTrack(id: track.id)
        } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }
}
