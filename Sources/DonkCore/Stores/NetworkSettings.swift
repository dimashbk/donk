import Combine
import Foundation

public struct NetworkSettings: Codable, Equatable, Sendable {
    public var hiddenHosts: [String]
    public var bypassHosts: [String]
    public var maxBodySize: Int
    public var limit: Int
    public var redactsExports: Bool
    public var redaction: RedactionPolicy

    public static let `default` = NetworkSettings()

    public init(
        hiddenHosts: [String] = [],
        bypassHosts: [String] = [],
        maxBodySize: Int = 2 * 1024 * 1024,
        limit: Int = 1000,
        redactsExports: Bool = true,
        redaction: RedactionPolicy = .default
    ) {
        self.hiddenHosts = hiddenHosts
        self.bypassHosts = bypassHosts
        self.maxBodySize = maxBodySize
        self.limit = limit
        self.redactsExports = redactsExports
        self.redaction = redaction
    }

    public var exportRedaction: RedactionPolicy? {
        redactsExports ? redaction : nil
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenHosts, bypassHosts, maxBodySize, limit, redactsExports, redaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NetworkSettings()
        hiddenHosts = try container.decodeIfPresent([String].self, forKey: .hiddenHosts) ?? fallback.hiddenHosts
        bypassHosts = try container.decodeIfPresent([String].self, forKey: .bypassHosts) ?? fallback.bypassHosts
        maxBodySize = try container.decodeIfPresent(Int.self, forKey: .maxBodySize) ?? fallback.maxBodySize
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? fallback.limit
        redactsExports = (try? container.decodeIfPresent(Bool.self, forKey: .redactsExports)) ?? fallback.redactsExports
        redaction = (try? container.decodeIfPresent(RedactionPolicy.self, forKey: .redaction)) ?? fallback.redaction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hiddenHosts, forKey: .hiddenHosts)
        try container.encode(bypassHosts, forKey: .bypassHosts)
        try container.encode(maxBodySize, forKey: .maxBodySize)
        try container.encode(limit, forKey: .limit)
        try container.encode(redactsExports, forKey: .redactsExports)
        try container.encode(redaction, forKey: .redaction)
    }
}

public final class NetworkSettingsStore: @unchecked Sendable {
    public static let shared = NetworkSettingsStore()

    private let lock = DonkLock()
    private let writeLock = DonkLock()
    private let fileName: String
    private let customDirectory: URL?
    private var isLoaded = false
    private var current = NetworkSettings.default
    private let subject: CurrentValueSubject<NetworkSettings, Never>
    private let publication: PublicationQueue<NetworkSettings>

    public init(fileName: String = "network-settings.json", directory: URL? = nil) {
        self.fileName = fileName
        customDirectory = directory
        let subject = CurrentValueSubject<NetworkSettings, Never>(.default)
        self.subject = subject
        publication = PublicationQueue(latestOnly: true) { subject.send($0) }
    }

    public var settings: NetworkSettings {
        get { lock.withLock { loadIfNeeded(); return current } }
        set {
            let changed: Bool = lock.withLock {
                loadIfNeeded()
                guard current != newValue else { return false }
                current = newValue
                publication.enqueue(newValue)
                return true
            }
            guard changed else { return }
            persist()
            publication.flush()
        }
    }

    public func update(_ change: (inout NetworkSettings) -> Void) {
        let changed: Bool = lock.withLock {
            loadIfNeeded()
            var copy = current
            change(&copy)
            guard copy != current else { return false }
            current = copy
            publication.enqueue(copy)
            return true
        }
        guard changed else { return }
        persist()
        publication.flush()
    }

    public var changes: AnyPublisher<NetworkSettings, Never> {
        lock.withLock { loadIfNeeded() }
        return subject.eraseToAnyPublisher()
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        current = DonkPersistence.load(NetworkSettings.self, from: fileName, in: customDirectory ?? DonkPersistence.directory) ?? .default
        subject.value = current
    }

    private func persist() {
        writeLock.withLock {
            let value = lock.withLock { current }
            DonkPersistence.save(value, to: fileName, in: customDirectory ?? DonkPersistence.directory)
        }
    }
}

public enum HostPattern {
    public static func matches(_ host: String, pattern: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, !pattern.isEmpty else { return false }
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let domain = pattern.dropFirst(2)
            if !domain.contains("*") && !domain.contains("?") {
                return host == domain || host.hasSuffix("." + domain)
            }
        }
        if pattern.contains("*") || pattern.contains("?") {
            return Wildcard.matches(host, pattern: pattern)
        }
        return host == pattern
    }

    public static func matchesAny(_ host: String?, patterns: [String]) -> Bool {
        guard let host, !patterns.isEmpty else { return false }
        return patterns.contains { matches(host, pattern: $0) }
    }
}
