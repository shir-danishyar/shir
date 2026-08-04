import RiffKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingQueue = false
    @State private var scrubPosition: TimeInterval = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                handle
                stage
                    .padding(.top, 8)
                trackInfo
                    .padding(.top, 24)
                scrubber
                    .padding(.top, 20)
                transportControls
                    .padding(.top, 12)
                secondaryControls
                    .padding(.top, 24)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $isShowingQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
    }

    private var handle: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 40, height: 40)
            }
            Spacer()
            Text(playback.isPlayingYouTube ? "Playing from YouTube" : "Playing from your library")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button {
                isShowingQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 40, height: 40)
            }
        }
    }

    /// The video for YouTube tracks, artwork for local ones. The web view is
    /// always mounted while a YouTube track is loaded — never hidden behind
    /// artwork — because the embedded player has to remain visible.
    @ViewBuilder
    private var stage: some View {
        if playback.isPlayingYouTube {
            YouTubePlayerView(webView: playback.youtubeEngine.webView)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .background(Color.black)
        } else {
            ArtworkView(
                url: playback.currentTrack?.artworkURL,
                size: 300,
                cornerRadius: 16,
                seed: abs(playback.currentTrack?.id.hashValue ?? 0)
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(playback.currentTrack?.title ?? "Nothing playing")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(playback.currentTrack?.artist ?? "")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { playback.isScrubbing ? scrubPosition : playback.position },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    playback.isScrubbing = editing
                    if editing {
                        scrubPosition = playback.position
                    } else {
                        playback.seek(to: scrubPosition)
                    }
                }
            )
            .tint(Theme.accent)

            HStack {
                Text((playback.isScrubbing ? scrubPosition : playback.position).formattedPlaybackTime)
                Spacer()
                Text(playback.duration > 0 ? playback.duration.formattedPlaybackTime : "--:--")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 36) {
            Button { playback.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26))
            }

            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 68, height: 68)
                    if playback.status == .buffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: playback.status.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
            }

            Button { playback.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26))
            }
        }
        .foregroundStyle(Theme.primaryText)
        .buttonStyle(.plain)
    }

    private var secondaryControls: some View {
        HStack(spacing: 44) {
            Button { playback.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playback.isShuffled ? Theme.accent : Theme.secondaryText)
            }
            Button { playback.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon)
                    .foregroundStyle(playback.repeatMode == .off ? Theme.secondaryText : Theme.accent)
            }
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
    }

    private var repeatIcon: String {
        switch playback.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}
