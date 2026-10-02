import Foundation

// MARK: - Sustained window

struct SustainedWindow {
    private(set) var start: TimeInterval?
    private var sum: Double = 0
    private var count = 0

    mutating func update(isAbnormal: Bool, value: Double, now: TimeInterval) -> (duration: TimeInterval, average: Double)? {
        guard isAbnormal else {
            reset()
            return nil
        }
        if start == nil {
            start = now
            sum = 0
            count = 0
        }
        sum += value
        count += 1
        return (now - (start ?? now), sum / Double(max(1, count)))
    }

    mutating func reset() {
        start = nil
        sum = 0
        count = 0
    }
}

// MARK: - Growth tracker

struct GrowthTracker {
    private var points: [(time: TimeInterval, value: UInt64)] = []
    private var runMax: UInt64 = 0

    mutating func update(value: UInt64, now: TimeInterval, window: TimeInterval, dropTolerance: UInt64) -> (growth: UInt64, span: TimeInterval)? {
        if !points.isEmpty, value &+ dropTolerance < runMax {
            restart(value: value, now: now)
            return nil
        }
        points.append((now, value))
        runMax = max(runMax, value)
        while let first = points.first, now - first.time > window {
            points.removeFirst()
        }
        guard let first = points.first, value > first.value else { return nil }
        return (value - first.value, now - first.time)
    }

    mutating func restart(value: UInt64, now: TimeInterval) {
        points = [(now, value)]
        runMax = value
    }

    mutating func reset() {
        points = []
        runMax = 0
    }
}

// MARK: - Engine

final class AlertEngine {
    var settings: PerformanceAlertSettings
    var maximumSampleGap: TimeInterval = 5
    var memoryDropTolerance: UInt64 = 4 * 1_048_576

    private let clock: () -> TimeInterval
    private var cpuWindow = SustainedWindow()
    private var fpsWindow = SustainedWindow()
    private var hitchWindow = SustainedWindow()
    private var growth = GrowthTracker()
    private var lastFired: [PerformanceAlertKind: TimeInterval] = [:]
    private var lastSampleTime: TimeInterval?

    init(settings: PerformanceAlertSettings = .default, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings
        self.clock = clock
    }

    func reset() {
        cpuWindow.reset()
        fpsWindow.reset()
        hitchWindow.reset()
        growth.reset()
        lastFired.removeAll()
        lastSampleTime = nil
    }

    func evaluate(_ sample: PerformanceSample) -> [PerformanceAlert] {
        let now = clock()
        if let lastSampleTime, now - lastSampleTime > maximumSampleGap {
            cpuWindow.reset()
            fpsWindow.reset()
            hitchWindow.reset()
            growth.reset()
        }
        lastSampleTime = now
        var alerts: [PerformanceAlert] = []
        if let alert = evaluateCPU(sample, now: now) { alerts.append(alert) }
        if let alert = evaluateMemoryLimit(sample, now: now) { alerts.append(alert) }
        if let alert = evaluateMemoryGrowth(sample, now: now) { alerts.append(alert) }
        if let alert = evaluateFPS(sample, now: now) { alerts.append(alert) }
        if let alert = evaluateHitches(sample, now: now) { alerts.append(alert) }
        return alerts
    }

    func hang(duration: TimeInterval) -> PerformanceAlert? {
        let rule = settings.hang
        guard rule.isEnabled, duration * 1000 >= rule.threshold else { return nil }
        let severity: PerformanceSeverity = duration >= 2 ? .critical : .warning
        return fire(.hang, severity: severity, message: "Main thread hung for \(PerformanceText.duration(duration))", now: clock())
    }

    func thermalChanged(_ state: ProcessInfo.ThermalState) -> PerformanceAlert? {
        let rule = settings.thermal
        let minimum = max(Int(rule.threshold.rounded()), ProcessInfo.ThermalState.serious.rawValue)
        guard rule.isEnabled, state.rawValue >= minimum else { return nil }
        let severity: PerformanceSeverity = state == .critical ? .critical : .warning
        return fire(.thermal, severity: severity, message: "Thermal state: \(state.title.lowercased())", now: clock())
    }

    func memoryWarning() -> PerformanceAlert? {
        guard settings.memoryWarning.isEnabled else { return nil }
        return fire(.memoryWarning, severity: .critical, message: "Memory warning received", now: clock())
    }

