import Combine
import DonkCore
import DonkUI
import UIKit

// MARK: - Main hop

enum PerformanceMain {
    static func run(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }
}

// MARK: - Monitor

final class PerformanceMonitor: @unchecked Sendable {
    static let shared = PerformanceMonitor()

    enum Update: Sendable {
        case sample(PerformanceSample)
        case events
        case reset
        case state
    }

    struct Snapshot {
        var samples: [PerformanceSample]
        var threads: [PerformanceThread]
        var events: [PerformanceEvent]
        var isRunning: Bool
        var gpuAvailability: GPUSampler.Availability
    }

    static let historyDuration: TimeInterval = 300
    static let eventCapacity = 200

    let preferences: PerformancePreferencesStore

    private let lock = DonkLock()
    private let queue = DispatchQueue(label: "io.github.donk.performance.sampler", qos: .utility)
    private let frames = FrameMonitor()
    private let watchdog = HangWatchdog()
    private let gpu = GPUSampler()
    private let engine = AlertEngine()
    private let subject = PassthroughSubject<Update, Never>()

    private var timer: DispatchSourceTimer?
    private var lastTargetFPS = 60
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    private var lastLowPower = false

    private var history = RingBuffer<PerformanceSample>(capacity: Int(historyDuration * 2) + 8)
    private var events = RingBuffer<PerformanceEvent>(capacity: eventCapacity)
    private var threads: [PerformanceThread] = []
    private var running = false
    private var alertsEnabledValue = true
    private var foreground = true
    private var gpuAvailabilityValue: GPUSampler.Availability = .unknown
    private var observers: [NSObjectProtocol] = []
    private var donkUI = DonkUIActivity()
    private var visibilityCancellable: AnyCancellable?
    private let isDebuggerVisible: @Sendable () -> Bool
    private let toastPresenter: @Sendable (PerformanceAlert) -> Void

    struct DonkUIActivity {
        static let margin: CFTimeInterval = 0.3

        var debuggerVisible = false
        var dashboards = 0
        var lastTransition: CFTimeInterval = -.infinity

        func overlaps(start: CFTimeInterval, end: CFTimeInterval, debuggerVisibleNow: Bool) -> Bool {
            if debuggerVisibleNow || debuggerVisible || dashboards > 0 {
                return true
            }
            return lastTransition >= start - Self.margin && lastTransition <= end + Self.margin
        }
    }

    init(
        preferences: PerformancePreferencesStore = .shared,
        debuggerVisibility: AnyPublisher<Bool, Never> = DonkEnvironment.debuggerVisibility,
        isDebuggerVisible: @escaping @Sendable () -> Bool = { DonkEnvironment.isDebuggerVisible },
        toastPresenter: @escaping @Sendable (PerformanceAlert) -> Void = { alert in
            DonkToast.show(alert.message, icon: alert.kind.icon, tone: alert.severity.tone, duration: 3)
        }
    ) {
        self.preferences = preferences
        self.isDebuggerVisible = isDebuggerVisible
        self.toastPresenter = toastPresenter
        visibilityCancellable = debuggerVisibility.sink { [weak self] visible in
            self?.debuggerVisibilityChanged(visible)
        }
    }

    // MARK: - donk UI

    func debuggerVisibilityChanged(_ visible: Bool, at time: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock {
            guard donkUI.debuggerVisible != visible else { return }
            donkUI.debuggerVisible = visible
            donkUI.lastTransition = time
        }
    }

    func donkScreenDidAppear(at time: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock {
            donkUI.dashboards += 1
            donkUI.lastTransition = time
        }
    }

    func donkScreenDidDisappear(at time: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock {
            donkUI.dashboards = max(0, donkUI.dashboards - 1)
            donkUI.lastTransition = time
        }
    }

    func isDonkUIInvolved(from start: CFTimeInterval, to end: CFTimeInterval) -> Bool {
        let visibleNow = isDebuggerVisible()
        return lock.withLock { donkUI.overlaps(start: start, end: end, debuggerVisibleNow: visibleNow) }
    }

    // MARK: - Public state

