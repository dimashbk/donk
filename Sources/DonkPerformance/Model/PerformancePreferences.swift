import Combine
import DonkCore
import Foundation

public enum PerformanceSamplingRate: Double, Codable, CaseIterable, Sendable, Identifiable {
    case half = 0.5
    case one = 1
    case two = 2

    public var id: Double { rawValue }

    public var interval: TimeInterval {
        1 / rawValue
    }

    public var title: String {
        switch self {
        case .half: return "0.5 Hz"
        case .one: return "1 Hz"
        case .two: return "2 Hz"
        }
    }
}

enum HUDEdge: String, Codable, Sendable {
    case leading
    case trailing
}

struct PerformancePreferences: Codable, Equatable, Sendable {
    var isHUDVisible = false
    var isHUDExpanded = false
    var hudEdge: HUDEdge = .leading
    var hudVerticalFraction: Double = 0.04
    var hudStaysAboveKeyboard = false
    var samplingRate: PerformanceSamplingRate = .one
    var prefersHighRefreshRate = false
    var alerts = PerformanceAlertSettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isHUDVisible, isHUDExpanded, hudEdge, hudVerticalFraction, hudStaysAboveKeyboard, samplingRate, prefersHighRefreshRate, alerts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PerformancePreferences()
        isHUDVisible = (try? container.decodeIfPresent(Bool.self, forKey: .isHUDVisible)) ?? defaults.isHUDVisible
        isHUDExpanded = (try? container.decodeIfPresent(Bool.self, forKey: .isHUDExpanded)) ?? defaults.isHUDExpanded
        hudEdge = (try? container.decodeIfPresent(HUDEdge.self, forKey: .hudEdge)) ?? defaults.hudEdge
        let fraction = (try? container.decodeIfPresent(Double.self, forKey: .hudVerticalFraction)) ?? defaults.hudVerticalFraction
        hudVerticalFraction = min(max(fraction, 0), 1)
        hudStaysAboveKeyboard = (try? container.decodeIfPresent(Bool.self, forKey: .hudStaysAboveKeyboard)) ?? defaults.hudStaysAboveKeyboard
        samplingRate = (try? container.decodeIfPresent(PerformanceSamplingRate.self, forKey: .samplingRate)) ?? defaults.samplingRate
        prefersHighRefreshRate = (try? container.decodeIfPresent(Bool.self, forKey: .prefersHighRefreshRate)) ?? defaults.prefersHighRefreshRate
        alerts = (try? container.decodeIfPresent(PerformanceAlertSettings.self, forKey: .alerts)) ?? defaults.alerts
    }
}

final class PerformancePreferencesStore: @unchecked Sendable {
    static let shared = PerformancePreferencesStore()

    private let lock = DonkLock()
    private let fileName: String
    private let directory: URL?
    private let ioQueue = DispatchQueue(label: "io.github.donk.performance.preferences", qos: .utility)
    private let subject: CurrentValueSubject<PerformancePreferences, Never>
    private var storage: PerformancePreferences

    init(fileName: String = "performance.json", directory: URL? = nil) {
        self.fileName = fileName
        self.directory = directory
        let loaded: PerformancePreferences?
        if let directory {
            loaded = DonkPersistence.load(PerformancePreferences.self, from: fileName, in: directory)
        } else {
            loaded = DonkPersistence.load(PerformancePreferences.self, from: fileName)
        }
        storage = loaded ?? PerformancePreferences()
        subject = CurrentValueSubject(storage)
    }

    var value: PerformancePreferences {
        lock.withLock { storage }
    }

    var changes: AnyPublisher<PerformancePreferences, Never> {
        subject.eraseToAnyPublisher()
    }

    func update(_ transform: (inout PerformancePreferences) -> Void) {
        let snapshot: PerformancePreferences? = lock.withLock {
            var copy = storage
            transform(&copy)
            guard copy != storage else { return nil }
            storage = copy
            return copy
        }
        guard let snapshot else { return }
        let fileName = fileName
        let directory = directory
        ioQueue.async {
            if let directory {
                DonkPersistence.save(snapshot, to: fileName, in: directory)
            } else {
                DonkPersistence.save(snapshot, to: fileName)
            }
        }
        subject.send(snapshot)
    }
}
