import DonkUI
import Foundation

extension CrashReport.Kind {
    var label: String {
        switch self {
        case .signal: return "Signal"
        case .exception: return "Exception"
        case .metricKit: return "MetricKit"
        case .uncleanExit: return "Unclean exit"
        }
    }

    var tone: DonkTone {
        switch self {
        case .signal: return .error
        case .exception: return .warning
        case .metricKit: return .info
        case .uncleanExit: return .neutral
        }
    }

    var icon: String {
        switch self {
        case .signal: return "xmark.octagon.fill"
        case .exception: return "exclamationmark.triangle.fill"
        case .metricKit: return "waveform.path.ecg"
        case .uncleanExit: return "power"
        }
    }
}

extension CrashReport {
    var icon: String {
        guard kind == .metricKit, let title = metricKitTitle else { return kind.icon }
        if title.hasPrefix("Hang") { return "hourglass" }
        if title.hasPrefix("CPU") { return "cpu" }
        return kind.icon
    }

    var threadLabel: String? {
        var parts: [String] = []
        if isMainThread == true {
            parts.append("Main thread")
        } else if isMainThread == false {
            parts.append("Background thread")
        }
        if let threadName, !threadName.isEmpty, threadName != "main" {
            parts.append(threadName)
        }
        if let queue = details.first(where: { $0.key == "Queue" })?.value, isMainThread != true {
            parts.append(queue)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var crashedThreadTitle: String {
        kind == .exception ? "Exception Backtrace" : "Crashed Thread"
    }
}

extension CrashFrame {
    var isUnsymbolicated: Bool {
        symbol == nil && imageLoadAddress != nil
    }
}

enum CrashDayFormatter {
    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "yMMMd")
        return formatter.string(from: day)
    }
}

struct CrashDaySection: Identifiable, Equatable {
    var day: Date
    var reports: [CrashReport]

    var id: Date { day }

    static func group(_ reports: [CrashReport], calendar: Calendar = .current) -> [CrashDaySection] {
        var sections: [CrashDaySection] = []
        for report in reports.sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: report.date)
            if let last = sections.indices.last, sections[last].day == day {
                sections[last].reports.append(report)
            } else {
                sections.append(CrashDaySection(day: day, reports: [report]))
            }
        }
        return sections
    }
}
