import Foundation
import UserNotifications

enum PushSoundSpec: Equatable {
    case systemDefault
    case named(String)
    case critical(name: String?, volume: Float)

    var label: String {
        switch self {
        case .systemDefault: return "default"
        case let .named(name): return name
        case let .critical(name, volume):
            return "critical · \(name ?? "default") · volume \(String(format: "%.2g", volume))"
        }
    }

    var notificationSound: UNNotificationSound {
        switch self {
        case .systemDefault:
            return .default
        case let .named(name):
            return UNNotificationSound(named: UNNotificationSoundName(name))
        case let .critical(name, volume):
            if let name {
                return .criticalSoundNamed(UNNotificationSoundName(name), withAudioVolume: volume)
            }
            return .defaultCriticalSound(withAudioVolume: volume)
        }
    }
}

enum PushInterruptionLevel: String, Equatable, CaseIterable {
    case passive
    case active
    case timeSensitive = "time-sensitive"
    case critical

    var title: String {
        switch self {
        case .passive: return "Passive"
        case .active: return "Active"
        case .timeSensitive: return "Time Sensitive"
        case .critical: return "Critical"
        }
    }

    var systemLevel: UNNotificationInterruptionLevel {
        switch self {
        case .passive: return .passive
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        case .critical: return .critical
        }
    }
}

struct PushMappedContent: Equatable {
    var title = ""
    var subtitle = ""
    var body = ""
    var badge: Int?
    var sound: PushSoundSpec?
    var threadIdentifier = ""
    var categoryIdentifier = ""
    var launchImageName = ""
    var interruptionLevel: PushInterruptionLevel?
    var relevanceScore: Double?
    var targetContentIdentifier: String?
    var filterCriteria: String?
    var isMutableContent = false
    var isContentAvailable = false
    var hasAPS = false

    var hasAlert: Bool {
        !title.isEmpty || !subtitle.isEmpty || !body.isEmpty
    }

    var isSilent: Bool {
        isContentAvailable && !hasAlert && sound == nil && badge == nil
    }
}

enum PushContentMapper {
    static func map(_ payload: [String: Any], bundle: Bundle = .main) -> PushMappedContent {
        var content = PushMappedContent()
        guard let aps = payload["aps"] as? [String: Any] else { return content }
        content.hasAPS = true
        mapAlert(aps["alert"], bundle: bundle, into: &content)
        content.badge = PushJSON.int(aps["badge"])
        content.sound = sound(aps["sound"])
        content.threadIdentifier = PushJSON.string(aps["thread-id"]) ?? ""
        content.categoryIdentifier = PushJSON.string(aps["category"]) ?? ""
        if let level = PushJSON.string(aps["interruption-level"])?.lowercased() {
            content.interruptionLevel = PushInterruptionLevel(rawValue: level)
        }
        if let score = PushJSON.double(aps["relevance-score"]) {
            content.relevanceScore = min(max(score, 0), 1)
        }
        content.targetContentIdentifier = PushJSON.string(aps["target-content-id"])
        content.filterCriteria = PushJSON.string(aps["filter-criteria"])
        content.isMutableContent = PushJSON.int(aps["mutable-content"]) == 1
        content.isContentAvailable = PushJSON.int(aps["content-available"]) == 1
        return content
    }

