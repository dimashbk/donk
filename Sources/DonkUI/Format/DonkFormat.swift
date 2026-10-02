import Foundation

public enum DonkFormat {
    // MARK: - Bytes

    public static func bytes(_ count: Int) -> String {
        bytes(Int64(count))
    }

    public static func bytes(_ count: Int64) -> String {
        let sign = count < 0 ? "-" : ""
        let magnitude = count.magnitude
        guard magnitude >= 1024 else { return "\(sign)\(magnitude) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(magnitude) / 1024
        var unit = 0
        while value >= 1023.95, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return sign + String(format: "%.1f", value) + " " + units[unit]
    }

    // MARK: - Duration

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let value = max(0, seconds)
        if value == 0 { return "0 ms" }
        if value < 0.001 { return String(format: "%.2f ms", value * 1000) }
        let milliseconds = (value * 1000).rounded()
        if milliseconds < 1000 { return "\(Int(milliseconds)) ms" }
        if value < 9.995 { return String(format: "%.2f s", value) }
        if value < 59.95 { return String(format: "%.1f s", value) }
        let total = Int(value.rounded())
        if total < 3600 {
            return "\(total / 60)m " + String(format: "%02ds", total % 60)
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return "\(hours)h " + String(format: "%02dm", minutes)
    }

    // MARK: - Dates

    public static func time(_ date: Date) -> String {
        Formatters.time.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        Formatters.dateTime.string(from: date)
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 1 { return "now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
        if delta < 604_800 { return "\(Int(delta / 86_400))d ago" }
        return Formatters.shortDate.string(from: date)
    }

    // MARK: - Numbers

    public static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        guard fraction.isFinite else { return "–" }
        return String(format: "%.\(max(0, fractionDigits))f%%", fraction * 100)
    }

    public static func number(_ value: Int) -> String {
        Formatters.integer.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func number(_ value: Double, fractionDigits: Int = 1) -> String {
        guard value.isFinite else { return "–" }
        let formatter = fractionDigits == 1 ? Formatters.decimal : Formatters.makeDecimal(fractionDigits)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func compact(_ value: Int) -> String {
        let magnitude = Double(value.magnitude)
        let sign = value < 0 ? "-" : ""
        switch magnitude {
        case ..<1000: return "\(value)"
        case ..<10_000: return sign + trimmed(magnitude / 1000) + "K"
        case ..<1_000_000: return sign + "\(Int(magnitude / 1000))K"
        case ..<10_000_000: return sign + trimmed(magnitude / 1_000_000) + "M"
        default: return sign + "\(Int(magnitude / 1_000_000))M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", (value * 10).rounded(.down) / 10)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    // MARK: - Formatters

    private enum Formatters {
        static let posix = Locale(identifier: "en_US_POSIX")

        static let time: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = posix
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()

        static let dateTime: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = posix
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()

        static let shortDate: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return formatter
        }()

        static let integer: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter
        }()

        static let decimal = makeDecimal(1)

        static func makeDecimal(_ digits: Int) -> NumberFormatter {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = max(0, digits)
            return formatter
        }
    }
}
