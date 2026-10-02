import Foundation

public struct NetworkFilter: Codable, Equatable, Sendable {
    public var query: String
    public var kinds: Set<NetworkKind>
    public var hosts: Set<String>
    public var statusCategories: Set<StatusCategory>
    public var onlyModified: Bool
    public var onlyPinned: Bool

    public init() {
        query = ""
        kinds = []
        hosts = []
        statusCategories = []
        onlyModified = false
        onlyPinned = false
    }

    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && kinds.isEmpty
            && hosts.isEmpty
            && statusCategories.isEmpty
            && !onlyModified
            && !onlyPinned
    }
}

public enum NetworkSearch {
    public static let bodySearchLimit = 256 * 1024

    public static func apply(_ filter: NetworkFilter, hiddenHosts: [String], to entries: [NetworkEntry]) -> [NetworkEntry] {
        let terms = SearchTerm.parse(filter.query)
        let hostFilter = Set(filter.hosts.map { $0.lowercased() })
        let hidden = hiddenHosts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return entries.filter { entry in
            if !filter.kinds.isEmpty, !filter.kinds.contains(entry.kind) { return false }
            if filter.onlyPinned, !entry.isPinned { return false }
            if filter.onlyModified, !entry.origin.isModified { return false }
            if !filter.statusCategories.isEmpty, !filter.statusCategories.contains(entry.statusCategory) { return false }
            if !hostFilter.isEmpty || !hidden.isEmpty {
                let host = entry.host
                if !hostFilter.isEmpty {
                    guard let host, hostFilter.contains(host.lowercased()) else { return false }
                }
                if HostPattern.matchesAny(host, patterns: hidden) { return false }
            }
            return terms.isEmpty || matches(entry, terms: terms)
        }
    }

    public static func matches(_ entry: NetworkEntry, query: String) -> Bool {
        let terms = SearchTerm.parse(query)
        return terms.isEmpty || matches(entry, terms: terms)
    }

    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                found.append(range)
                searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        guard !found.isEmpty else { return [] }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [found[0]]
        for range in found.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: - Matching

    static func matches(_ entry: NetworkEntry, terms: [SearchTerm]) -> Bool {
        terms.allSatisfy { term in
            matchesMetadata(entry, term) || matchesHeaders(entry, term) || matchesBodies(entry, term) || matchesMessages(entry, term)
        }
    }

    private static func matchesMetadata(_ entry: NetworkEntry, _ term: SearchTerm) -> Bool {
        if term.matches(entry.request.url) { return true }
        if term.matches(entry.request.method) || term.matches(entry.methodLabel) || term.matches(entry.statusLabel) { return true }
        if let code = entry.response?.statusCode, term.matches(String(code)) { return true }
        if let error = entry.error, term.matches(error.message) || term.matches(error.domain) || term.matches(String(error.code)) {
            return true
        }
        if let grpc = entry.grpc {
            if term.matches(grpc.path) { return true }
            if let message = grpc.statusMessage, term.matches(message) { return true }
            if let code = grpc.statusCode, term.matches(String(code)) { return true }
        }
        if let pageURL = entry.web?.pageURL, term.matches(pageURL) { return true }
        return false
    }

    private static func matchesHeaders(_ entry: NetworkEntry, _ term: SearchTerm) -> Bool {
        if matches(entry.request.headers, term) { return true }
        if let response = entry.response, matches(response.headers, term) { return true }
        if let grpc = entry.grpc {
            if matches(grpc.requestMetadata, term) || matches(grpc.responseHeaders, term) || matches(grpc.trailers, term) {
                return true
            }
        }
        return false
    }

    private static func matches(_ headers: [HTTPHeader], _ term: SearchTerm) -> Bool {
        headers.contains { term.matches($0.name) || term.matches($0.value) }
    }

    private static func matchesBodies(_ entry: NetworkEntry, _ term: SearchTerm) -> Bool {
        if let body = entry.request.body, matches(body, term, entry: entry, slot: .request) { return true }
        if let body = entry.response?.body, matches(body, term, entry: entry, slot: .response) { return true }
        return false
    }

    private static func matches(_ body: BodyData, _ term: SearchTerm, entry: NetworkEntry, slot: SearchTextCache.Slot) -> Bool {
        guard !body.data.isEmpty, !body.isImage else { return false }
        if term.isASCII {
            return body.data.withUnsafeBytes { raw in
                term.matches(bytes: UnsafeRawBufferPointer(rebasing: raw.prefix(bodySearchLimit)))
            }
        }
        let folded = SearchTextCache.shared.foldedText(for: body, entry: entry, slot: slot, limit: bodySearchLimit)
        return folded.withUnsafeBytes { term.matchesFolded($0) }
    }

    private static func matchesMessages(_ entry: NetworkEntry, _ term: SearchTerm) -> Bool {
        guard let messages = entry.grpc?.messages, !messages.isEmpty else { return false }
        for message in messages {
            if term.matches(message.typeName) { return true }
            if let json = message.json, term.matches(json, limit: bodySearchLimit) { return true }
            if message.json == nil, let text = message.textFormat, term.matches(text, limit: bodySearchLimit) { return true }
        }
        return false
    }
}

