import Foundation

package enum DonkPersistence {
    package static var directory: URL { defaultDirectory }

    package static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        load(type, from: name, in: directory)
    }

    package static func save<T: Encodable>(_ value: T, to name: String) {
        save(value, to: name, in: directory)
    }

    package static func load<T: Decodable>(_ type: T.Type, from name: String, in directory: URL) -> T? {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    package static func save<T: Encodable>(_ value: T, to name: String, in directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        createDirectory(directory)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try? data.write(to: url, options: .atomic)
    }

    package static func remove(_ name: String, in directory: URL) {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    package static func createDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let base = defaultDirectory.path
        guard url.path == base || url.path.hasPrefix(base + "/") else { return }
        var root = defaultDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    private static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Donk", isDirectory: true)
    }()
}

// MARK: - Lenient decoding

struct LenientArray<Element: Codable>: Codable {
    var elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(SkippedValue.self)
            }
        }
        elements = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }

    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
