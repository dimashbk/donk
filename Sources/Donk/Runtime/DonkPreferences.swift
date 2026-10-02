import Combine
import DonkCore
import Foundation

// MARK: - Bubble placement

struct BubblePlacement: Codable, Equatable, Sendable {
    enum Edge: String, Codable, Sendable {
        case left, right
    }

    var edge: Edge
    var verticalFraction: Double

    static let `default` = BubblePlacement(edge: .right, verticalFraction: 0.72)

    init(edge: Edge, verticalFraction: Double) {
        self.edge = edge
        self.verticalFraction = min(max(verticalFraction, 0), 1)
    }
}

// MARK: - Preferences

struct DonkPreferences: Codable, Equatable, Sendable {
    static let defaultBreakpointTimeout: TimeInterval = 300

    var showsBubble: Bool?
    var opensOnShake: Bool?
    var captureEnabled: Bool
    var breakpointTimeout: TimeInterval
    var bubble: BubblePlacement

    init(
        showsBubble: Bool? = nil,
        opensOnShake: Bool? = nil,
        captureEnabled: Bool = true,
        breakpointTimeout: TimeInterval = DonkPreferences.defaultBreakpointTimeout,
        bubble: BubblePlacement = .default
    ) {
        self.showsBubble = showsBubble
        self.opensOnShake = opensOnShake
        self.captureEnabled = captureEnabled
        self.breakpointTimeout = breakpointTimeout
        self.bubble = bubble
    }

    private enum CodingKeys: String, CodingKey {
        case showsBubble, opensOnShake, captureEnabled, breakpointTimeout, bubble
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DonkPreferences()
        showsBubble = try? container.decodeIfPresent(Bool.self, forKey: .showsBubble)
        opensOnShake = try? container.decodeIfPresent(Bool.self, forKey: .opensOnShake)
        captureEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .captureEnabled)) ?? fallback.captureEnabled
        breakpointTimeout = (try? container.decodeIfPresent(TimeInterval.self, forKey: .breakpointTimeout)) ?? fallback.breakpointTimeout
        bubble = (try? container.decodeIfPresent(BubblePlacement.self, forKey: .bubble)) ?? fallback.bubble
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(showsBubble, forKey: .showsBubble)
        try container.encodeIfPresent(opensOnShake, forKey: .opensOnShake)
        try container.encode(captureEnabled, forKey: .captureEnabled)
        try container.encode(breakpointTimeout, forKey: .breakpointTimeout)
        try container.encode(bubble, forKey: .bubble)
    }
}

// MARK: - Store

final class DonkPreferencesStore: @unchecked Sendable {
    static let shared = DonkPreferencesStore()

    private static let fileName = "preferences.json"

    private let lock = NSLock()
    private var current: DonkPreferences
    private let subject: CurrentValueSubject<DonkPreferences, Never>

    init() {
        let loaded = DonkPersistence.load(DonkPreferences.self, from: Self.fileName) ?? DonkPreferences()
        current = loaded
        subject = CurrentValueSubject(loaded)
    }

    var value: DonkPreferences {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var changes: AnyPublisher<DonkPreferences, Never> {
        subject.eraseToAnyPublisher()
    }

    func update(_ change: (inout DonkPreferences) -> Void) {
        lock.lock()
        var copy = current
        change(&copy)
        guard copy != current else {
            lock.unlock()
            return
        }
        current = copy
        lock.unlock()
        DonkPersistence.save(copy, to: Self.fileName)
        subject.send(copy)
    }

    func reset() {
        update { $0 = DonkPreferences() }
    }
}

// MARK: - Live application

enum DonkLiveSettings {
    static func apply(_ preferences: DonkPreferences) {
        if NetworkStore.shared.isCaptureEnabled != preferences.captureEnabled {
            NetworkStore.shared.isCaptureEnabled = preferences.captureEnabled
        }
        if BreakpointCenter.shared.timeout != preferences.breakpointTimeout {
            BreakpointCenter.shared.timeout = preferences.breakpointTimeout
        }
    }
}