// MARK: - Term

struct SearchTerm {
    let text: String
    let bytes: [UInt8]
    let isASCII: Bool
    let folded: [UInt8]
    private let anchor: Int

    init(_ raw: String) {
        text = raw.lowercased()
        bytes = Array(text.utf8)
        isASCII = bytes.allSatisfy { $0 < 0x80 }
        anchor = isASCII ? Self.rarestIndex(in: bytes) : 0
        folded = isASCII ? [] : FoldedText.fold(raw)
    }

    static func parse(_ query: String) -> [SearchTerm] {
        query.split(whereSeparator: \.isWhitespace).map { SearchTerm(String($0)) }
    }

    func matches(_ string: String, limit: Int = .max) -> Bool {
        guard isASCII else {
            let source = string.utf8.count <= limit ? string : String(decoding: string.utf8.prefix(limit), as: UTF8.self)
            return FoldedText.fold(source).withUnsafeBytes { matchesFolded($0) }
        }
        if let result = string.utf8.withContiguousStorageIfAvailable({ buffer -> Bool in
            let raw = UnsafeRawBufferPointer(buffer)
            return matchesASCII(UnsafeRawBufferPointer(rebasing: raw.prefix(limit)))
        }) {
            return result
        }
        let copy = Array(string.utf8.prefix(limit))
        return copy.withUnsafeBytes { matchesASCII($0) }
    }

    func matches(bytes haystack: UnsafeRawBufferPointer) -> Bool {
        if isASCII { return matchesASCII(haystack) }
        return FoldedText.fold(String(decoding: haystack, as: UTF8.self)).withUnsafeBytes { matchesFolded($0) }
    }

    func matchesFolded(_ haystack: UnsafeRawBufferPointer) -> Bool {
        FoldedText.contains(folded, in: haystack)
    }

    private func matchesASCII(_ haystack: UnsafeRawBufferPointer) -> Bool {
        let needleCount = bytes.count
        guard needleCount > 0 else { return true }
        let count = haystack.count
        guard count >= needleCount, let base = haystack.baseAddress else { return false }
        let anchorByte = bytes[anchor]
        let isLetter = anchorByte >= 0x61 && anchorByte <= 0x7A
        let upperByte = isLetter ? anchorByte - 0x20 : anchorByte
        let lastAnchor = count - needleCount + anchor
        var start = anchor
        var nextLower = -2
        var nextUpper = isLetter ? -2 : -1
        return bytes.withUnsafeBufferPointer { needle -> Bool in
            while start <= lastAnchor {
                if nextLower != -1, nextLower < start {
                    nextLower = Self.find(anchorByte, in: base, from: start, through: lastAnchor)
                }
                if nextUpper != -1, nextUpper < start {
                    nextUpper = Self.find(upperByte, in: base, from: start, through: lastAnchor)
                }
                let position: Int
                switch (nextLower, nextUpper) {
                case (-1, -1): return false
                case (-1, let upper): position = upper
                case (let lower, -1): position = lower
                case let (lower, upper): position = min(lower, upper)
                }
                let candidate = position - anchor
                var offset = 0
                while offset < needleCount {
                    var byte = haystack[candidate + offset]
                    if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                    if byte != needle[offset] { break }
                    offset += 1
                }
                if offset == needleCount { return true }
                start = position + 1
            }
            return false
        }
    }

    private static func find(_ byte: UInt8, in base: UnsafeRawPointer, from start: Int, through end: Int) -> Int {
        guard start <= end, let found = memchr(base + start, Int32(byte), end - start + 1) else { return -1 }
        return base.distance(to: UnsafeRawPointer(found))
    }

