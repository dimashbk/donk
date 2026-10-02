import Combine
import DonkCore
import Foundation

final class PushHistoryStore: @unchecked Sendable {
    static let shared = PushHistoryStore()
    static let defaultLimit = 100

    let limit: Int
    private let directory: URL?
    private let fileName: String
    private let lock = DonkLock()
    private let ioQueue = DispatchQueue(label: "dev.donk.push.history", qos: .utility)
    private var storedRecords: [PushRecord] = []
    private var isLoaded = false
    private let subject = PassthroughSubject<[PushRecord], Never>()

    init(directory: URL? = nil, fileName: String = "push-history.json", limit: Int = PushHistoryStore.defaultLimit) {
        self.directory = directory
        self.fileName = fileName
        self.limit = max(1, limit)
    }

    var records: [PushRecord] {
        lock.withLock {
            loadIfNeeded()
            return storedRecords
        }
    }

    var count: Int {
        records.count
    }

    var changes: AnyPublisher<[PushRecord], Never> {
        subject.eraseToAnyPublisher()
    }

    func record(_ id: UUID) -> PushRecord? {
        records.first { $0.id == id }
    }

    func append(_ record: PushRecord) {
        mutate { records in
            records.insert(record, at: 0)
            if records.count > limit {
                records.removeLast(records.count - limit)
            }
        }
    }

    func update(_ id: UUID, _ transform: @escaping (inout PushRecord) -> Void) {
        mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            transform(&records[index])
        }
    }

    func remove(_ ids: Set<UUID>) {
        mutate { records in
            records.removeAll { ids.contains($0.id) }
        }
    }

    func clear() {
        mutate { records in
            records.removeAll()
        }
    }

    func flush() {
        ioQueue.sync {}
    }

    private func mutate(_ body: (inout [PushRecord]) -> Void) {
        let snapshot: [PushRecord] = lock.withLock {
            loadIfNeeded()
            body(&storedRecords)
            persist(storedRecords)
            return storedRecords
        }
        subject.send(snapshot)
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let loaded: [PushRecord]?
        if let directory {
            loaded = DonkPersistence.load([PushRecord].self, from: fileName, in: directory)
        } else {
            loaded = DonkPersistence.load([PushRecord].self, from: fileName)
        }
        storedRecords = Array((loaded ?? []).prefix(limit))
    }

    private func persist(_ records: [PushRecord]) {
        let directory = directory
        let fileName = fileName
        ioQueue.async {
            if let directory {
                DonkPersistence.save(records, to: fileName, in: directory)
            } else {
                DonkPersistence.save(records, to: fileName)
            }
        }
    }
}
