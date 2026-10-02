import Combine
import DonkCore
import DonkUI
import Foundation

@MainActor
final class EntryDetailModel: ObservableObject {
    @Published private(set) var entry: NetworkEntry?
    @Published private(set) var isRemoved = false
    @Published private(set) var pausedExchange: PausedExchange?
    @Published private(set) var redaction: RedactionPolicy?

    let id: UUID
    private let store: NetworkStore
    private var cancellables = Set<AnyCancellable>()

    init(id: UUID, store: NetworkStore = .shared) {
        self.id = id
        self.store = store
        entry = store.entry(id)
        isRemoved = entry == nil
        pausedExchange = BreakpointCenter.shared.pending.first { $0.entryID == id }
        redaction = NetworkSettingsStore.shared.settings.exportRedaction
        NetworkSettingsStore.shared.changes
            .map(\.exportRedaction)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] policy in
                guard let self, self.redaction != policy else { return }
                self.redaction = policy
            }
            .store(in: &cancellables)
        store.events
            .filter { event in
                switch event {
                case let .added(changed), let .updated(changed): return changed == id
                case let .removed(ids): return ids.contains(id)
                case .cleared: return true
                }
            }
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)
        BreakpointCenter.shared.changes
            .map { pending in pending.first { $0.entryID == id } }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exchange in
                guard let self, self.pausedExchange?.id != exchange?.id else { return }
                self.pausedExchange = exchange
            }
            .store(in: &cancellables)
    }

    private func reload() {
        if let current = store.entry(id) {
            if current != entry { entry = current }
            if isRemoved { isRemoved = false }
        } else if !isRemoved {
            isRemoved = true
        }
    }

    func togglePin() {
        EntryActions.togglePin(id)
        reload()
    }

    var redactsSecrets: Bool {
        redaction != nil
    }

    func setRedactsSecrets(_ value: Bool) {
        DonkHaptics.selection()
        NetworkSettingsStore.shared.update { $0.redactsExports = value }
        redaction = NetworkSettingsStore.shared.settings.exportRedaction
        DonkToast.show(value ? "Secrets are redacted" : "Exports include secrets", icon: value ? "lock.fill" : "lock.open", tone: value ? .success : .warning, duration: 1.4)
    }

    var headerMask: HeaderMask? {
        redaction.map(HeaderMask.init)
    }
}

struct HeaderMask {
    private let names: Set<String>

    init(_ policy: RedactionPolicy) {
        names = Set(policy.headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    func masks(_ name: String) -> Bool {
        names.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
