import Combine
import DonkCore
import DonkCrash
import DonkInspector
import DonkNetwork
import DonkPerformance
import DonkUI
import Foundation

// MARK: - Stats

struct NetworkStats: Equatable, Sendable {
    var total = 0
    var failures = 0

    static func compute(_ entries: [NetworkEntry], hiddenHosts: [String]) -> NetworkStats {
        var stats = NetworkStats()
        for entry in entries {
            if !hiddenHosts.isEmpty, HostPattern.matchesAny(entry.host, patterns: hiddenHosts) {
                continue
            }
            stats.total += 1
            switch entry.statusCategory {
            case .clientError, .serverError, .failure:
                stats.failures += 1
            case .pending, .success, .redirect:
                break
            }
        }
        return stats
    }

    var subtitle: String {
        guard total > 0 else { return "No requests yet" }
        return "\(DonkFormat.compact(total)) \(total == 1 ? "request" : "requests")"
    }
}

// MARK: - Model

@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var stats = NetworkStats()
    @Published private(set) var activeRuleCount = 0
    @Published private(set) var paused: [PausedExchange] = []
    @Published private(set) var crashCount = 0
    @Published private(set) var isCrashReporterInstalled = false
    @Published private(set) var inspectorMode: InspectorMode?
    @Published private(set) var isHUDVisible = false
    @Published private(set) var isCaptureEnabled = true
    @Published var tools: Set<DonkTool> = Set(DonkTool.allCases)

    private let activity = HomeActivityGate()
    private let statsQueue = DispatchQueue(label: "dev.donk.home.stats", qos: .utility)
    private var cancellables: [AnyCancellable] = []

    init() {
        let gate = activity
        let networkChanges = NetworkStore.shared.events
            .map { _ in () }
            .merge(with: NetworkSettingsStore.shared.changes.map { _ in () })
            .merge(with: gate.refreshes)
            .filter { gate.isActive }
            .throttle(for: .milliseconds(400), scheduler: statsQueue, latest: true)
            .map { _ -> NetworkStats in
                NetworkStats.compute(
                    NetworkStore.shared.snapshot(),
                    hiddenHosts: NetworkSettingsStore.shared.settings.hiddenHosts
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                MainActor.assumeIsolated { self?.stats = stats }
            }
        let rules = RuleStore.shared.changes
            .map { rules -> Int in
                RuleStore.shared.isEnabled ? rules.filter(\.isEnabled).count : 0
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                MainActor.assumeIsolated { self?.activeRuleCount = count }
            }
        let breakpoints = BreakpointCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exchanges in
                MainActor.assumeIsolated { self?.paused = exchanges }
            }
        cancellables = [networkChanges, rules, breakpoints]
    }

    func setActive(_ isActive: Bool) {
        activity.isActive = isActive
        guard isActive else { return }
        refresh()
    }

    func refresh() {
        activity.requestRefresh()
        refreshLocalState()
        refreshCrashes()
    }

    func refreshLocalState() {
        inspectorMode = DonkInspector.activeMode
        isHUDVisible = DonkPerformance.isHUDVisible
        isCaptureEnabled = NetworkStore.shared.isCaptureEnabled
    }

    private func refreshCrashes() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let count = DonkCrash.reportCount()
            let installed = DonkCrash.isInstalled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.crashCount = count
                    self?.isCrashReporterInstalled = installed
                }
            }
        }
    }

    // MARK: - Toggles

    func setHUDVisible(_ isVisible: Bool) {
        DonkPerformance.isHUDVisible = isVisible
        DonkHaptics.light()
        isHUDVisible = DonkPerformance.isHUDVisible
    }

    func setInspector(_ mode: InspectorMode, isOn: Bool) {
        DonkHaptics.light()
        if isOn {
            DonkRuntime.shared.startInspector(mode)
        } else if DonkInspector.activeMode == mode {
            DonkRuntime.shared.stopInspector()
        }
        inspectorMode = isOn ? mode : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.inspectorMode = DonkInspector.activeMode }
        }
    }

    func setCaptureEnabled(_ isEnabled: Bool) {
        DonkHaptics.light()
        DonkPreferencesStore.shared.update { $0.captureEnabled = isEnabled }
        DonkLiveSettings.apply(DonkPreferencesStore.shared.value)
        isCaptureEnabled = NetworkStore.shared.isCaptureEnabled
    }
}

// MARK: - Activity gate

final class HomeActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private let subject = PassthroughSubject<Void, Never>()

    var isActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        set {
            lock.lock()
            active = newValue
            lock.unlock()
        }
    }

    var refreshes: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    func requestRefresh() {
        subject.send(())
    }
}
