import ShirKit
import SwiftUI

/// One song in a list. Shared by search results, playlists and the queue so
/// they stay visually identical.
struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false
    var showsSourceBadge: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, size: 48, seed: abs(track.id.hashValue))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if showsSourceBadge {
                        SourceBadge(source: track.source)
                    }
                    Text(track.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let duration = track.duration {
                Text(duration.formattedPlaybackTime)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Tells the two sources apart at a glance, which matters because they behave
/// differently: only downloads keep playing in the background.
struct SourceBadge: View {
    let source: MediaSource

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private var label: String {
        switch source {
        case .youtube: return "YOUTUBE"
        case .localFile: return "OFFLINE"
        }
    }

    private var color: Color {
        switch source {
        case .youtube: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .localFile: return Color(red: 0.35, green: 0.8, blue: 0.55)
        }
    }
}
