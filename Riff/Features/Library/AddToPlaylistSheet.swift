import RiffKit
import SwiftUI

/// Where a song goes when you tap `+`.
///
/// Every row is a toggle, so the sheet doubles as "which lists is this song
/// already in" — the checkmarks are the answer. My Favorites sits at the top
/// alongside the user's own playlists because that is what it is: one list
/// among several, not a synonym for the library.
struct AddToPlaylistSheet: View {
    let track: Track

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        trackCard

                        Divider()
                            .overlay(Theme.separator)
                            .padding(.vertical, 8)

                        createRow
                        RowSeparator()

                        favoritesRow
                        RowSeparator()

                        ForEach(library.playlists) { playlist in
                            playlistRow(playlist)
                            RowSeparator()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Add To Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .alert("New Playlist", isPresented: $isCreatingPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    // Creating from here means "put this song in it" — landing
                    // on an empty new playlist would be a dead end.
                    let playlist = library.createPlaylist(named: newPlaylistName)
                    library.add(track, toPlaylist: playlist.id)
                }
            }
        }
    }

    // MARK: - Rows

    private var trackCard: some View {
        HStack(spacing: 12) {
            VideoThumbnail(
                url: track.artworkURL,
                width: 62,
                height: 62,
                seed: abs(track.id.hashValue)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(track.artist)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var createRow: some View {
        Button {
            newPlaylistName = ""
            isCreatingPlaylist = true
        } label: {
            HStack(spacing: 14) {
                iconTile("plus", tint: Theme.accent)
                Text("Create New Playlist")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.accent)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("createPlaylistRow")
    }

    private var favoritesRow: some View {
        Button {
            library.toggleFavorite(track)
        } label: {
            HStack(spacing: 14) {
                iconTile("heart.fill", tint: Theme.secondaryText)
                Text("My Favorites")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                checkmark(isOn: library.isFavorite(track.id))
            }
            .padding(.horizontal, 12)
            .frame(height: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favoritesRow")
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let tracks = library.tracks(in: playlist)
        return Button {
            library.toggle(track, inPlaylist: playlist.id)
        } label: {
            HStack(spacing: 14) {
                MosaicArtwork(
                    urls: tracks.compactMap(\.artworkURL),
                    size: 58,
                    seed: playlist.artworkSeed
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text("\(tracks.count) Track\(tracks.count == 1 ? "" : "s")")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                }

                Spacer()
                checkmark(isOn: playlist.trackIDs.contains(track.id))
            }
            .padding(.horizontal, 12)
            .frame(height: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private func iconTile(_ symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.field)
            .frame(width: 58, height: 58)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(tint)
            }
    }

    /// Reserves its slot whether or not it is showing, so rows don't shift when
    /// a checkmark appears.
    private func checkmark(isOn: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .opacity(isOn ? 1 : 0)
            .frame(width: 30)
    }
}
