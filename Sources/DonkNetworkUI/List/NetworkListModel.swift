import Combine
import DonkCore
import DonkUI
import Foundation

// MARK: - Row item

struct NetworkRowItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: NetworkKind
    let method: String
    let title: String
    let host: String?
    let time: String
    let status: String
    let statusTone: DonkTone
    let barTone: DonkTone
    let isLive: Bool
    let isPaused: Bool
    let duration: String?
    let size: String?
    let origin: OriginBadge?
    let isPinned: Bool
    let initiator: String?
    let canRepeat: Bool

    init(_ entry: NetworkEntry) {
        id = entry.id
        kind = entry.kind
        method = entry.methodLabel
        title = entry.title.isEmpty ? entry.request.url : entry.title
        host = entry.host
        time = EntryFormat.clock(entry.timing.startedAt)
        status = EntryStyle.statusLabel(entry)
        statusTone = EntryStyle.statusTone(entry)
        barTone = EntryStyle.barTone(entry)
        isLive = entry.state == .pending || entry.state == .streaming
        isPaused = entry.state == .paused
        duration = entry.state.isInFlight ? nil : entry.duration.map(DonkFormat.duration)
        let bytes = entry.responseSize
        size = bytes > 0 ? DonkFormat.bytes(bytes) : nil
        origin = EntryStyle.originBadge(entry.origin)
        isPinned = entry.isPinned
        initiator = entry.kind == .webView ? entry.web.map { EntryStyle.initiatorTitle($0.initiator) } : nil
        canRepeat = EntryStyle.canRepeat(entry)
    }
}

// MARK: - Results

struct ListCounts: Equatable, Sendable {
    var total = 0
    var http = 0
    var grpc = 0
    var webView = 0
    var errors = 0
    var modified = 0
    var pinned = 0
    var hidden = 0
    var categories: [StatusCategory: Int] = [:]

    func count(for kind: NetworkKind) -> Int {
        switch kind {
        case .http: return http
        case .grpc: return grpc
        case .webView: return webView
        }
    }
}

struct HostCount: Identifiable, Equatable, Sendable {
    var host: String
    var count: Int
    var id: String { host }
}

struct ListResult: Sendable {
    var rows: [NetworkRowItem]
    var counts: ListCounts
    var hosts: [HostCount]
    var newCount: Int
}

enum ListComputation {
    static func run(entries: [NetworkEntry], filter: NetworkFilter, hidden: [String], known: Set<UUID>?) -> ListResult {
        var counts = ListCounts()
        var hostTally: [String: Int] = [:]
        let patterns = hidden.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for entry in entries {
            if let host = entry.host?.lowercased() {
                hostTally[host, default: 0] += 1
            }
            if !patterns.isEmpty, HostPattern.matchesAny(entry.host, patterns: patterns) {
                counts.hidden += 1
                continue
            }
            counts.total += 1
            switch entry.kind {
            case .http: counts.http += 1
            case .grpc: counts.grpc += 1
            case .webView: counts.webView += 1
            }
            let category = entry.statusCategory
            counts.categories[category, default: 0] += 1
            if EntryStyle.errorCategories.contains(category) { counts.errors += 1 }
            if entry.origin.isModified { counts.modified += 1 }
            if entry.isPinned { counts.pinned += 1 }
        }
        let filtered = NetworkSearch.apply(filter, hiddenHosts: patterns, to: entries)
        var rows: [NetworkRowItem] = []
        rows.reserveCapacity(filtered.count)
        var newCount = 0
        for entry in filtered {
            if let known, !known.contains(entry.id) {
                newCount += 1
                continue
            }
            rows.append(NetworkRowItem(entry))
        }
        var hosts: [HostCount] = hostTally.map { key, value in HostCount(host: key, count: value) }
        hosts.sort { (lhs: HostCount, rhs: HostCount) -> Bool in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.host < rhs.host
        }
        return ListResult(rows: rows, counts: counts, hosts: hosts, newCount: newCount)
    }
}

// MARK: - Model

@MainActor
final class NetworkListModel: ObservableObject {
    @Published private(set) var rows: [NetworkRowItem] = []
    @Published private(set) var counts = ListCounts()
    @Published private(set) var hosts: [HostCount] = []
    @Published private(set) var newCount = 0
    @Published private(set) var hasLoaded = false
    @Published private(set) var hiddenHosts: [String] = []
    @Published private(set) var isCaptureEnabled: Bool
    @Published private(set) var activeRuleCount = 0
    @Published private(set) var rulesEnabled = true
    @Published var searchText = ""
    @Published var filter = NetworkFilter() {
        didSet {
            guard filter != oldValue else { return }
            refresh(freeze: false)
        }
    }

