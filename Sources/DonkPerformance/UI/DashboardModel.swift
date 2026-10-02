import Combine
import DonkUI
import SwiftUI

enum ChartWindow: String, CaseIterable, Hashable {
    case oneMinute = "1 min"
    case fiveMinutes = "5 min"

    var duration: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }
}

struct DashboardSeries: Equatable, Sendable {
    var cpu: [Double] = []
    var mainThread: [Double] = []
    var memory: [Double] = []
    var fps: [Double] = []
    var maximumFPS: [Double] = []
    var hitch: [Double] = []
    var gpu: [Double] = []
    var droppedFrames = 0

    init() {}

    init(samples: [PerformanceSample], window: TimeInterval) {
        guard let last = samples.last else { return }
        let cutoff = last.uptime - window
        let maximum = Double(last.maximumFPS)
        for sample in samples where sample.uptime > cutoff {
            cpu.append(sample.cpu)
            mainThread.append(sample.mainThreadCPU)
            memory.append(Double(sample.footprint) / 1_048_576)
            if let value = sample.gpuMillisecondsPerSecond {
                gpu.append(value)
            }
            if sample.isForeground, let value = sample.fps {
                fps.append(value)
                maximumFPS.append(maximum)
                if let ratio = sample.hitchRatio {
                    hitch.append(ratio)
                }
                droppedFrames += sample.droppedFrames
            }
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var snapshot: PerformanceMonitor.Snapshot
    @Published private(set) var series = DashboardSeries()
    @Published private(set) var preferences: PerformancePreferences
    @Published private(set) var alertsEnabled: Bool
    @Published private(set) var chartsReady = false
    @Published var chartWindow: ChartWindow = .oneMinute {
        didSet {
            if chartWindow != oldValue {
                scheduleRefresh()
            }
        }
    }

    static let chartRevealDelay: TimeInterval = 0.35

    let monitor: PerformanceMonitor
    private let work = DispatchQueue(label: "io.github.donk.performance.dashboard", qos: .userInitiated)
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    init(monitor: PerformanceMonitor = .shared) {
        self.monitor = monitor
        snapshot = monitor.snapshot()
        preferences = monitor.preferences.value
        alertsEnabled = monitor.alertsEnabled
        monitor.updates
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &cancellables)
        monitor.preferences.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.preferences = value
            }
            .store(in: &cancellables)
        scheduleRefresh()
    }

    func refresh() {
        scheduleRefresh()
    }

