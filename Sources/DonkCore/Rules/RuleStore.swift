import Combine
import Foundation

public final class RuleStore: @unchecked Sendable {
    public static let shared = RuleStore()

    private struct State: Codable {
        var isEnabled: Bool
        var rules: [NetworkRule]

        init(isEnabled: Bool, rules: [NetworkRule]) {
            self.isEnabled = isEnabled
            self.rules = rules
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled, rules
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            rules = try container.decodeIfPresent(LenientArray<NetworkRule>.self, forKey: .rules)?.elements ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(isEnabled, forKey: .isEnabled)
            try container.encode(rules, forKey: .rules)
        }
    }

    private let lock = DonkLock()
    private let writeLock = DonkLock()
    private let fileName: String
    private let customDirectory: URL?
    private var isLoaded = false
    private var enabled = true
    private var storedRules: [NetworkRule] = []
    private var activeRules: [NetworkRule] = []
    private let subject: CurrentValueSubject<[NetworkRule], Never>
    private let publication: PublicationQueue<[NetworkRule]>

    public init(fileName: String = "rules.json", directory: URL? = nil) {
        self.fileName = fileName
        customDirectory = directory
        let subject = CurrentValueSubject<[NetworkRule], Never>([])
        self.subject = subject
        publication = PublicationQueue(latestOnly: true) { subject.send($0) }
    }

    // MARK: - State

    public var isEnabled: Bool {
        get { lock.withLock { loadIfNeeded(); return enabled } }
        set {
            let changed: Bool = lock.withLock {
                loadIfNeeded()
                guard enabled != newValue else { return false }
                enabled = newValue
                publication.enqueue(storedRules)
                return true
            }
            guard changed else { return }
            persist()
            publication.flush()
        }
    }

    public var rules: [NetworkRule] {
        lock.withLock { loadIfNeeded(); return storedRules }
    }

    public var hasActiveRules: Bool {
        lock.withLock { loadIfNeeded(); return enabled && !activeRules.isEmpty }
    }

    public var changes: AnyPublisher<[NetworkRule], Never> {
        lock.withLock { loadIfNeeded() }
        return subject.eraseToAnyPublisher()
    }

    // MARK: - Mutation

    public func add(_ rule: NetworkRule) {
        mutate { rules in
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
            } else {
                rules.append(rule)
            }
        }
    }

    public func update(_ rule: NetworkRule) {
        mutate { rules in
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index] = rule
        }
    }

    public func remove(_ id: UUID) {
        mutate { rules in
            rules.removeAll { $0.id == id }
        }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        mutate { rules in
            let valid = fromOffsets.filter { $0 >= 0 && $0 < rules.count }
            guard !valid.isEmpty else { return }
            let moving = valid.map { rules[$0] }
            let target = toOffset - valid.filter { $0 < toOffset }.count
            for index in valid.reversed() {
                rules.remove(at: index)
            }
            let destination = min(max(0, target), rules.count)
            rules.insert(contentsOf: moving, at: destination)
        }
    }

    public func removeAll() {
        mutate { $0.removeAll() }
    }

    // MARK: - Resolution

    public func resolve(kind: NetworkKind, method: String, url: String) -> RuleResolution {
        let candidates: [NetworkRule] = lock.withLock { loadIfNeeded(); return enabled ? activeRules : [] }
        guard !candidates.isEmpty, kind != .webView else { return .empty }
        var resolution = RuleResolution()
        for rule in candidates {
            let wantsTransform = resolution.transform == nil && rule.action.isTransform
            let wantsBreakpoint = resolution.breakpoint == nil && rule.action.isBreakpoint
            guard wantsTransform || wantsBreakpoint else { continue }
            guard rule.match.matches(kind: kind, method: method, url: url) else { continue }
            if wantsTransform {
                resolution.transform = rule
            } else {
                resolution.breakpoint = rule
            }
            if resolution.transform != nil, resolution.breakpoint != nil { break }
        }
        return resolution
    }

    // MARK: - Private

    private func mutate(_ change: (inout [NetworkRule]) -> Void) {
        let changed: Bool = lock.withLock {
            loadIfNeeded()
            var copy = storedRules
            change(&copy)
            guard copy != storedRules else { return false }
            storedRules = copy
            activeRules = copy.filter(\.isEnabled)
            publication.enqueue(copy)
            return true
        }
        guard changed else { return }
        persist()
        publication.flush()
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let state = DonkPersistence.load(State.self, from: fileName, in: customDirectory ?? DonkPersistence.directory)
            ?? State(isEnabled: true, rules: [])
        enabled = state.isEnabled
        storedRules = state.rules
        activeRules = state.rules.filter(\.isEnabled)
        subject.value = state.rules
    }

    private func persist() {
        writeLock.withLock {
            let state = lock.withLock { State(isEnabled: enabled, rules: storedRules) }
            DonkPersistence.save(state, to: fileName, in: customDirectory ?? DonkPersistence.directory)
        }
    }
}