    let store: NetworkStore
    private var cancellables = Set<AnyCancellable>()
    private var displayedIDs = Set<UUID>()
    private var isAtTop = true
    private var isComputing = false
    private var pendingRequest: Bool?

    init(store: NetworkStore = .shared) {
        self.store = store
        isCaptureEnabled = store.isCaptureEnabled
        hiddenHosts = NetworkSettingsStore.shared.settings.hiddenHosts
        bind()
        refresh(freeze: false)
    }

    // MARK: - Binding

    private func bind() {
        store.events
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.refresh(freeze: true)
            }
            .store(in: &cancellables)

        NetworkSettingsStore.shared.changes
            .map(\.hiddenHosts)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hosts in
                guard let self, hosts != self.hiddenHosts else { return }
                self.hiddenHosts = hosts
                self.refresh(freeze: false)
            }
            .store(in: &cancellables)

        RuleStore.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rules in
                self?.activeRuleCount = rules.filter(\.isEnabled).count
                self?.rulesEnabled = RuleStore.shared.isEnabled
            }
            .store(in: &cancellables)

        $searchText
            .removeDuplicates()
            .map { text -> AnyPublisher<String, Never> in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return Just(trimmed).eraseToAnyPublisher()
                }
                return Just(trimmed)
                    .delay(for: .milliseconds(250), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self, self.filter.query != query else { return }
                self.filter.query = query
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refresh(freeze: Bool) {
        if isComputing {
            pendingRequest = (pendingRequest ?? true) && freeze
            return
        }
        start(freeze: freeze)
    }

    private func start(freeze: Bool) {
        isComputing = true
        pendingRequest = nil
        let filter = filter
        let hidden = hiddenHosts
        let known: Set<UUID>? = freeze && !isAtTop && hasLoaded ? displayedIDs : nil
        let store = store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ListComputation.run(entries: store.snapshot(), filter: filter, hidden: hidden, known: known)
            }.value
            guard let self else { return }
            self.apply(result)
            self.isComputing = false
            if let next = self.pendingRequest {
                self.start(freeze: next)
            }
        }
    }

    private func apply(_ result: ListResult) {
        if rows != result.rows {
            rows = result.rows
            displayedIDs = Set(result.rows.map(\.id))
        }
        if counts != result.counts { counts = result.counts }
        if hosts != result.hosts { hosts = result.hosts }
        if newCount != result.newCount { newCount = result.newCount }
        if !hasLoaded { hasLoaded = true }
    }

    // MARK: - Scroll

    func setAtTop(_ value: Bool) {
        guard isAtTop != value else { return }
        isAtTop = value
        if value, newCount > 0 {
            refresh(freeze: false)
        }
    }

    func revealNew() {
        isAtTop = true
        refresh(freeze: false)
    }

    // MARK: - Filter helpers

    var isFiltering: Bool {
        !filter.isEmpty || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func resetFilters() {
        searchText = ""
        filter = NetworkFilter()
    }

    func toggleKind(_ kind: NetworkKind) {
        var kinds = filter.kinds
        if kinds.contains(kind) {
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
        if kinds.count == NetworkKind.allCases.count { kinds = [] }
        filter.kinds = kinds
    }

    var showsErrorsOnly: Bool {
        filter.statusCategories == EntryStyle.errorCategories
    }

    func toggleErrors() {
        filter.statusCategories = showsErrorsOnly ? [] : EntryStyle.errorCategories
    }

    var sheetFilterCount: Int {
        var count = 0
        if !filter.hosts.isEmpty { count += 1 }
        if !filter.statusCategories.isEmpty && !showsErrorsOnly { count += 1 }
        return count
    }

    // MARK: - Capture

    func setCaptureEnabled(_ enabled: Bool) {
        store.isCaptureEnabled = enabled
        isCaptureEnabled = enabled
        DonkHaptics.light()
        DonkToast.show(enabled ? "Capture resumed" : "Capture paused", icon: enabled ? "play.fill" : "pause.fill", tone: enabled ? .success : .warning)
    }

    func syncCaptureState() {
        let enabled = store.isCaptureEnabled
        if enabled != isCaptureEnabled { isCaptureEnabled = enabled }
    }

    // MARK: - Export

    func filteredEntries() -> [NetworkEntry] {
        let ids = Set(rows.map(\.id))
        return store.snapshot().filter { ids.contains($0.id) }
    }

    func clear() {
        store.clear(keepPinned: true)
        DonkHaptics.medium()
        refresh(freeze: false)
    }
}
