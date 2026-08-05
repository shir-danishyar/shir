import ShirKit
import SwiftUI

/// The bar above the tab bar. Tapping it opens Now Playing.
///
/// The reference has no artwork here, which is worth copying rather than
/// "improving": with the title centred and only one control on the right, the
/// bar reads as a status line rather than a second, competing player. The
/// progress hairline sits along the very top edge.
struct MiniPlayerBar: View {
    @Environment(PlaybackCoordinator.self) private var playback
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            progressLine

            HStack(spacing: 10) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30)

                VStack(spacing: 1) {
                    Text(playback.currentTrack?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(playback.currentTrack?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                Button {
                    playback.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 34, height: 34)
                        Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.miniPlayerHeight)
        }
        .background(Theme.surfaceRaised)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