    private static func rarestIndex(in bytes: [UInt8]) -> Int {
        var best = 0
        var bestScore = Int.max
        for (index, byte) in bytes.enumerated() {
            let score = frequency(of: byte)
            if score < bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    private static let letterFrequency: [UInt8] = Array("etaoinshrdlcumwfgypbvkjxqz".utf8)

    private static func frequency(of byte: UInt8) -> Int {
        if byte >= 0x61, byte <= 0x7A {
            let rank = letterFrequency.firstIndex(of: byte) ?? 0
            return 40 - rank
        }
        if byte >= 0x30, byte <= 0x39 { return 25 }
        switch byte {
        case 0x20, 0x22, 0x3A, 0x2C, 0x2F, 0x2E, 0x7B, 0x7D, 0x5B, 0x5D: return 60
        case 0x5F, 0x2D, 0x3D, 0x26: return 30
        default: return 5
        }
    }
}

// MARK: - Folded text

enum FoldedText {
    static func fold(_ string: String) -> [UInt8] {
        Array(string.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping.utf8)
    }

    static func contains(_ needle: [UInt8], in haystack: UnsafeRawBufferPointer) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count, let base = haystack.baseAddress else { return false }
        return needle.withUnsafeBytes { needleBytes -> Bool in
            guard let needleBase = needleBytes.baseAddress else { return false }
            var offset = 0
            while offset <= haystack.count - needle.count {
                guard let found = memmem(base + offset, haystack.count - offset, needleBase, needle.count) else { return false }
                let start = base.distance(to: UnsafeRawPointer(found))
                if !continuesCluster(at: start + needle.count, in: haystack) { return true }
                offset = start + 1
            }
            return false
        }
    }

    private static func continuesCluster(at offset: Int, in buffer: UnsafeRawBufferPointer) -> Bool {
        guard let scalar = scalar(at: offset, in: buffer), scalar.value >= 0x300 else { return false }
        switch scalar.value {
        case 0x200D, 0x1F3FB...0x1F3FF:
            return true
        default:
            break
        }
        let properties = scalar.properties
        if properties.isGraphemeExtend { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func scalar(at offset: Int, in buffer: UnsafeRawBufferPointer) -> Unicode.Scalar? {
        guard offset < buffer.count else { return nil }
        let lead = buffer[offset]
        let length: Int
        var value: UInt32
        switch lead {
        case 0..<0x80:
            return Unicode.Scalar(lead)
        case 0xC0..<0xE0:
            length = 2
            value = UInt32(lead & 0x1F)
        case 0xE0..<0xF0:
            length = 3
            value = UInt32(lead & 0x0F)
        case 0xF0..<0xF8:
            length = 4
            value = UInt32(lead & 0x07)
        default:
            return nil
        }
        guard offset + length <= buffer.count else { return nil }
        for index in 1..<length {
            let byte = buffer[offset + index]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(byte & 0x3F)
        }
        return Unicode.Scalar(value)
    }
}

// MARK: - Cache

final class SearchTextCache: @unchecked Sendable {
    enum Slot: UInt8 {
        case request, response
    }

    private struct Key: Hashable {
        var id: UUID
        var slot: Slot
    }

    private struct Fingerprint: Equatable {
        var state: NetworkState
        var messageCount: Int
        var count: Int
        var originalSize: Int
        var isTruncated: Bool
        var limit: Int
        var sample: Int
    }

    private struct Item {
        var fingerprint: Fingerprint
        var bytes: [UInt8]
        var lastUse: UInt64
    }

    static let shared = SearchTextCache()

    let byteBudget: Int
    private let lock = DonkLock()
    private var items: [Key: Item] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0
    private var misses = 0

    init(byteBudget: Int = 32 * 1024 * 1024) {
        self.byteBudget = byteBudget
    }

    func foldedText(for body: BodyData, entry: NetworkEntry, slot: Slot, limit: Int) -> [UInt8] {
        let key = Key(id: entry.id, slot: slot)
        let fingerprint = Self.fingerprint(body, entry: entry, limit: limit)
        let cached: [UInt8]? = lock.withLock {
            guard let item = items[key], item.fingerprint == fingerprint else { return nil }
            clock &+= 1
            items[key]?.lastUse = clock
            return item.bytes
        }
        if let cached { return cached }
        let folded = body.data.withUnsafeBytes { raw in
            FoldedText.fold(String(decoding: UnsafeRawBufferPointer(rebasing: raw.prefix(limit)), as: UTF8.self))
        }
        store(folded, fingerprint: fingerprint, for: key)
        return folded
    }

    func removeAll() {
        lock.withLock {
            items.removeAll()
            totalBytes = 0
        }
    }

    var count: Int {
        lock.withLock { items.count }
    }

    var missCount: Int {
        lock.withLock { misses }
    }

    private func store(_ bytes: [UInt8], fingerprint: Fingerprint, for key: Key) {
        lock.withLock {
            misses += 1
            guard bytes.count <= byteBudget / 4 else { return }
            clock &+= 1
            if let previous = items[key] {
                totalBytes -= previous.bytes.count
            }
            items[key] = Item(fingerprint: fingerprint, bytes: bytes, lastUse: clock)
            totalBytes += bytes.count
            guard totalBytes > byteBudget else { return }
            let target = byteBudget * 3 / 4
            for (oldKey, item) in items.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
                guard totalBytes > target else { break }
                items[oldKey] = nil
                totalBytes -= item.bytes.count
            }
        }
    }

    private static func fingerprint(_ body: BodyData, entry: NetworkEntry, limit: Int) -> Fingerprint {
        var hasher = Hasher()
        body.data.withUnsafeBytes { raw in
            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw.prefix(32)))
            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw.suffix(32)))
            if raw.count > 64 {
                let middle = raw.count / 2
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[middle..<min(raw.count, middle + 32)]))
            }
        }
        let grpc = entry.grpc
        return Fingerprint(
            state: entry.state,
            messageCount: (grpc?.sentMessageCount ?? 0) + (grpc?.receivedMessageCount ?? 0),
            count: body.data.count,
            originalSize: body.originalSize,
            isTruncated: body.isTruncated,
            limit: limit,
            sample: hasher.finalize()
        )
    }
}
