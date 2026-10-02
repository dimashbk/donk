import DonkCore
import Foundation

enum DefaultsValueType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case string = "String"
    case int = "Int"
    case double = "Double"
    case bool = "Bool"
    case date = "Date"
    case data = "Data"
    case array = "Array"
    case dictionary = "Dictionary"

    var id: String { rawValue }

    var isCollection: Bool {
        self == .array || self == .dictionary
    }

    static func detect(_ value: Any) -> DefaultsValueType? {
        if let number = value as? NSNumber {
            if PlistTree.isBool(number) { return .bool }
            return PlistTree.isFloatingPoint(number) ? .double : .int
        }
        if value is String { return .string }
        if value is Date { return .date }
        if value is Data { return .data }
        if value is NSArray { return .array }
        if value is NSDictionary { return .dictionary }
        return nil
    }
}

// MARK: - Values

enum DefaultsValues {
    static func preview(_ value: Any, type: DefaultsValueType?) -> String {
        switch type {
        case .string:
            let string = value as? String ?? ""
            if string.isEmpty { return "Empty string" }
            return String(string.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
        case .int:
            return (value as? NSNumber).map { "\($0.int64Value)" } ?? "\(value)"
        case .double:
            return (value as? NSNumber).map { formatDouble($0.doubleValue) } ?? "\(value)"
        case .bool:
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        case .date:
            return (value as? Date).map(StorageFormat.dateTime) ?? "\(value)"
        case .data:
            let data = value as? Data ?? Data()
            if data.isEmpty { return "0 bytes" }
            return "\(data.count) bytes · " + HexDump.hex(data, limit: 16, grouped: true)
        case .array:
            let count = (value as? NSArray)?.count ?? 0
            let summary = count == 1 ? "1 item" : "\(count) items"
            if let compact = compactJSON(value), compact.count <= 80 { return summary + " · " + compact }
            return summary
        case .dictionary:
            let count = (value as? NSDictionary)?.count ?? 0
            let summary = count == 1 ? "1 key" : "\(count) keys"
            if let compact = compactJSON(value), compact.count <= 80 { return summary + " · " + compact }
            return summary
        case nil:
            return String(describing: value)
        }
    }

    static func formatDouble(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        return "\(value)"
    }

    static func defaultValue(for type: DefaultsValueType) -> Any {
        switch type {
        case .string: return ""
        case .int: return 0
        case .double: return 0.0
        case .bool: return false
        case .date: return Date()
        case .data: return Data()
        case .array: return [Any]()
        case .dictionary: return [String: Any]()
        }
    }

    static func parseInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces))
    }

    static func parseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    static func parseBase64(_ text: String) -> Data? {
        let cleaned = text.components(separatedBy: .whitespacesAndNewlines).joined()
        if cleaned.isEmpty { return Data() }
        return Data(base64Encoded: cleaned)
    }

    static func jsonText(for collection: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(collection),
              let data = try? JSONSerialization.data(
                withJSONObject: collection,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseCollection(_ text: String, as type: DefaultsValueType) -> Result<Any, FileOperationError> {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            return .failure(FileOperationError(message: "Enter a JSON \(type == .array ? "array" : "object")"))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(FileOperationError(message: "Invalid JSON"))
        }
        switch type {
        case .array where !(object is NSArray):
            return .failure(FileOperationError(message: "Expected a JSON array"))
        case .dictionary where !(object is NSDictionary):
            return .failure(FileOperationError(message: "Expected a JSON object"))
        default:
            break
        }
        guard PropertyListSerialization.propertyList(object, isValidFor: .binary) else {
            return .failure(FileOperationError(message: "null is not allowed in property lists"))
        }
        return .success(object)
    }

    private static func compactJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Domain

struct DefaultsDomain: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case standard
        case suite
    }

    let kind: Kind
    let name: String

    var id: String { (kind == .standard ? "standard:" : "suite:") + name }

    var title: String {
        kind == .standard ? "Standard" : name
    }

    static var standard: DefaultsDomain {
        DefaultsDomain(kind: .standard, name: Bundle.main.bundleIdentifier ?? "")
    }

    static func suite(_ name: String) -> DefaultsDomain {
        DefaultsDomain(kind: .suite, name: name)
    }
}

enum PreferencesFile {
    static func domain(for url: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> DefaultsDomain? {
        guard url.pathExtension.lowercased() == "plist" else { return nil }
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent == "Preferences",
              folder.deletingLastPathComponent().lastPathComponent == "Library" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        if let bundleIdentifier, name == bundleIdentifier {
            return DefaultsDomain(kind: .standard, name: bundleIdentifier)
        }
        return .suite(name)
    }
}

struct DefaultsEntry: Identifiable, @unchecked Sendable {
    let key: String
    let value: Any
    let type: DefaultsValueType?
    let preview: String

    var id: String { key }

    init(key: String, value: Any) {
        self.key = key
        self.value = value
        self.type = DefaultsValueType.detect(value)
        self.preview = DefaultsValues.preview(value, type: type)
    }
}

enum DefaultsStore {
    private static let lock = DonkLock()
    private static var suites: [String: UserDefaults] = [:]

    static func userDefaults(for domain: DefaultsDomain) -> UserDefaults? {
        switch domain.kind {
        case .standard:
            return .standard
        case .suite:
            guard !domain.name.isEmpty else { return nil }
            return lock.withLock {
                if let existing = suites[domain.name] { return existing }
                let created = UserDefaults(suiteName: domain.name)
                suites[domain.name] = created
                return created
            }
        }
    }

    static func persistentDomain(_ domain: DefaultsDomain) -> [String: Any] {
        guard !domain.name.isEmpty, let defaults = userDefaults(for: domain) else { return [:] }
        return defaults.persistentDomain(forName: domain.name) ?? [:]
    }

    static func entries(in domain: DefaultsDomain) -> [DefaultsEntry] {
        let dictionary = persistentDomain(domain)
        return dictionary.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { key in dictionary[key].map { DefaultsEntry(key: key, value: $0) } }
    }

    static func count(in domain: DefaultsDomain) -> Int {
        persistentDomain(domain).count
    }

    static func value(forKey key: String, in domain: DefaultsDomain) -> Any? {
        persistentDomain(domain)[key]
    }

    static func set(_ value: Any, forKey key: String, in domain: DefaultsDomain) {
        userDefaults(for: domain)?.set(value, forKey: key)
    }

    static func remove(_ key: String, in domain: DefaultsDomain) {
        userDefaults(for: domain)?.removeObject(forKey: key)
    }

    static func reset(_ domain: DefaultsDomain) {
        guard !domain.name.isEmpty, let defaults = userDefaults(for: domain) else { return }
        defaults.removePersistentDomain(forName: domain.name)
    }

    static func exportPlist(_ domain: DefaultsDomain) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: persistentDomain(domain), format: .xml, options: 0)
    }
}
