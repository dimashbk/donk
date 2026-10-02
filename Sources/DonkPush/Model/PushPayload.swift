import DonkCore
import Foundation

struct PushPayloadError: Error, Equatable, CustomStringConvertible {
    var message: String

    var description: String { message }
}

struct PushPayload {
    static let apnsSizeLimit = 4096

    let text: String
    let value: JSONValue
    let dictionary: [String: Any]

    static func parse(_ text: String) -> Result<PushPayload, PushPayloadError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(PushPayloadError(message: "Payload is empty"))
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(trimmed)
        } catch let error as JSONParseError {
            return .failure(PushPayloadError(message: "Invalid JSON: \(error.reason) at offset \(error.offset)"))
        } catch {
            return .failure(PushPayloadError(message: "Invalid JSON"))
        }
        guard case .object = value else {
            return .failure(PushPayloadError(message: "Payload must be a JSON object, got \(value.typeName)"))
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let dictionary = object as? [String: Any]
        else {
            return .failure(PushPayloadError(message: "Payload could not be decoded as a dictionary"))
        }
        return .success(PushPayload(text: trimmed, value: value, dictionary: dictionary))
    }

    var aps: [String: Any]? {
        dictionary["aps"] as? [String: Any]
    }

    var hasAPS: Bool {
        aps != nil
    }

    var isMutableContent: Bool {
        PushJSON.int(aps?["mutable-content"]) == 1
    }

    var isContentAvailable: Bool {
        PushJSON.int(aps?["content-available"]) == 1
    }

    var hasVisibleContent: Bool {
        guard let aps else { return false }
        return aps["alert"] != nil || aps["sound"] != nil || aps["badge"] != nil
    }

    var isSilent: Bool {
        isContentAvailable && !hasVisibleContent
    }

    var byteCount: Int {
        value.compact().utf8.count
    }

    var containsNull: Bool {
        Self.containsNull(value)
    }

    var categoryIdentifier: String? {
        aps?["category"] as? String
    }

    func attachmentURL(keyPaths: [String]) -> URL? {
        PushJSON.attachmentURL(in: dictionary, keyPaths: keyPaths)
    }

    private static func containsNull(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case let .object(members): return members.contains { containsNull($0.value) }
        case let .array(values): return values.contains { containsNull($0) }
        default: return false
        }
    }
}

// MARK: - JSON helpers

enum PushJSON {
    static func value(from object: Any?) -> JSONValue {
        guard let object else { return .null }
        switch object {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return value(from: number)
        case let dictionary as [AnyHashable: Any]:
            return value(fromUserInfo: dictionary)
        case let array as [Any]:
            return .array(array.map { value(from: $0) })
        case let data as Data:
            return .string(data.base64EncodedString())
        case let date as Date:
            return .string(ISO8601DateFormatter().string(from: date))
        case let url as URL:
            return .string(url.absoluteString)
        default:
            return .string(String(describing: object))
        }
    }

    static func value(from number: NSNumber) -> JSONValue {
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            let double = number.doubleValue
            guard double.isFinite else { return .string(number.stringValue) }
            if double == double.rounded(), abs(double) < 1e15 {
                return .number(String(format: "%.1f", double))
            }
            return .number("\(double)")
        }
        return .number(number.stringValue)
    }

    static func value(fromUserInfo userInfo: [AnyHashable: Any]) -> JSONValue {
        let members = userInfo
            .map { (key: "\($0.key)", value: $0.value) }
            .sorted { lhs, rhs in
                if lhs.key == "aps" { return rhs.key != "aps" }
                if rhs.key == "aps" { return false }
                return lhs.key < rhs.key
            }
            .map { JSONMember(key: $0.key, value: value(from: $0.value)) }
        return .object(members)
    }

    static func text(fromUserInfo userInfo: [AnyHashable: Any]) -> String {
        value(fromUserInfo: userInfo).prettyPrinted()
    }

    static func lookup(_ keyPath: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any], let direct = dictionary[keyPath] {
            return direct
        }
        let components = keyPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1 else { return nil }
        var current: Any = object
        for component in components {
            if let dictionary = current as? [String: Any], let next = dictionary[component] {
                current = next
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func attachmentURL(in payload: [String: Any], keyPaths: [String]) -> URL? {
        for keyPath in keyPaths {
            guard let raw = lookup(keyPath, in: payload) as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let url = URL(string: trimmed),
                let scheme = url.scheme?.lowercased(),
                ["http", "https", "file"].contains(scheme)
            else { continue }
            return url
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { string($0) }
    }
}
