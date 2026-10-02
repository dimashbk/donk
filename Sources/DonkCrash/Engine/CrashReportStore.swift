import Combine
import DonkCore
import Foundation

final class CrashReportStore: @unchecked Sendable {
    let directory: URL
    let limit: Int
    private let lock = DonkLock()
    private var cache: [CrashReport]?
    private let subject = PassthroughSubject<[CrashReport], Never>()

    init(directory: URL, limit: Int = 200) {
        self.directory = directory
        self.limit = limit
    }

    var changes: AnyPublisher<[CrashReport], Never> {
        subject.eraseToAnyPublisher()
    }

    var count: Int {
        lock.withLock { loadedLocked().count }
    }

    func all() -> [CrashReport] {
        lock.withLock { loadedLocked() }
    }

    func report(_ id: UUID) -> CrashReport? {
        all().first { $0.id == id }
    }

    func add(_ report: CrashReport) {
        add([report])
    }

    func add(_ reports: [CrashReport]) {
        guard !reports.isEmpty else { return }
        let snapshot: [CrashReport] = lock.withLock {
            ensureDirectory()
            var current = loadedLocked()
            for report in reports {
                if let data = CrashJSON.encode(report) {
                    try? data.write(to: fileURL(report.id), options: .atomic)
                }
                current.removeAll { $0.id == report.id }
                current.append(report)
            }
            current.sort(by: CrashReportStore.newestFirst)
            if current.count > limit {
                for stale in current[limit...] {
                    try? FileManager.default.removeItem(at: fileURL(stale.id))
                }
                current = Array(current.prefix(limit))
            }
            cache = current
            return current
        }
        subject.send(snapshot)
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let snapshot: [CrashReport] = lock.withLock {
            var current = loadedLocked()
            for id in ids {
                try? FileManager.default.removeItem(at: fileURL(id))
            }
            current.removeAll { ids.contains($0.id) }
            cache = current
            return current
        }
        subject.send(snapshot)
    }

    func deleteAll() {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
            cache = []
        }
        subject.send([])
    }

    func reload() {
        let snapshot: [CrashReport] = lock.withLock {
            cache = nil
            return loadedLocked()
        }
        subject.send(snapshot)
    }

    private func loadedLocked() -> [CrashReport] {
        if let cache {
            return cache
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let reports = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CrashReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return CrashJSON.decode(CrashReport.self, from: data)
            }
            .sorted(by: CrashReportStore.newestFirst)
        cache = reports
        return reports
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func newestFirst(_ lhs: CrashReport, _ rhs: CrashReport) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date > rhs.date
    }
}
