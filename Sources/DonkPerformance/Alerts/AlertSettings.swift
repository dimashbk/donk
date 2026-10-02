import Foundation

// MARK: - Kinds

public enum PerformanceAlertKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpu
    case memoryLimit
    case memoryGrowth
    case lowFPS
    case hitches
    case hang
    case thermal
    case memoryWarning

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: return "High CPU"
        case .memoryLimit: return "Memory near limit"
        case .memoryGrowth: return "Memory growth"
        case .lowFPS: return "Low frame rate"
        case .hitches: return "Hitches"
        case .hang: return "Main thread hang"
        case .thermal: return "Thermal state"
        case .memoryWarning: return "Memory warning"
        }
    }

    public var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memoryLimit: return "memorychip"
        case .memoryGrowth: return "chart.line.uptrend.xyaxis"
        case .lowFPS: return "gauge"
        case .hitches: return "waveform.path.ecg"
        case .hang: return "hourglass"
        case .thermal: return "thermometer"
        case .memoryWarning: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Rule

public struct PerformanceAlertRule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var threshold: Double
    public var duration: TimeInterval

    public init(isEnabled: Bool = true, threshold: Double, duration: TimeInterval = 0) {
        self.isEnabled = isEnabled
        self.threshold = threshold
        self.duration = duration
    }
}

// MARK: - Settings

public struct PerformanceAlertSettings: Codable, Equatable, Sendable {
    public var cpu = PerformanceAlertRule(threshold: 80, duration: 10)
    public var memoryLimit = PerformanceAlertRule(threshold: 80)
    public var memoryGrowth = PerformanceAlertRule(threshold: 50, duration: 180)
    public var lowFPS = PerformanceAlertRule(threshold: 45, duration: 5)
    public var hitches = PerformanceAlertRule(threshold: 10, duration: 5)
    public var hang = PerformanceAlertRule(threshold: 250)
    public var thermal = PerformanceAlertRule(threshold: Double(ProcessInfo.ThermalState.serious.rawValue))
    public var memoryWarning = PerformanceAlertRule(threshold: 0)
    public var cooldown: TimeInterval = 30

    public static let `default` = PerformanceAlertSettings()

    public init() {}

    public subscript(kind: PerformanceAlertKind) -> PerformanceAlertRule {
        get {
            switch kind {
            case .cpu: return cpu
            case .memoryLimit: return memoryLimit
            case .memoryGrowth: return memoryGrowth
            case .lowFPS: return lowFPS
            case .hitches: return hitches
            case .hang: return hang
            case .thermal: return thermal
            case .memoryWarning: return memoryWarning
            }
        }
        set {
            switch kind {
            case .cpu: cpu = newValue
            case .memoryLimit: memoryLimit = newValue
            case .memoryGrowth: memoryGrowth = newValue
            case .lowFPS: lowFPS = newValue
            case .hitches: hitches = newValue
            case .hang: hang = newValue
            case .thermal: thermal = newValue
            case .memoryWarning: memoryWarning = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cpu, memoryLimit, memoryGrowth, lowFPS, hitches, hang, thermal, memoryWarning, cooldown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PerformanceAlertSettings()
        cpu = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .cpu)) ?? defaults.cpu
        memoryLimit = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .memoryLimit)) ?? defaults.memoryLimit
        memoryGrowth = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .memoryGrowth)) ?? defaults.memoryGrowth
        lowFPS = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .lowFPS)) ?? defaults.lowFPS
        hitches = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .hitches)) ?? defaults.hitches
        hang = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .hang)) ?? defaults.hang
        thermal = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .thermal)) ?? defaults.thermal
        memoryWarning = (try? container.decodeIfPresent(PerformanceAlertRule.self, forKey: .memoryWarning)) ?? defaults.memoryWarning
        cooldown = (try? container.decodeIfPresent(TimeInterval.self, forKey: .cooldown)) ?? defaults.cooldown
    }
}

// MARK: - Alert

public struct PerformanceAlert: Sendable, Equatable {
    public var kind: PerformanceAlertKind
    public var severity: PerformanceSeverity
    public var message: String
    public var uptime: TimeInterval

    public init(kind: PerformanceAlertKind, severity: PerformanceSeverity, message: String, uptime: TimeInterval) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.uptime = uptime
    }
}
