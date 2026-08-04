import SwiftUI

/// One place for colour and spacing so the screens stay visually consistent.
enum Theme {
    static let accent = Color(red: 1.00, green: 0.42, blue: 0.34)
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.19)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.6)

    static let cornerRadius: CGFloat = 12
    /// Height reserved above the tab bar so the mini player never covers content.
    static let miniPlayerHeight: CGFloat = 62

    /// Deterministic cover art for a playlist, derived from its stored seed so
    /// the same playlist always looks the same.
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

/// Remote artwork with a placeholder that keeps list rows from jumping while
/// thumbnails load.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6
    var seed: Int = 0

    var body: some View {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Theme.gradient(seed: seed)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35))
                .foregroundStyle(.white.opacity(0.85))
        }
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
