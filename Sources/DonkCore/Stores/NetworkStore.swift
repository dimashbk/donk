import Combine
import Foundation

public enum NetworkStoreEvent: Sendable, Equatable {
    case added(UUID)
    case updated(UUID)
    case removed(Set<UUID>)
    case cleared
}

public final class NetworkStore: @unchecked Sendable {
    public static let shared = NetworkStore()
    public static let defaultMaxTotalBytes = 96 * 1024 * 1024

    private struct Stored {
        var entry: NetworkEntry
        var sequence: UInt64
        var cost: Int
    }

    private struct Slot {
        var id: UUID
        var sequence: UInt64
    }

    private let lock = DonkLock()
    private var entries: [UUID: Stored] = [:]
    private var order: [Slot] = []
    private var head = 0
    private var staleCount = 0
    private var nextSequence: UInt64 = 0
    private var totalCost = 0
    private var storedLimit: Int
    private var storedMaxBodySize: Int
    private var storedMaxTotalBytes: Int
    private var captureEnabled = true
    private let subject: PassthroughSubject<NetworkStoreEvent, Never>
    private let publication: PublicationQueue<NetworkStoreEvent>

    public init(limit: Int = 1000, maxBodySize: Int = 2 * 1024 * 1024, maxTotalBytes: Int = NetworkStore.defaultMaxTotalBytes) {
        storedLimit = max(1, limit)
        storedMaxBodySize = max(0, maxBodySize)
        storedMaxTotalBytes = max(0, maxTotalBytes)
        let subject = PassthroughSubject<NetworkStoreEvent, Never>()
        self.subject = subject
        publication = PublicationQueue { subject.send($0) }
    }

    // MARK: - Configuration

    public var limit: Int {
        get { lock.withLock { storedLimit } }
        set {
            lock.withLock {
                storedLimit = max(1, newValue)
                evictAndCompactLocked(protecting: nil)
            }
            publication.flush()
        }
    }

    public var maxTotalBytes: Int {
        get { lock.withLock { storedMaxTotalBytes } }
        set {
            lock.withLock {
                storedMaxTotalBytes = max(0, newValue)
                evictAndCompactLocked(protecting: nil)
            }
            publication.flush()
        }
    }

    public var totalBytes: Int {
        lock.withLock { totalCost }
    }

    public var maxBodySize: Int {
        get { lock.withLock { storedMaxBodySize } }
        set { lock.withLock { storedMaxBodySize = max(0, newValue) } }
    }

    public var isCaptureEnabled: Bool {
        get { lock.withLock { captureEnabled } }
        set { lock.withLock { captureEnabled = newValue } }
    }

    public func configure(with settings: NetworkSettings) {
        maxBodySize = settings.maxBodySize
        limit = settings.limit
    }

    // MARK: - Mutation

    public func add(_ entry: NetworkEntry) {
        let id = entry.id
        lock.withLock {
            let cost = Self.cost(of: entry)
            if let existing = entries[id] {
                totalCost += cost - existing.cost
                entries[id] = Stored(entry: entry, sequence: existing.sequence, cost: cost)
                publication.enqueue(.updated(id))
            } else {
                nextSequence &+= 1
                entries[id] = Stored(entry: entry, sequence: nextSequence, cost: cost)
                order.append(Slot(id: id, sequence: nextSequence))
                totalCost += cost
                publication.enqueue(.added(id))
            }
            evictAndCompactLocked(protecting: id)
        }
        publication.flush()
    }

    public func update(_ id: UUID, _ transform: (inout NetworkEntry) -> Void) {
        lock.withLock {
            guard entries[id] != nil else { return }
            transform(&entries[id]!.entry)
            entries[id]!.entry.id = id
            let cost = Self.cost(of: entries[id]!.entry)
            totalCost += cost - entries[id]!.cost
            entries[id]!.cost = cost
            publication.enqueue(.updated(id))
            if totalCost > storedMaxTotalBytes {
                evictAndCompactLocked(protecting: id)
            }
        }
        publication.flush()
    }

    public func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var removed = Set<UUID>()
            for id in ids {
                guard let stored = entries.removeValue(forKey: id) else { continue }
                totalCost -= stored.cost
                removed.insert(id)
            }
            guard !removed.isEmpty else { return }
            staleCount += removed.count
            compactIfNeededLocked()
            publication.enqueue(.removed(removed))
        }
        publication.flush()
    }

    public func clear(keepPinned: Bool = true) {
        lock.withLock {
            if keepPinned {
                order = order[head...].filter { slot in
                    guard let stored = entries[slot.id], stored.sequence == slot.sequence else { return false }
                    return stored.entry.isPinned
                }
                entries = entries.filter { $0.value.entry.isPinned }
                totalCost = entries.values.reduce(0) { $0 + $1.cost }
            } else {
                entries.removeAll()
                order.removeAll()
                totalCost = 0
            }
            head = 0
            staleCount = 0
            publication.enqueue(.cleared)
        }
        publication.flush()
    }

    // MARK: - Reading

    public func entry(_ id: UUID) -> NetworkEntry? {
        lock.withLock { entries[id]?.entry }
    }

    public func snapshot() -> [NetworkEntry] {
        lock.withLock {
            var result: [NetworkEntry] = []
            result.reserveCapacity(entries.count)
            var index = order.count - 1
            while index >= head {
                let slot = order[index]
                if let stored = entries[slot.id], stored.sequence == slot.sequence {
                    result.append(stored.entry)
                }
                index -= 1
            }
            return result
        }
    }

    public var hosts: [String] {
        let requests = lock.withLock { entries.values.map(\.entry.request.url) }
        var unique = Set<String>()
        for url in requests {
            if let host = URLParts.host(of: url)?.lowercased() {
                unique.insert(host)
            }
        }
        return unique.sorted()
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public var events: AnyPublisher<NetworkStoreEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    // MARK: - Budget

    static func cost(of entry: NetworkEntry) -> Int {
        (entry.request.body?.data.count ?? 0)
            + (entry.response?.body?.data.count ?? 0)
            + (entry.grpc?.storedMessageBytes ?? 0)
    }

    private var isOverBudgetLocked: Bool {
        entries.count > storedLimit || totalCost > storedMaxTotalBytes
    }

    private func evictAndCompactLocked(protecting protected: UUID?) {
        let removed = evictLocked(protecting: protected)
        compactIfNeededLocked()
        if !removed.isEmpty {
            publication.enqueue(.removed(removed))
        }
    }

    private func evictLocked(protecting protected: UUID?) -> Set<UUID> {
        var removed = Set<UUID>()
        var index = head
        while isOverBudgetLocked, index < order.count {
            let slot = order[index]
            guard let stored = entries[slot.id], stored.sequence == slot.sequence else {
                if index == head {
                    head += 1
                    staleCount -= 1
                }
                index += 1
                continue
            }
            if stored.entry.isPinned || slot.id == protected {
                index += 1
                continue
            }
            entries[slot.id] = nil
            totalCost -= stored.cost
            removed.insert(slot.id)
            if index == head {
                head += 1
            } else {
                staleCount += 1
            }
            index += 1
        }
        return removed
    }

    private func compactIfNeededLocked() {
        let waste = head + staleCount
        guard waste > 64, waste * 2 > order.count else { return }
        order = order[head...].filter { slot in
            entries[slot.id]?.sequence == slot.sequence
        }
        head = 0
        staleCount = 0
    }
}