    static func makeContent(payload: [String: Any], bundle: Bundle = .main) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        apply(map(payload, bundle: bundle), userInfo: payload, to: content)
        return content
    }

    static func apply(_ mapped: PushMappedContent, userInfo: [AnyHashable: Any], to content: UNMutableNotificationContent) {
        content.title = mapped.title
        content.subtitle = mapped.subtitle
        content.body = mapped.body
        content.badge = mapped.badge.map { NSNumber(value: $0) }
        content.sound = mapped.sound?.notificationSound
        content.threadIdentifier = mapped.threadIdentifier
        content.categoryIdentifier = mapped.categoryIdentifier
        content.launchImageName = mapped.launchImageName
        content.targetContentIdentifier = mapped.targetContentIdentifier
        if let level = mapped.interruptionLevel {
            content.interruptionLevel = level.systemLevel
        }
        if let score = mapped.relevanceScore {
            content.relevanceScore = score
        }
        if #available(iOS 16.0, *), let criteria = mapped.filterCriteria {
            content.filterCriteria = criteria
        }
        content.userInfo = userInfo
    }

    static func sound(_ value: Any?) -> PushSoundSpec? {
        switch value {
        case let name as String:
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return trimmed.lowercased() == "default" ? .systemDefault : .named(trimmed)
        case let dictionary as [String: Any]:
            let rawName = PushJSON.string(dictionary["name"])?.trimmingCharacters(in: .whitespaces)
            let name = (rawName?.isEmpty ?? true) || rawName?.lowercased() == "default" ? nil : rawName
            if PushJSON.int(dictionary["critical"]) == 1 {
                let volume = PushJSON.double(dictionary["volume"]).map { Float(min(max($0, 0), 1)) } ?? 1
                return .critical(name: name, volume: volume)
            }
            return name.map(PushSoundSpec.named) ?? .systemDefault
        default:
            return nil
        }
    }

    private static func mapAlert(_ value: Any?, bundle: Bundle, into content: inout PushMappedContent) {
        if let body = value as? String {
            content.body = body
            return
        }
        guard let alert = value as? [String: Any] else { return }
        content.title = resolve(alert, plain: "title", key: "title-loc-key", args: "title-loc-args", bundle: bundle)
        content.subtitle = resolve(alert, plain: "subtitle", key: "subtitle-loc-key", args: "subtitle-loc-args", bundle: bundle)
        content.body = resolve(alert, plain: "body", key: "loc-key", args: "loc-args", bundle: bundle)
        content.launchImageName = PushJSON.string(alert["launch-image"]) ?? ""
    }

    private static func resolve(_ alert: [String: Any], plain: String, key: String, args: String, bundle: Bundle) -> String {
        if let locKey = PushJSON.string(alert[key]), !locKey.isEmpty {
            return PushLocalization.resolve(key: locKey, arguments: PushJSON.stringArray(alert[args]), bundle: bundle)
        }
        return PushJSON.string(alert[plain]) ?? ""
    }
}

// MARK: - Localization

enum PushLocalization {
    static func resolve(key: String, arguments: [String], bundle: Bundle = .main) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return self.format(format, arguments: arguments)
    }

    static func format(_ format: String, arguments: [String]) -> String {
        var result = ""
        var nextArgument = 0
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                result.append(character)
                index = format.index(after: index)
                continue
            }
            let afterPercent = format.index(after: index)
            guard afterPercent < format.endIndex else {
                result.append(character)
                break
            }
            if format[afterPercent] == "%" {
                result.append("%")
                index = format.index(after: afterPercent)
                continue
            }
            if format[afterPercent] == "@" {
                result.append(argument(at: nextArgument, in: arguments))
                nextArgument += 1
                index = format.index(after: afterPercent)
                continue
            }
            var cursor = afterPercent
            var digits = ""
            while cursor < format.endIndex, format[cursor].isASCII, format[cursor].isNumber {
                digits.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            if !digits.isEmpty,
               cursor < format.endIndex, format[cursor] == "$",
               format.index(after: cursor) < format.endIndex,
               format[format.index(after: cursor)] == "@",
               let position = Int(digits), position > 0 {
                result.append(argument(at: position - 1, in: arguments))
                index = format.index(cursor, offsetBy: 2)
                continue
            }
            result.append(character)
            index = afterPercent
        }
        return result
    }

    private static func argument(at index: Int, in arguments: [String]) -> String {
        arguments.indices.contains(index) ? arguments[index] : ""
    }
}