    var updates: AnyPublisher<Update, Never> {
        subject.eraseToAnyPublisher()
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var alertsEnabled: Bool {
        get { lock.withLock { alertsEnabledValue } }
        set {
            lock.withLock { alertsEnabledValue = newValue }
            queue.async { [subject] in subject.send(.state) }
        }
    }

    var latestSample: PerformanceSample? {
        lock.withLock { history.last }
    }

    var recentEvents: [PerformanceEvent] {
        lock.withLock { events.elements.reversed() }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                samples: history.elements,
                threads: threads,
                events: events.elements.reversed(),
                isRunning: running,
                gpuAvailability: gpuAvailabilityValue
            )
        }
    }

    // MARK: - Lifecycle

    func start(_ configuration: PerformanceConfiguration) {
        _ = CPUSampler.mainThreadPort
        let shouldStart: Bool = lock.withLock {
            alertsEnabledValue = configuration.alertsEnabled
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        let prefs = preferences.value
        queue.async { [self] in
            engine.settings = prefs.alerts
            engine.reset()
            gpu.reset()
            lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            lastThermal = ProcessInfo.processInfo.thermalState
            scheduleTimer(prefs.samplingRate)
            if lastThermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                recordThermal(lastThermal)
            }
            subject.send(.state)
        }
        installObservers()
        watchdog.start { [weak self] report in
            self?.queue.async { self?.recordHang(report) }
        }
        PerformanceMain.run { [self] in
            guard isRunning else { return }
            let isForeground = UIApplication.shared.applicationState != .background
            lock.withLock { foreground = isForeground }
            frames.start(prefersHighRefreshRate: prefs.prefersHighRefreshRate)
            frames.setPaused(!isForeground)
            watchdog.setPaused(!isForeground)
            HUDController.shared.monitorDidStart()
        }
    }

    func stop() {
        let wasRunning: Bool = lock.withLock {
            defer { running = false }
            return running
        }
        guard wasRunning else { return }
        removeObservers()
        watchdog.stop()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            subject.send(.state)
        }
        PerformanceMain.run { [self] in
            frames.stop()
            HUDController.shared.monitorDidStop()
        }
    }

    // MARK: - Controls

    func setSamplingRate(_ rate: PerformanceSamplingRate) {
        preferences.update { $0.samplingRate = rate }
        queue.async { [self] in
            guard isRunning else { return }
            scheduleTimer(rate)
            subject.send(.state)
        }
    }

    @MainActor
    func setPrefersHighRefreshRate(_ enabled: Bool) {
        preferences.update { $0.prefersHighRefreshRate = enabled }
        frames.setPrefersHighRefreshRate(enabled)
    }

    func updateAlertSettings(_ settings: PerformanceAlertSettings) {
        preferences.update { $0.alerts = settings }
        queue.async { [self] in
            engine.settings = settings
        }
    }

    func resetHistory() {
        lock.withLock {
            history.removeAll()
            events.removeAll()
            threads = []
        }
        queue.async { [self] in
            engine.reset()
            subject.send(.reset)
        }
    }

    // MARK: - Sampling

    private func scheduleTimer(_ rate: PerformanceSamplingRate) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = rate.interval
        timer.schedule(deadline: .now() + min(interval, 0.5), repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard isRunning else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let cpu = CPUSampler.sample()
        let memory = MemorySampler.sample()
        let gpuValue = gpu.sample(now: uptime)
        let window = frames.drain()
        if let window {
            lastTargetFPS = window.targetFPS
        }
        let processInfo = ProcessInfo.processInfo
        let isForeground = lock.withLock { foreground }
        let sample = PerformanceSample(
            date: Date(),
            uptime: uptime,
            cpu: cpu.total,
            mainThreadCPU: cpu.mainThread,
            threadCount: cpu.threadCount,
            footprint: memory.footprint,
            memoryLimit: memory.limit,
            gpuMillisecondsPerSecond: gpuValue,
            fps: isForeground ? window?.fps : nil,
            hitchRatio: isForeground ? window?.hitchRatio : nil,
            droppedFrames: window?.droppedFrames ?? 0,
            targetFPS: lastTargetFPS,
            maximumFPS: frames.maximumFPS,
            thermalState: processInfo.thermalState,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isForeground: isForeground
        )
        let availability = gpu.availability
        lock.withLock {
            history.append(sample)
            history.removeFirst { uptime - $0.uptime > Self.historyDuration }
            threads = cpu.threads
            gpuAvailabilityValue = availability
        }
        let alerts = engine.evaluate(sample)
        if !alerts.isEmpty {
            let now = CACurrentMediaTime()
            let interval = preferences.value.samplingRate.interval
            let duringDonkUI = isDonkUIInvolved(from: now - interval, to: now)
            alerts.forEach { deliver($0, logsEvent: true, duringDonkUI: duringDonkUI) }
        }
        subject.send(.sample(sample))
    }

    // MARK: - Events

    private func appendEvent(_ event: PerformanceEvent) {
        lock.withLock { events.append(event) }
    }

    private func deliver(_ alert: PerformanceAlert, logsEvent: Bool, duringDonkUI: Bool = false) {
        guard alertsEnabled else { return }
        if logsEvent {
            appendEvent(
                PerformanceEvent(
                    kind: .alert(alert.kind),
                    severity: alert.severity,
                    title: alert.message + (duringDonkUI ? PerformanceEvent.donkUITag : ""),
                    detail: alert.kind.title,
                    isDuringDonkUI: duringDonkUI
                )
            )
            subject.send(.events)
        }
        guard !duringDonkUI else { return }
        toastPresenter(alert)
    }

    func recordHang(_ report: HangReport) {
        let stack = report.addresses.isEmpty ? [] : Symbolicator.symbolicate(report.addresses)
        let backtrace = stack.isEmpty ? nil : PerformanceBacktrace(
            threadName: "com.apple.main-thread",
            capturedAfter: report.capturedAfter ?? 0,
            frames: stack
        )
        let severity: PerformanceSeverity = report.duration >= 2 ? .critical : .warning
        let started = report.endedAt.addingTimeInterval(-report.duration)
        let duringDonkUI = isDonkUIInvolved(from: report.startedUptime, to: report.endedUptime)
        appendEvent(
            PerformanceEvent(
                date: started,
                kind: .hang(duration: report.duration),
                severity: severity,
                title: "Main thread hung for \(PerformanceText.duration(report.duration))" + (duringDonkUI ? PerformanceEvent.donkUITag : ""),
                detail: duringDonkUI ? "Overlapped opening or using donk's own UI" : (severity == .critical ? "Severe hang" : "Hang"),
                backtrace: backtrace,
                isDuringDonkUI: duringDonkUI
            )
        )
        subject.send(.events)
        guard !duringDonkUI else { return }
        if let alert = engine.hang(duration: report.duration) {
            deliver(alert, logsEvent: false)
        }
    }

    private func recordMemoryWarning() {
        let footprint = MemorySampler.footprint()
        appendEvent(
            PerformanceEvent(
                kind: .memoryWarning,
                severity: .critical,
                title: "Memory warning",
                detail: "Footprint \(PerformanceText.megabytes(footprint))"
            )
        )
        subject.send(.events)
        if let alert = engine.memoryWarning() {
            deliver(alert, logsEvent: false)
        }
    }

    private func recordThermal(_ state: ProcessInfo.ThermalState) {
        let severity: PerformanceSeverity
        switch state {
        case .critical: severity = .critical
        case .serious: severity = .warning
        default: severity = .info
        }
        appendEvent(
            PerformanceEvent(
                kind: .thermal(state),
                severity: severity,
                title: "Thermal state: \(state.title.lowercased())",
                detail: nil
            )
        )
        subject.send(.events)
        if let alert = engine.thermalChanged(state) {
            deliver(alert, logsEvent: false)
        }
    }

    private func recordLowPower(_ enabled: Bool) {
        appendEvent(
            PerformanceEvent(
                kind: .lowPowerMode(enabled),
                severity: .info,
                title: enabled ? "Low Power Mode on" : "Low Power Mode off",
                detail: nil
            )
        )
        subject.send(.events)
    }

    // MARK: - Observers

    private func installObservers() {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.recordMemoryWarning() }
        })
        tokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                let state = ProcessInfo.processInfo.thermalState
                guard state != self.lastThermal else { return }
                self.lastThermal = state
                self.recordThermal(state)
            }
        })
        tokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard enabled != self.lastLowPower else { return }
                self.lastLowPower = enabled
                self.recordLowPower(enabled)
            }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(false)
        })
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setForeground(true)
        })
        lock.withLock { observers = tokens }
    }

    private func removeObservers() {
        let tokens: [NSObjectProtocol] = lock.withLock {
            defer { observers = [] }
            return observers
        }
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setForeground(_ isForeground: Bool) {
        lock.withLock { foreground = isForeground }
        watchdog.setPaused(!isForeground)
        PerformanceMain.run { [self] in
            guard isRunning else { return }
            frames.setPaused(!isForeground)
        }
    }
}

// MARK: - Tone

extension PerformanceSeverity {
    var tone: DonkTone {
        switch self {
        case .info: return .info
        case .warning: return .warning
        case .critical: return .error
        }
    }
}