    // MARK: - Rules

    private func evaluateCPU(_ sample: PerformanceSample, now: TimeInterval) -> PerformanceAlert? {
        let rule = settings.cpu
        guard rule.isEnabled, sample.isForeground else {
            cpuWindow.reset()
            return nil
        }
        guard let window = cpuWindow.update(isAbnormal: sample.cpu > rule.threshold, value: sample.cpu, now: now),
              window.duration >= rule.duration - 0.001 else { return nil }
        let severity: PerformanceSeverity = window.average >= rule.threshold * 2 ? .critical : .warning
        let message = "CPU \(PerformanceText.percent(window.average)) for \(PerformanceText.duration(window.duration))"
        return fire(.cpu, severity: severity, message: message, now: now)
    }

    private func evaluateMemoryLimit(_ sample: PerformanceSample, now: TimeInterval) -> PerformanceAlert? {
        let rule = settings.memoryLimit
        guard rule.isEnabled, let fraction = sample.memoryUsageFraction, let limit = sample.memoryLimit else { return nil }
        let percent = fraction * 100
        guard percent > rule.threshold else { return nil }
        let severity: PerformanceSeverity = percent >= 95 ? .critical : .warning
        let message = "Memory at \(PerformanceText.percent(percent)) of limit (\(PerformanceText.megabytes(sample.footprint)) of \(PerformanceText.megabytes(limit)))"
        return fire(.memoryLimit, severity: severity, message: message, now: now)
    }

    private func evaluateMemoryGrowth(_ sample: PerformanceSample, now: TimeInterval) -> PerformanceAlert? {
        let rule = settings.memoryGrowth
        guard rule.isEnabled, sample.footprint > 0 else {
            growth.reset()
            return nil
        }
        let window = rule.duration > 0 ? rule.duration : 180
        guard let result = growth.update(value: sample.footprint, now: now, window: window, dropTolerance: memoryDropTolerance) else { return nil }
        let thresholdBytes = UInt64(max(0, rule.threshold) * 1_048_576)
        guard result.growth > thresholdBytes else { return nil }
        let message = "Memory grew \(PerformanceText.megabytes(result.growth)) in \(PerformanceText.duration(result.span))"
        let alert = fire(.memoryGrowth, severity: .warning, message: message, now: now)
        if alert != nil {
            growth.restart(value: sample.footprint, now: now)
        }
        return alert
    }

    private func evaluateFPS(_ sample: PerformanceSample, now: TimeInterval) -> PerformanceAlert? {
        let rule = settings.lowFPS
        guard rule.isEnabled, sample.isForeground, let fps = sample.fps else {
            fpsWindow.reset()
            return nil
        }
        guard let window = fpsWindow.update(isAbnormal: fps < rule.threshold, value: fps, now: now),
              window.duration >= rule.duration - 0.001 else { return nil }
        let severity: PerformanceSeverity = window.average < rule.threshold * 2 / 3 ? .critical : .warning
        let message = "FPS \(Int(window.average.rounded())) for \(PerformanceText.duration(window.duration))"
        return fire(.lowFPS, severity: severity, message: message, now: now)
    }

    private func evaluateHitches(_ sample: PerformanceSample, now: TimeInterval) -> PerformanceAlert? {
        let rule = settings.hitches
        guard rule.isEnabled, sample.isForeground, let ratio = sample.hitchRatio else {
            hitchWindow.reset()
            return nil
        }
        guard let window = hitchWindow.update(isAbnormal: ratio > rule.threshold, value: ratio, now: now),
              window.duration >= rule.duration - 0.001 else { return nil }
        let severity: PerformanceSeverity = window.average >= 10 ? .critical : .warning
        let message = "Hitches \(PerformanceText.number(window.average)) ms/s for \(PerformanceText.duration(window.duration))"
        return fire(.hitches, severity: severity, message: message, now: now)
    }

    // MARK: - Cooldown

    private func fire(_ kind: PerformanceAlertKind, severity: PerformanceSeverity, message: String, now: TimeInterval) -> PerformanceAlert? {
        if let last = lastFired[kind], now - last < settings.cooldown {
            return nil
        }
        lastFired[kind] = now
        return PerformanceAlert(kind: kind, severity: severity, message: message, uptime: now)
    }
}
