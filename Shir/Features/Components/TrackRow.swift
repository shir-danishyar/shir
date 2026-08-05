import ShirKit
import SwiftUI

/// One song in a list.
///
/// The reference marks the currently playing row by turning *both* lines of
/// text the accent colour — no highlight bar, no icon, no bold weight. That is
/// the entire treatment, and it reads clearly against the black background.
struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false
    var accessory: Accessory = .none
    var onAccessory: (() -> Void)?

    enum Accessory {
        case none
        /// Pink `+`, for adding to the library or a playlist.
        case add
        /// Chevron, for rows that push a new screen.
        case disclosure
    }

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(url: track.artworkURL, seed: abs(track.id.hashValue))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch accessory {
            case .none:
                EmptyView()
            case .add:
                Button { onAccessory?() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 44)
                }
                // Without .plain the button swallows the whole row's tap.
                .buttonStyle(.plain)
            case .disclosure:
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.rowHeight)
        .contentShape(Rectangle())
    }
}

/// A search result. Carries a channel rather than an artist, shows the duration
/// on the thumbnail, and allows two lines of title because YouTube titles are
/// long and the first line alone is often useless.
struct SearchResultRow: View {
    let video: YouTubeVideo
    var isInLibrary: Bool
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VideoThumbnail(
                url: video.thumbnailURL,
                duration: video.duration,
                seed: abs(video.id.hashValue)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(Theme.rowTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(video.channelTitle)
                    .font(Theme.rowSubtitle)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAdd) {
                Image(systemName: isInLibrary ? "checkmark" : "plus")
                    .font(.system(size: 22))
                    .foregroundStyle(isInLibrary ? Theme.secondaryText : Theme.accent)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isInLibrary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// A hairline starting under the text rather than under the artwork — what
/// makes a dense list read as grouped instead of striped.
struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, Theme.separatorInset)
    }
}

/// The bold letter band between alphabetical groups.
struct SectionHeaderBar: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.sectionHeader)
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Theme.surface)
    }
}

/// Centred pink "Shuffle Play", which sits above every track list.
struct ShufflePlayButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                Text("Shuffle Play")
                    .font(.system(size: 20))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Tells the two sources apart, which matters because they behave differently:
/// only imported files keep playing with the screen off.
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
        case .youtube: return Theme.accent
        case .localFile: return Color(red: 0.35, green: 0.8, blue: 0.55)
        }
    }
}
