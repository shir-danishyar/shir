import Foundation

public extension TimeInterval {
    /// `3:07`, or `1:02:07` once past an hour.
    var formattedPlaybackTime: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
