import Foundation

// MARK: - Regex cache

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()

    private enum Entry {
        case valid(NSRegularExpression)
        case invalid
    }

    private struct Key: Hashable {
        var pattern: String
        var options: UInt
    }

    private let lock = DonkLock()
    private var entries: [Key: Entry] = [:]
    private let capacity = 256

    func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = Key(pattern: pattern, options: options.rawValue)
        if let cached = lock.withLock({ entries[key] }) {
            if case let .valid(regex) = cached { return regex }
            return nil
        }
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        lock.withLock {
            if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
            entries[key] = compiled.map(Entry.valid) ?? .invalid
        }
        return compiled
    }
}

// MARK: - Wildcard

enum Wildcard {
    static func matches(_ text: String, pattern: String) -> Bool {
        let scalars = Array(text.lowercased().unicodeScalars)
        let tokens = Array(pattern.lowercased().unicodeScalars)
        var textIndex = 0
        var patternIndex = 0
        var starIndex = -1
        var starTextIndex = 0
        while textIndex < scalars.count {
            if patternIndex < tokens.count, tokens[patternIndex] == "?" || tokens[patternIndex] == scalars[textIndex] {
                textIndex += 1
                patternIndex += 1
            } else if patternIndex < tokens.count, tokens[patternIndex] == "*" {
                starIndex = patternIndex
                starTextIndex = textIndex
                patternIndex += 1
            } else if starIndex >= 0 {
                patternIndex = starIndex + 1
                starTextIndex += 1
                textIndex = starTextIndex
            } else {
                return false
            }
        }
        while patternIndex < tokens.count, tokens[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == tokens.count
    }
}

// MARK: - URL parts

enum URLParts {
    static func authority(of url: String) -> Substring? {
        guard let separator = url.range(of: "://") else { return nil }
        let rest = url[separator.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        return rest[..<end]
    }

    static func host(of url: String) -> String? {
        guard var authority = authority(of: url) else { return nil }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = authority[authority.index(after: authority.startIndex)..<close]
            return host.isEmpty ? nil : String(host)
        }
        if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }
        return authority.isEmpty ? nil : String(authority)
    }

    static func rawPath(of url: String) -> Substring {
        let start: String.Index
        if let separator = url.range(of: "://") {
            let rest = url[separator.upperBound...]
            start = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? url.endIndex
        } else {
            start = url.startIndex
        }
        let tail = url[start...]
        let end = tail.firstIndex { $0 == "?" || $0 == "#" } ?? tail.endIndex
        return tail[..<end]
    }

    static func path(of url: String) -> String {
        let raw = rawPath(of: url)
        if raw.isEmpty {
            return authority(of: url) == nil ? url : "/"
        }
        let string = String(raw)
        return string.removingPercentEncoding ?? string
    }

    static func queryItems(of url: String) -> [URLQueryItem] {
        if let components = URLComponents(string: url) {
            return components.queryItems ?? []
        }
        guard let questionMark = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: questionMark)...]
        if let hash = query.firstIndex(of: "#") {
            query = query[..<hash]
        }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : nil
            return URLQueryItem(name: name.removingPercentEncoding ?? name, value: value.map { $0.removingPercentEncoding ?? $0 })
        }
    }
}

// MARK: - Formatting

enum DonkFormat {
    static func duration(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded())) ms"
        }
        if interval < 60 {
            return String(format: "%.2f s", interval)
        }
        let minutes = Int(interval / 60)
        let seconds = Int(interval.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }

    static func bytes(_ count: Int) -> String {
        let value = Double(count)
        if count < 1024 { return "\(count) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1f MB", value / (1024 * 1024)) }
        return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
    }

    static func seconds(_ interval: TimeInterval) -> String {
        if interval.rounded() == interval, abs(interval) < Double(Int.max) {
            return String(Int(interval))
        }
        var text = String(format: "%.3f", interval)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    static func timeOfDay(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Shell

enum Shell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
