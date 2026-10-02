import Foundation

// MARK: - Severity

public enum PerformanceSeverity: Int, Codable, Sendable, Comparable, CaseIterable {
    case info
    case warning
    case critical

    public static func < (lhs: PerformanceSeverity, rhs: PerformanceSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Sample

public struct PerformanceSample: Sendable, Equatable {
    public var date: Date
    public var uptime: TimeInterval
    public var cpu: Double
    public var mainThreadCPU: Double
    public var threadCount: Int
    public var footprint: UInt64
    public var memoryLimit: UInt64?
    public var gpuMillisecondsPerSecond: Double?
    public var fps: Double?
    public var hitchRatio: Double?
    public var droppedFrames: Int
    public var targetFPS: Int
    public var maximumFPS: Int
    public var thermalState: ProcessInfo.ThermalState
    public var isLowPowerModeEnabled: Bool
    public var isForeground: Bool

    public init(
        date: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        cpu: Double = 0,
        mainThreadCPU: Double = 0,
        threadCount: Int = 0,
        footprint: UInt64 = 0,
        memoryLimit: UInt64? = nil,
        gpuMillisecondsPerSecond: Double? = nil,
        fps: Double? = nil,
        hitchRatio: Double? = nil,
        droppedFrames: Int = 0,
        targetFPS: Int = 60,
        maximumFPS: Int = 60,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isLowPowerModeEnabled: Bool = false,
        isForeground: Bool = true
    ) {
        self.date = date
        self.uptime = uptime
        self.cpu = cpu
        self.mainThreadCPU = mainThreadCPU
        self.threadCount = threadCount
        self.footprint = footprint
        self.memoryLimit = memoryLimit
        self.gpuMillisecondsPerSecond = gpuMillisecondsPerSecond
        self.fps = fps
        self.hitchRatio = hitchRatio
        self.droppedFrames = droppedFrames
        self.targetFPS = targetFPS
        self.maximumFPS = maximumFPS
        self.thermalState = thermalState
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isForeground = isForeground
    }

    public var memoryUsageFraction: Double? {
        guard let memoryLimit, memoryLimit > 0 else { return nil }
        return Double(footprint) / Double(memoryLimit)
    }
}

// MARK: - Threads

public struct PerformanceThread: Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var name: String
    public var isMain: Bool
    public var cpu: Double
    public var runState: Int32

    public var displayName: String {
        if isMain { return name.isEmpty ? "Main Thread" : name }
        return name.isEmpty ? String(format: "Thread 0x%x", id) : name
    }
}

// MARK: - Backtrace

public struct PerformanceStackFrame: Sendable, Equatable, Identifiable {
    public var index: Int
    public var address: UInt
    public var image: String?
    public var symbol: String?
    public var offset: UInt

    public var id: Int { index }

    public var line: String {
        let indexText = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
        let imageText = (image ?? "???").padding(toLength: max(24, (image ?? "???").count + 1), withPad: " ", startingAt: 0)
        let addressText = String(format: "0x%016lx", address)
        let symbolText = symbol.map { "\($0) + \(offset)" } ?? "+ \(offset)"
        return "\(indexText)\(imageText)\(addressText) \(symbolText)"
    }

    public var compactLine: String {
        let header = "\(index)  \(image ?? "???")  " + String(format: "0x%lx", address)
        let detail = symbol.map { "\($0) + \(offset)" } ?? "+ \(offset)"
        return header + "\n    " + detail
    }
}

public struct PerformanceBacktrace: Sendable, Equatable {
    public var threadName: String
    public var capturedAfter: TimeInterval
    public var frames: [PerformanceStackFrame]

    public var text: String {
        var lines = ["Thread 0 name: \(threadName)", "Captured \(PerformanceText.duration(capturedAfter)) into the hang", ""]
        lines.append(contentsOf: frames.map(\.line))
        return lines.joined(separator: "\n")
    }

    public var compactText: String {
        frames.map(\.compactLine).joined(separator: "\n")
    }
}

// MARK: - Events

public struct PerformanceEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case hang(duration: TimeInterval)
        case memoryWarning
        case thermal(ProcessInfo.ThermalState)
        case lowPowerMode(Bool)
        case alert(PerformanceAlertKind)
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var severity: PerformanceSeverity
    public var title: String
    public var detail: String?
    public var backtrace: PerformanceBacktrace?
    public var isDuringDonkUI: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        severity: PerformanceSeverity,
        title: String,
        detail: String? = nil,
        backtrace: PerformanceBacktrace? = nil,
        isDuringDonkUI: Bool = false
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.backtrace = backtrace
        self.isDuringDonkUI = isDuringDonkUI
    }

    static let donkUITag = " (donk UI open)"

    public var isHang: Bool {
        if case .hang = kind { return true }
        return false
    }
}

// MARK: - Thermal

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Text

enum PerformanceText {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let value = max(0, seconds)
        if value < 1 { return "\(Int((value * 1000).rounded())) ms" }
        if value < 10 {
            let tenths = (value * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths)) s" : String(format: "%.1f s", tenths)
        }
        if value < 60 { return "\(Int(value.rounded())) s" }
        let total = Int(value.rounded())
        if total < 3600 { return "\(total / 60)m " + String(format: "%02ds", total % 60) }
        return "\(total / 3600)h " + String(format: "%02dm", (total % 3600) / 60)
    }

    static func megabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_048_576
        if value >= 1024 { return String(format: "%.2f GB", value / 1024) }
        if value >= 100 { return "\(Int(value.rounded())) MB" }
        return String(format: "%.1f MB", value)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
