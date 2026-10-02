import Foundation

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let kind: FileKind?
    let isProtected: Bool

    var id: String { url.path }
    var path: String { url.path }
}

enum FileSortField: String, CaseIterable, Codable, Sendable {
    case name = "Name"
    case size = "Size"
    case date = "Date"

    var defaultAscending: Bool {
        self == .name
    }

    var icon: String {
        switch self {
        case .name: return "textformat.abc"
        case .size: return "arrow.up.arrow.down"
        case .date: return "calendar"
        }
    }
}

struct FileSort: Hashable, Codable, Sendable {
    var field: FileSortField
    var ascending: Bool

    static let `default` = FileSort(field: .name, ascending: true)
}

enum DirectoryListing {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    static func list(_ directory: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        let roots = StorageLocations.protectedPaths
        let canonicalDirectory = StorageLocations.canonicalPath(directory)
        let directoryIsProtected = StorageLocations.isProtected(canonicalPath: canonicalDirectory, roots: roots)
        let keySet = Set(resourceKeys)
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keySet)
            let name = url.lastPathComponent
            let isLink = values?.isSymbolicLink ?? false
            var isDirectory = values?.isDirectory ?? false
            if isLink {
                let target = url.resolvingSymlinksInPath()
                isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            let childPath = canonicalDirectory == "/" ? "/" + name : canonicalDirectory + "/" + name
            return FileItem(
                url: url,
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isLink,
                isHidden: (values?.isHidden ?? false) || name.hasPrefix("."),
                size: isDirectory ? nil : Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                created: values?.creationDate,
                kind: isDirectory ? .folder : FileKind.guess(pathExtension: url.pathExtension),
                isProtected: directoryIsProtected || roots.contains(childPath)
            )
        }
    }

    static func sorted(_ items: [FileItem], by sort: FileSort, folderSizes: [String: Int64] = [:]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch sort.field {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order == .orderedSame { return lhs.path < rhs.path }
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            case .size:
                let left = lhs.size ?? folderSizes[lhs.path] ?? -1
                let right = rhs.size ?? folderSizes[rhs.path] ?? -1
                if left == right { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return sort.ascending ? left < right : left > right
            case .date:
                let left = lhs.modified ?? .distantPast
                let right = rhs.modified ?? .distantPast
                if left == right { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
                return sort.ascending ? left < right : left > right
            }
        }
    }

    static func filtered(_ items: [FileItem], query: String, includeHidden: Bool) -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if !includeHidden && item.isHidden { return false }
            if trimmed.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

// MARK: - Folder sizes

final class FolderSizeCache: @unchecked Sendable {
    static let shared = FolderSizeCache()
    static let freshness: TimeInterval = 10

    private struct Entry {
        let size: Int64
        let date: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var waiters: [String: [@Sendable (Int64) -> Void]] = [:]
    private var staleInFlight: Set<String> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.donk.storage.folder-sizes"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    func cachedSize(of url: URL) -> Int64? {
        let key = Self.key(url)
        return lock.withLock { entries[key]?.size }
    }

    func size(of url: URL, maxAge: TimeInterval = FolderSizeCache.freshness) async -> Int64 {
        await withCheckedContinuation { continuation in
            requestSize(of: url, maxAge: maxAge) { continuation.resume(returning: $0) }
        }
    }

    func requestSize(
        of url: URL,
        maxAge: TimeInterval = FolderSizeCache.freshness,
        completion: @escaping @Sendable (Int64) -> Void
    ) {
        let key = Self.key(url)
        enum Action { case cached(Int64), waiting, start }
        let action: Action = lock.withLock {
            if let entry = entries[key], Date().timeIntervalSince(entry.date) < maxAge {
                return .cached(entry.size)
            }
            if waiters[key] != nil {
                waiters[key]?.append(completion)
                return .waiting
            }
            waiters[key] = [completion]
            return .start
        }
        switch action {
        case let .cached(size):
            completion(size)
        case .waiting:
            break
        case .start:
            queue.addOperation { [weak self] in
                let size = Self.computeSize(of: url)
                self?.finish(key, size: size)
            }
        }
    }

    func invalidate(_ url: URL) {
        let path = Self.key(url)
        lock.withLock {
            func affected(_ key: String) -> Bool {
                key == path || path.hasPrefix(key + "/") || key.hasPrefix(path + "/")
            }
            entries = entries.filter { !affected($0.key) }
            for key in waiters.keys where affected(key) {
                staleInFlight.insert(key)
            }
        }
    }

    func invalidateAll() {
        lock.withLock {
            entries.removeAll()
            staleInFlight.formUnion(waiters.keys)
        }
    }

    static func computeSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        let keySet = Set(keys)
        while let next = enumerator.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: keySet), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func finish(_ key: String, size: Int64) {
        let callbacks: [@Sendable (Int64) -> Void] = lock.withLock {
            if staleInFlight.remove(key) == nil {
                entries[key] = Entry(size: size, date: Date())
            }
            return waiters.removeValue(forKey: key) ?? []
        }
        callbacks.forEach { $0(size) }
    }

    private static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
