import Foundation

/// Parses the ISO 8601 durations the YouTube Data API returns for videos
/// (`PT4M13S`, `PT1H2M`, `P1DT30S`). Foundation has no parser for this shape,
/// so it is hand-rolled and covered by tests.
public enum ISO8601Duration {
    public static func seconds(from string: String) -> TimeInterval? {
        guard string.hasPrefix("P") else { return nil }

        var total: TimeInterval = 0
        var number = ""
        var inTimeSection = false
        var sawComponent = false

        for character in string.dropFirst() {
            if character == "T" {
                inTimeSection = true
                number = ""
                continue
            }
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = TimeInterval(number) else { return nil }
            number = ""

            switch (character, inTimeSection) {
            case ("D", _): total += value * 86_400
            case ("W", _): total += value * 604_800
            case ("H", true): total += value * 3_600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            case ("M", false): total += value * 2_592_000 // months, nominal 30 days
            case ("Y", false): total += value * 31_536_000
            default: return nil
            }
            sawComponent = true
        }

        // Trailing digits with no unit, e.g. "PT4M1" — malformed.
        guard number.isEmpty, sawComponent else { return nil }
        return total
    }
}

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