    func scheduleRefresh() {
        generation &+= 1
        let token = generation
        let window = chartWindow.duration
        let monitor = monitor
        work.async { [weak self] in
            let snapshot = monitor.snapshot()
            let series = DashboardSeries(samples: snapshot.samples, window: window)
            let alertsEnabled = monitor.alertsEnabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(token: token, snapshot: snapshot, series: series, alertsEnabled: alertsEnabled)
                }
            }
        }
    }

    private func apply(token: Int, snapshot: PerformanceMonitor.Snapshot, series: DashboardSeries, alertsEnabled: Bool) {
        guard token == generation else { return }
        self.snapshot = snapshot
        if self.series != series {
            self.series = series
        }
        if self.alertsEnabled != alertsEnabled {
            self.alertsEnabled = alertsEnabled
        }
    }

    func screenDidAppear() {
        monitor.donkScreenDidAppear()
        guard !chartsReady else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chartRevealDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.chartsReady else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.chartsReady = true
                }
            }
        }
    }

    func screenDidDisappear() {
        monitor.donkScreenDidDisappear()
    }

    // MARK: - Derived

    var latest: PerformanceSample? {
        snapshot.samples.last
    }

    var isRunning: Bool {
        snapshot.isRunning
    }

    var rate: PerformanceSamplingRate {
        preferences.samplingRate
    }

    var capacity: Int {
        max(2, Int(chartWindow.duration * rate.rawValue))
    }

    var cpuValues: [Double] {
        series.cpu
    }

    var mainThreadValues: [Double] {
        series.mainThread
    }

    var memoryValues: [Double] {
        series.memory
    }

    var fpsValues: [Double] {
        series.fps
    }

    var maximumFPSValues: [Double] {
        series.maximumFPS
    }

    var hitchValues: [Double] {
        series.hitch
    }

    var gpuValues: [Double] {
        series.gpu
    }

    var maximumFPS: Int {
        latest?.maximumFPS ?? 60
    }

    var droppedFramesInWindow: Int {
        series.droppedFrames
    }

    var cpuRange: ClosedRange<Double> {
        let peak = max(series.cpu.max() ?? 0, preferences.alerts.cpu.isEnabled ? preferences.alerts.cpu.threshold : 0) * 1.05
        let steps: [Double] = [100, 200, 400, 800, 1200, 1600, 2000, 2400, 3200, 4000]
        let upper = steps.first { $0 >= peak } ?? (peak / 400).rounded(.up) * 400
        return 0...upper
    }

    var fpsRange: ClosedRange<Double> {
        let peak = max(Double(maximumFPS), series.fps.max() ?? 0) * 1.1
        return 0...max(40, (peak / 40).rounded(.up) * 40)
    }

    var hitchRange: ClosedRange<Double> {
        let peak = max(15, (series.hitch.max() ?? 0) * 1.1)
        return 0...peak
    }

    // MARK: - Actions

    func setHUDVisible(_ visible: Bool) {
        DonkPerformance.isHUDVisible = visible
        DonkHaptics.light()
    }

    func setHUDStaysAboveKeyboard(_ enabled: Bool) {
        DonkPerformance.hudStaysAboveKeyboard = enabled
        DonkHaptics.light()
    }

    func setRate(_ rate: PerformanceSamplingRate) {
        monitor.setSamplingRate(rate)
    }

    func setPrefersHighRefreshRate(_ enabled: Bool) {
        monitor.setPrefersHighRefreshRate(enabled)
        DonkHaptics.light()
    }

    func resetHistory() {
        monitor.resetHistory()
        DonkHaptics.success()
        DonkToast.show("History cleared", icon: "trash", tone: .neutral)
    }

    func startMonitoring() {
        DonkPerformance.start(PerformanceConfiguration())
        DonkHaptics.success()
    }

    var reportText: String {
        PerformanceReport.text(snapshot: snapshot)
    }
}

// MARK: - Report

enum PerformanceReport {
    static func text(snapshot: PerformanceMonitor.Snapshot) -> String {
        var lines: [String] = ["donk performance report", "Generated \(DonkFormat.dateTime(Date()))", ""]
        if let sample = snapshot.samples.last {
            lines.append("CPU: \(PerformanceText.percent(sample.cpu)) (main \(PerformanceText.percent(sample.mainThreadCPU))), \(sample.threadCount) threads, \(CPUSampler.processorCount) cores")
            var memory = "Memory: \(PerformanceText.megabytes(sample.footprint)) footprint"
            if let limit = sample.memoryLimit {
                memory += " of \(PerformanceText.megabytes(limit)) estimated limit"
            }
            lines.append(memory)
            if let fps = sample.fps {
                lines.append("FPS: \(Int(fps.rounded())) (target \(sample.targetFPS), max \(sample.maximumFPS)), hitches \(PerformanceText.number(sample.hitchRatio ?? 0)) ms/s")
            }
            if let gpu = sample.gpuMillisecondsPerSecond {
                lines.append("GPU: \(PerformanceText.number(gpu)) ms/s")
            }
            lines.append("Thermal: \(sample.thermalState.title), Low Power Mode: \(sample.isLowPowerModeEnabled ? "on" : "off")")
        } else {
            lines.append("No samples recorded.")
        }
        let samples = snapshot.samples
        if !samples.isEmpty {
            let cpuPeak = samples.map(\.cpu).max() ?? 0
            let memoryPeak = samples.map(\.footprint).max() ?? 0
            let fps = samples.compactMap(\.fps)
            lines.append("")
            lines.append("Last \(PerformanceText.duration((samples.last?.uptime ?? 0) - (samples.first?.uptime ?? 0))):")
            lines.append("  CPU peak \(PerformanceText.percent(cpuPeak))")
            lines.append("  Memory peak \(PerformanceText.megabytes(memoryPeak))")
            if let low = fps.min() {
                lines.append("  FPS low \(Int(low.rounded()))")
            }
        }
        if !snapshot.events.isEmpty {
            lines.append("")
            lines.append("Events:")
            for event in snapshot.events.prefix(50) {
                lines.append("  \(DonkFormat.time(event.date))  \(event.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
