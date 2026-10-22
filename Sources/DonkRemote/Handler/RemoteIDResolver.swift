import Foundation

enum RemoteIDResolver {
    static let minimumPrefixLength = 8

    static func resolve<Item>(_ input: String, in items: [Item], noun: String, id: (Item) -> UUID) throws -> Item {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) {
            guard let match = items.first(where: { id($0) == uuid }) else {
                throw RemoteError.notFound("\(noun) \(uuid.uuidString) not found")
            }
            return match
        }
        let prefix = normalized(trimmed)
        guard prefix.count >= minimumPrefixLength, prefix.allSatisfy(\.isHexDigit) else {
            throw RemoteError.invalidParams("id must be a full id or a prefix of at least \(minimumPrefixLength) hex characters")
        }
        var match: Item?
        var matchCount = 0
        for item in items where normalized(id(item).uuidString).hasPrefix(prefix) {
            matchCount += 1
            if match == nil { match = item }
            if matchCount > 1 { break }
        }
        guard let match else {
            throw RemoteError.notFound("\(noun) \(trimmed) not found")
        }
        guard matchCount == 1 else {
            throw RemoteError.ambiguous("id prefix \(trimmed) matches more than one \(noun)")
        }
        return match
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "").uppercased()
    }
}
