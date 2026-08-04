import ShirKit
import SwiftUI

/// The always-present bar above the tab bar. Tapping it opens Now Playing.
struct MiniPlayerBar: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let track = playback.currentTrack {
                ArtworkView(url: track.artworkURL, size: 40, seed: abs(track.id.hashValue))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button {
                    playback.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.miniPlayerHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            let fraction = playback.duration > 0 ? playback.position / playback.duration : 0
            Rectangle()
                .fill(Theme.accent)
                .frame(width: proxy.size.width * min(max(fraction, 0), 1), height: 2)
        }
        .frame(height: 2)
    }
}
