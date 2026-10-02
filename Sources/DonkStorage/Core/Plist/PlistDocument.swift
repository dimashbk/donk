import DonkJSON
import Foundation

enum PlistTree {
    static func jsonValue(from object: Any) -> JSONValue {
        if let number = object as? NSNumber {
            return numberValue(number)
        }
        if let string = object as? String {
            return .string(string)
        }
        if let date = object as? Date {
            return .string(describe(date))
        }
        if let data = object as? Data {
            return .string(describe(data))
        }
        if let dictionary = object as? NSDictionary {
            let members = dictionary.allKeys
                .map { key -> (String, Any) in ("\(key)", dictionary[key] as Any) }
                .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                .map { JSONMember(key: $0.0, value: jsonValue(from: $0.1)) }
            return .object(members)
        }
        if let array = object as? NSArray {
            return .array(array.map { jsonValue(from: $0) })
        }
        if object is NSNull {
            return .null
        }
        return .string(String(describing: object))
    }

    static func describe(_ date: Date) -> String {
        "Date(" + StorageFormat.iso8601(date) + ")"
    }

    static func describe(_ data: Data) -> String {
        guard !data.isEmpty else { return "Data(0 bytes)" }
        let unit = data.count == 1 ? "byte" : "bytes"
        return "Data(\(data.count) \(unit) · " + HexDump.hex(data, limit: 24, grouped: false) + ")"
    }

    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func isFloatingPoint(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "d" || type == "f"
    }

    private static func numberValue(_ number: NSNumber) -> JSONValue {
        if isBool(number) {
            return .bool(number.boolValue)
        }
        if isFloatingPoint(number) {
            let value = number.doubleValue
            guard value.isFinite else { return .string("\(value)") }
            return .number("\(value)")
        }
        return .number(number.stringValue)
    }
}

// MARK: - Document

struct PlistDocument {
    let object: Any
    let format: PropertyListSerialization.PropertyListFormat

    var formatName: String {
        Self.name(of: format)
    }

    static func load(_ data: Data) throws -> PlistDocument {
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return PlistDocument(object: object, format: format)
    }

    static func xmlText(for object: Any) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    static func encode(_ object: Any, format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        let target: PropertyListSerialization.PropertyListFormat = format == .binary ? .binary : .xml
        return try PropertyListSerialization.data(fromPropertyList: object, format: target, options: 0)
    }

    static func parseXML(_ text: String) -> Result<Any, FileOperationError> {
        let data = Data(text.utf8)
        guard !data.isEmpty else { return .failure(FileOperationError(message: "Property list is empty")) }
        do {
            var format = PropertyListSerialization.PropertyListFormat.xml
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            guard format == .xml else {
                return .failure(FileOperationError(message: "Not an XML property list"))
            }
            return .success(object)
        } catch {
            return .failure(FileOperationError(message: message(for: error)))
        }
    }

    static func name(of format: PropertyListSerialization.PropertyListFormat) -> String {
        switch format {
        case .binary: return "Binary plist"
        case .xml: return "XML plist"
        case .openStep: return "OpenStep plist"
        @unknown default: return "Property list"
        }
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if let debug = nsError.userInfo["NSDebugDescription"] as? String, !debug.isEmpty {
            return debug
        }
        return nsError.localizedDescription
    }
}
