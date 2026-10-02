import Combine
import DonkCore
import DonkUI
import Foundation

struct BubbleActivity: Equatable, Sendable {
    var added = 0
    var tone: DonkTone?
    var cleared = false

    var isEmpty: Bool {
        added == 0 && tone == nil && !cleared
    }

    static func tone(for entry: NetworkEntry) -> DonkTone? {
        switch entry.state {
        case .completed, .failed:
            break
        case .pending, .paused, .streaming, .cancelled:
            return nil
        }
        switch entry.statusCategory {
        case .success, .redirect:
            return .success
        case .clientError:
            return .warning
        case .serverError, .failure:
            return .error
        case .pending:
            return nil
        }
    }

    static func severity(_ tone: DonkTone?) -> Int {
        switch tone {
        case .error: return 3
        case .warning: return 2
        case .success: return 1
        default: return 0
        }
    }

    mutating func merge(tone newTone: DonkTone) {
        if Self.severity(newTone) > Self.severity(tone) {
            tone = newTone
        }
    }
}

final class BubbleActivityMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.donk.bubble.activity", qos: .utility)
    private let store: NetworkStore
    private let deliver: @Sendable (BubbleActivity) -> Void
    private let flushInterval: TimeInterval
    private let terminalCapacity = 4000

    private var cancellable: AnyCancellable?
    private var terminal = Set<UUID>()
    private var terminalOrder: [UUID] = []
    private var pending = BubbleActivity()
    private var isFlushScheduled = false

    init(store: NetworkStore = .shared, flushInterval: TimeInterval = 0.15, deliver: @escaping @Sendable (BubbleActivity) -> Void) {
        self.store = store
        self.flushInterval = flushInterval
        self.deliver = deliver
    }

    func start() {
        queue.async { [self] in
            guard cancellable == nil else { return }
            cancellable = store.events
                .receive(on: queue)
                .sink { [weak self] event in self?.handle(event) }
        }
    }

    func stop() {
        queue.async { [self] in
            cancellable?.cancel()
            cancellable = nil
            terminal.removeAll()
            terminalOrder.removeAll()
            pending = BubbleActivity()
        }
    }

    private func handle(_ event: NetworkStoreEvent) {
        switch event {
        case let .added(id):
            guard let entry = store.entry(id), isVisible(entry) else { return }
            pending.added += 1
            markTerminalIfNeeded(entry)
        case let .updated(id):
            guard !terminal.contains(id), let entry = store.entry(id), isVisible(entry) else { return }
            markTerminalIfNeeded(entry)
        case let .removed(ids):
            terminal.subtract(ids)
        case .cleared:
            terminal.removeAll()
            terminalOrder.removeAll()
            pending = BubbleActivity()
            pending.cleared = true
        }
        scheduleFlush()
    }

    private func isVisible(_ entry: NetworkEntry) -> Bool {
        !HostPattern.matchesAny(entry.host, patterns: NetworkSettingsStore.shared.settings.hiddenHosts)
    }

    private func markTerminalIfNeeded(_ entry: NetworkEntry) {
        guard let tone = BubbleActivity.tone(for: entry) else { return }
        guard terminal.insert(entry.id).inserted else { return }
        terminalOrder.append(entry.id)
        if terminalOrder.count > terminalCapacity {
            let overflow = terminalOrder.count - terminalCapacity / 2
            terminal.subtract(terminalOrder.prefix(overflow))
            terminalOrder.removeFirst(overflow)
        }
        pending.merge(tone: tone)
    }

    private func scheduleFlush() {
        guard !isFlushScheduled, !pending.isEmpty else { return }
        isFlushScheduled = true
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        let activity = pending
        pending = BubbleActivity()
        guard !activity.isEmpty else { return }
        deliver(activity)
    }
}
