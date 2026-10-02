import DonkCore
import DonkUI
import Foundation

// MARK: - Preferences

struct FileBrowserPreferences: Codable, Equatable {
    var sort: FileSort = .default
    var showsHidden = false

    private static let fileName = "storage-browser.json"
    private static let lock = DonkLock()
    private static var cached: FileBrowserPreferences?

    static var current: FileBrowserPreferences {
        get {
            lock.withLock {
                if let cached { return cached }
                let loaded = DonkPersistence.load(FileBrowserPreferences.self, from: fileName) ?? FileBrowserPreferences()
                cached = loaded
                return loaded
            }
        }
        set {
            lock.withLock { cached = newValue }
            DonkPersistence.save(newValue, to: fileName)
        }
    }
}

// MARK: - Model

@MainActor
final class FileBrowserModel: ObservableObject {
    let url: URL
    let isProtected: Bool

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var state: StorageLoadState = .idle
    @Published private(set) var totalCount = 0
    @Published private(set) var hiddenCount = 0
    @Published private(set) var folderSizes: [String: Int64] = [:]
    @Published var query = "" {
        didSet { if oldValue != query { apply() } }
    }
    @Published var sort: FileSort {
        didSet {
            guard oldValue != sort else { return }
            FileBrowserPreferences.current.sort = sort
            apply()
        }
    }
    @Published var showsHidden: Bool {
        didSet {
            guard oldValue != showsHidden else { return }
            FileBrowserPreferences.current.showsHidden = showsHidden
            apply()
        }
    }

    private var allItems: [FileItem] = []
    private var itemPaths: Set<String> = []
    private var requestedSizes: Set<String> = []
    private var pendingSizes: [String: Int64] = [:]
    private var isFlushScheduled = false
    private var generation = 0

    init(url: URL) {
        self.url = url
        self.isProtected = StorageLocations.isProtected(url)
        let preferences = FileBrowserPreferences.current
        self.sort = preferences.sort
        self.showsHidden = preferences.showsHidden
    }

    var totalFileSize: Int64? {
        var total: Int64 = 0
        for item in allItems {
            if let size = item.size {
                total += size
            } else if let size = folderSizes[item.path] {
                total += size
            } else {
                return nil
            }
        }
        return total
    }

    func loadIfNeeded() {
        guard state == .idle else { return }
        Task { await reload() }
    }

    func refresh() async {
        FolderSizeCache.shared.invalidate(url)
        await reload()
    }

    func reload() async {
        generation += 1
        let current = generation
        if allItems.isEmpty {
            state = .loading
        }
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DirectoryListing.list(url) }
        }.value
        guard current == generation else { return }
        switch result {
        case let .success(listed):
            allItems = listed
            itemPaths = Set(listed.map(\.path))
            requestedSizes.removeAll()
            var sizes: [String: Int64] = [:]
            for item in listed where item.isDirectory {
                sizes[item.path] = FolderSizeCache.shared.cachedSize(of: item.url)
            }
            folderSizes = sizes
            state = .loaded
            apply()
        case let .failure(error):
            allItems = []
            itemPaths = []
            state = .failed(error.localizedDescription)
            apply()
        }
    }

    func requestSize(for item: FileItem) {
        guard item.isDirectory, !requestedSizes.contains(item.path) else { return }
        requestedSizes.insert(item.path)
        let path = item.path
        FolderSizeCache.shared.requestSize(of: item.url) { [weak self] size in
            Task { @MainActor [weak self] in
                self?.enqueueSize(size, for: path)
            }
        }
    }

    // MARK: - Mutations

    func delete(_ item: FileItem) {
        guard !item.isProtected else { return }
        do {
            try FileOperations.delete(item.url)
            FolderSizeCache.shared.invalidate(item.url)
            allItems.removeAll { $0.id == item.id }
            itemPaths.remove(item.path)
            folderSizes[item.path] = nil
            apply()
            DonkHaptics.success()
            DonkToast.show("Deleted “\(item.name)”", icon: "trash.fill", tone: .success)
        } catch {
            report(error, action: "delete")
        }
    }

    func rename(_ item: FileItem, to name: String) {
        guard !item.isProtected, name != item.name else { return }
        do {
            try FileOperations.rename(item.url, to: name)
            FolderSizeCache.shared.invalidate(item.url)
            DonkHaptics.success()
            Task { await reload() }
        } catch {
            report(error, action: "rename")
        }
    }

    func createFolder(named name: String) {
        guard !isProtected else { return }
        do {
            let created = try FileOperations.createFolder(named: name, in: url)
            FolderSizeCache.shared.invalidate(created)
            DonkHaptics.success()
            Task { await reload() }
        } catch {
            report(error, action: "create folder")
        }
    }

    func createTextFile(named name: String) {
        guard !isProtected else { return }
        do {
            let created = try FileOperations.createTextFile(named: name, in: url)
            FolderSizeCache.shared.invalidate(created)
            DonkHaptics.success()
            Task { await reload() }
        } catch {
            report(error, action: "create file")
        }
    }

    func fileDidChange(_ fileURL: URL) {
        FolderSizeCache.shared.invalidate(fileURL)
        Task { await reload() }
    }

    // MARK: - Private

    private func enqueueSize(_ size: Int64, for path: String) {
        guard itemPaths.contains(path) else { return }
        pendingSizes[path] = size
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.flushSizes()
        }
    }

    private func flushSizes() {
        isFlushScheduled = false
        guard !pendingSizes.isEmpty else { return }
        folderSizes.merge(pendingSizes) { _, new in new }
        pendingSizes.removeAll()
        if sort.field == .size {
            apply()
        }
    }

    private func apply() {
        let visible = DirectoryListing.filtered(allItems, query: query, includeHidden: showsHidden)
        items = DirectoryListing.sorted(visible, by: sort, folderSizes: folderSizes)
        totalCount = allItems.count
        hiddenCount = allItems.lazy.filter(\.isHidden).count
    }

    private func report(_ error: Error, action: String) {
        DonkHaptics.error()
        DonkToast.show("Couldn't \(action): \(error.localizedDescription)", tone: .error, duration: 3)
    }
}
