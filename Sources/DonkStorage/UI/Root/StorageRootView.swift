import Combine
import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

@MainActor
final class StorageRootModel: ObservableObject {
    @Published private(set) var fileLocations: [StorageLocation] = []
    @Published private(set) var groupLocations: [StorageLocation] = []
    @Published private(set) var domains: [DefaultsDomain] = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var defaultsCounts: [String: Int] = [:]
    @Published private(set) var keychainSummary: String?
    @Published private(set) var cookieCount: Int?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshGeneration = 0

    init() {
        reloadConfiguration()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refreshDefaultsCounts() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSHTTPCookieManagerCookiesChanged)
            .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refreshCookies() }
            .store(in: &cancellables)
    }

    func reloadConfiguration() {
        let configuration = StorageEnvironment.shared.configuration
        fileLocations = StorageLocations.standard()
        groupLocations = StorageLocations.appGroups(configuration.appGroupIdentifiers)
        var seen = Set<String>()
        let standard = DefaultsDomain.standard
        domains = [standard] + configuration.userDefaultsSuites
            .filter { !$0.isEmpty && $0 != standard.name && seen.insert($0).inserted }
            .map(DefaultsDomain.suite)
    }

    func refresh(force: Bool) async {
        reloadConfiguration()
        refreshGeneration += 1
        let generation = refreshGeneration
        let locations = fileLocations + groupLocations
        if force {
            locations.forEach { FolderSizeCache.shared.invalidate($0.url) }
        }
        for location in locations {
            if let cached = FolderSizeCache.shared.cachedSize(of: location.url) {
                sizes[location.id] = cached
            } else if force {
                sizes[location.id] = nil
            }
        }
        refreshDefaultsCounts()
        refreshCookies()
        refreshKeychain()
        await withTaskGroup(of: (String, Int64).self) { group in
            for location in locations {
                group.addTask { (location.id, await FolderSizeCache.shared.size(of: location.url)) }
            }
            for await (id, size) in group where generation == refreshGeneration {
                sizes[id] = size
            }
        }
    }

    private func refreshDefaultsCounts() {
        let domains = self.domains
        Task { [weak self] in
            let counts = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: domains.map { ($0.id, DefaultsStore.count(in: $0)) })
            }.value
            self?.defaultsCounts = counts
        }
    }

    private func refreshCookies() {
        Task { [weak self] in
            let count = await Task.detached(priority: .userInitiated) {
                HTTPCookieStorage.shared.cookies?.count ?? 0
            }.value
            self?.cookieCount = count
        }
    }

    private func refreshKeychain() {
        Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let count = try KeychainStore.items().count
                    return count == 1 ? "1 item" : "\(count) items"
                } catch KeychainError.missingEntitlement {
                    return "Unavailable · missing entitlement"
                } catch {
                    return "Unavailable"
                }
            }.value
            self?.keychainSummary = summary
        }
    }
}

// MARK: - View

struct StorageRootView: View {
    @StateObject private var model = StorageRootModel()

    var body: some View {
        List {
            Section {
                ForEach(model.fileLocations) { location in
                    NavigationLink {
                        FileBrowserView(url: location.url, title: location.title)
                    } label: {
                        DonkLabelRow(
                            icon: icon(for: location),
                            tone: tone(for: location),
                            title: location.title,
                            subtitle: sizeText(for: location)
                        )
                    }
                }
                ForEach(model.groupLocations) { location in
                    NavigationLink {
                        FileBrowserView(url: location.url, title: location.title)
                    } label: {
                        DonkLabelRow(
                            icon: "person.2.fill",
                            tone: .grpc,
                            title: location.title,
                            subtitle: "App Group · " + sizeText(for: location)
                        )
                    }
                }
            } header: {
                DonkSectionHeader("Files", icon: "folder.fill")
            } footer: {
                Text("donk keeps its own data in Library/Application Support/Donk. It is marked with a donk badge and is read-only here.")
            }

            Section {
                ForEach(model.domains) { domain in
                    NavigationLink {
                        DefaultsListView(domain: domain)
                    } label: {
                        DonkLabelRow(
                            icon: domain.kind == .standard ? "gearshape.fill" : "square.stack.3d.up.fill",
                            tone: domain.kind == .standard ? .accent : .grpc,
                            title: domain.title,
                            subtitle: defaultsSubtitle(for: domain)
                        )
                    }
                }
            } header: {
                DonkSectionHeader("UserDefaults", icon: "slider.horizontal.3")
            }

            Section {
                NavigationLink {
                    KeychainListView()
                } label: {
                    DonkLabelRow(
                        icon: "key.fill",
                        tone: .warning,
                        title: "Keychain",
                        subtitle: model.keychainSummary ?? "Counting…"
                    )
                }
                NavigationLink {
                    CookiesListView()
                } label: {
                    DonkLabelRow(
                        icon: "globe",
                        tone: .web,
                        title: "HTTP Cookies",
                        subtitle: model.cookieCount.map { $0 == 1 ? "1 cookie" : "\($0) cookies" } ?? "Counting…"
                    )
                }
            } header: {
                DonkSectionHeader("Keychain & Cookies", icon: "lock.fill")
            }
        }
        .donkListStyle()
        .donkNavigationTitle("Storage")
        .refreshable {
            await model.refresh(force: true)
        }
        .task {
            await model.refresh(force: false)
        }
    }

    private func sizeText(for location: StorageLocation) -> String {
        model.sizes[location.id].map { DonkFormat.bytes($0) } ?? "Calculating…"
    }

    private func defaultsSubtitle(for domain: DefaultsDomain) -> String {
        let count = model.defaultsCounts[domain.id].map { $0 == 1 ? "1 key" : "\($0) keys" } ?? "Counting…"
        if domain.kind == .standard {
            return domain.name.isEmpty ? count : domain.name + " · " + count
        }
        return "Suite · " + count
    }

    private func icon(for location: StorageLocation) -> String {
        switch location.kind {
        case .sandbox: return "house.fill"
        case .documents: return "doc.fill"
        case .library: return "books.vertical.fill"
        case .caches: return "archivebox.fill"
        case .temporary: return "clock.fill"
        case .appGroup: return "person.2.fill"
        }
    }

    private func tone(for location: StorageLocation) -> DonkTone {
        switch location.kind {
        case .sandbox: return .accent
        case .documents: return .info
        case .library: return .grpc
        case .caches: return .warning
        case .temporary: return .neutral
        case .appGroup: return .grpc
        }
    }
}
