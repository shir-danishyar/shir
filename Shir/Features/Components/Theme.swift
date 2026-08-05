import SwiftUI

/// The visual language, sampled pixel-by-pixel from the reference screenshots
/// rather than eyeballed. Every value here came out of an actual screenshot;
/// see `docs/design-notes.md` for the sampling method.
enum Theme {

    // MARK: - Colour
    //
    // The accent appears identically on the transport button, progress fill,
    // heart, add button and active tab — one colour, used everywhere.

    static let accent = Color(hex: 0xE24D68)

    /// True black. The list body is #000000, not a dark grey — the contrast
    /// against the raised bars is a big part of why the reference looks the way
    /// it does, so don't "soften" this.
    static let background = Color.black

    /// Nav bars and the letter-section headers.
    static let surface = Color(hex: 0x0F0F0F)
    /// Tab bar and mini player.
    static let surfaceRaised = Color(hex: 0x202020)
    /// Search fields, unfilled slider track.
    static let field = Color(hex: 0x333333)
    /// The floating alphabet index pill.
    static let indexPill = Color(hex: 0x141414)

    static let primaryText = Color.white
    static let secondaryText = Color(hex: 0x999999)
    static let tabInactive = Color(hex: 0x929292)
    static let separator = Color(hex: 0x262626)

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 12
    /// Thumbnails are 16:9, matching the video they represent.
    static let thumbWidth: CGFloat = 74
    static let thumbHeight: CGFloat = 44
    static let thumbCorner: CGFloat = 4
    static let rowHeight: CGFloat = 64
    static let miniPlayerHeight: CGFloat = 58
    /// Left inset for row separators so they start under the text, not the art.
    static var separatorInset: CGFloat { thumbWidth + 22 }

    // MARK: - Type
    //
    // The reference uses a notably large row title for a list of this density,
    // which is what makes it feel like a music app rather than a file browser.

    static let rowTitle = Font.system(size: 17, weight: .regular)
    static let rowSubtitle = Font.system(size: 15, weight: .regular)
    static let sectionHeader = Font.system(size: 20, weight: .bold)
    static let navTitle = Font.system(size: 17, weight: .semibold)
    static let nowPlayingTitle = Font.system(size: 26, weight: .bold)

    /// Deterministic cover art for a playlist with no tracks, derived from its
    /// stored seed so the same playlist always looks the same.
    static func gradient(seed: Int) -> LinearGradient {
        let hue = Double(seed % 360) / 360
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.78),
                Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    /// `Color(hex: 0xE24D68)` — sampled values are written as hex everywhere
    /// else in the design world, so store them that way rather than converting
    /// to decimal fractions by hand and introducing rounding drift.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Artwork

/// A 16:9 video thumbnail with an optional duration badge, as used in every
/// track row and search result.
struct VideoThumbnail: View {
    let url: URL?
    var width: CGFloat = Theme.thumbWidth
    var height: CGFloat = Theme.thumbHeight
    var duration: TimeInterval?
    var seed: Int = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: width, height: height)
            .clipped()

            if let duration, duration > 0 {
                Text(duration.formattedPlaybackTime)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
                    .padding(2)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.thumbCorner, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Theme.gradient(seed: seed)
            Image(systemName: "music.note")
                .font(.system(size: height * 0.4))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Square artwork built from up to four track thumbnails, the way playlists are
/// represented in the reference. One track fills the square; four make a 2x2.
struct MosaicArtwork: View {
    let urls: [URL]
    var size: CGFloat = 64
    var seed: Int = 0

    var body: some View {
        Group {
            switch urls.count {
            case 0:
                Theme.gradient(seed: seed)
            case 1:
                tile(urls[0])
            default:
                let four = Array(urls.prefix(4))
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(four[0])
                        tile(four.count > 1 ? four[1] : four[0])
                    }
                    HStack(spacing: 0) {
                        tile(four.count > 2 ? four[2] : four[0])
                        tile(four.count > 3 ? four[3] : four[min(1, four.count - 1)])
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func tile(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image): image.resizable().aspectRatio(contentMode: .fill)
            default: Theme.gradient(seed: seed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Shared empty-state so every screen says "nothing here yet" the same way.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(Theme.secondaryText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
