import Combine
import Darwin
import QuartzCore
import XCTest
@testable import DonkPerformance

private typealias ForkFunction = @convention(c) () -> pid_t

private let forkFunction: ForkFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else { return nil }
    return unsafeBitCast(symbol, to: ForkFunction.self)
}()

final class HangFilterTests: XCTestCase {
    func testWholeProcessStopIsDiscarded() {
        XCTAssertTrue(HangFilter.isWholeProcessStop(measured: 0.65, watchdogStall: 0.6, threshold: 0.25, tolerance: 0.1, isTraced: false))
        XCTAssertTrue(HangFilter.isWholeProcessStop(measured: 0.9, watchdogStall: 0.6, threshold: 0.25, tolerance: 0.1, isTraced: false))
        XCTAssertTrue(HangFilter.isWholeProcessStop(measured: 30, watchdogStall: 29.9, threshold: 0.25, tolerance: 0.1, isTraced: false))
        XCTAssertFalse(HangFilter.isWholeProcessStop(measured: 0.3, watchdogStall: 0, threshold: 0.25, tolerance: 0.1, isTraced: false))
        XCTAssertFalse(HangFilter.isWholeProcessStop(measured: 0.6, watchdogStall: 0, threshold: 0.25, tolerance: 0.1, isTraced: true))
        XCTAssertFalse(HangFilter.isWholeProcessStop(measured: 1.6, watchdogStall: 0.6, threshold: 0.25, tolerance: 0.1, isTraced: false))
        XCTAssertEqual(HangFilter.effectiveDuration(measured: 1.6, watchdogStall: 0.6), 1.0, accuracy: 0.0001)
        XCTAssertEqual(HangFilter.effectiveDuration(measured: 0.2, watchdogStall: 0.6), 0)
    }

    func testDebuggerStopsAreDiscardedWhenTraced() {
        XCTAssertTrue(HangFilter.isWholeProcessStop(measured: 1.6, watchdogStall: 0.6, threshold: 0.25, tolerance: 0.1, isTraced: true))
        XCTAssertFalse(HangFilter.isWholeProcessStop(measured: 1.6, watchdogStall: 0.1, threshold: 0.25, tolerance: 0.1, isTraced: true))
    }

    func testProcessTracingQueryAnswers() {
        _ = ProcessTracing.isTraced()
    }

    func testStoppedProcessIsNotReportedAsAHang() throws {
        let fork = try XCTUnwrap(forkFunction)
        let queue = DispatchQueue(label: "donk.test.stopped")
        var configuration = HangWatchdog.Configuration()
        configuration.captureThreshold = .infinity
        let watchdog = HangWatchdog(queue: queue, configuration: configuration)
        let reports = ReportList()
        watchdog.start { reports.append($0) }
        Thread.sleep(forTimeInterval: 0.3)

        queue.async {
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < 0.15 {}
        }
        usleep(80_000)
        let parent = getpid()
        let child = fork()
        if child == 0 {
            usleep(700_000)
            kill(parent, SIGCONT)
            _exit(0)
        }
        XCTAssertGreaterThan(child, 0)
        let stoppedAt = CACurrentMediaTime()
        kill(parent, SIGSTOP)
        let stoppedFor = CACurrentMediaTime() - stoppedAt
        var status: Int32 = 0
        waitpid(child, &status, 0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(stoppedFor, 0.5, "the process should have been stopped")
        XCTAssertTrue(reports.values.isEmpty, "a whole-process stop is not a main-thread hang: \(reports.values.map(\.duration))")

        queue.async {
            Thread.sleep(forTimeInterval: 0.6)
        }
        Thread.sleep(forTimeInterval: 1.2)
        watchdog.stop()
        XCTAssertEqual(reports.values.count, 1, "a real hang after the stop is still reported")
        XCTAssertGreaterThanOrEqual(reports.values.first?.duration ?? 0, 0.45)
        XCTAssertGreaterThan(reports.values.first?.endedUptime ?? 0, reports.values.first?.startedUptime ?? 0)
    }
}

final class DonkUIActivityTests: XCTestCase {
    private func makeMonitor(visibility: PassthroughSubject<Bool, Never>, visible: VisibleFlag, toasts: ToastLog) -> PerformanceMonitor {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("donk-perf-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PerformanceMonitor(
            preferences: PerformancePreferencesStore(directory: directory),
            debuggerVisibility: visibility.eraseToAnyPublisher(),
            isDebuggerVisible: { visible.value },
            toastPresenter: { toasts.append($0.message) }
        )
    }

    private func hang(from start: CFTimeInterval, duration: TimeInterval) -> HangReport {
        HangReport(duration: duration, endedAt: Date(), addresses: [], capturedAfter: nil, startedUptime: start, endedUptime: start + duration)
    }

    func testHangDuringDebuggerTransitionIsTaggedWithoutAToast() {
        let visibility = PassthroughSubject<Bool, Never>()
        let visible = VisibleFlag()
        let toasts = ToastLog()
        let monitor = makeMonitor(visibility: visibility, visible: visible, toasts: toasts)
        let now = CACurrentMediaTime()

        monitor.debuggerVisibilityChanged(true, at: now)
        monitor.debuggerVisibilityChanged(false, at: now + 0.1)
        monitor.recordHang(hang(from: now - 0.05, duration: 0.346))

        let event = monitor.recentEvents.first
        XCTAssertEqual(event?.isDuringDonkUI, true)
        XCTAssertTrue(event?.title.hasSuffix(PerformanceEvent.donkUITag) ?? false, event?.title ?? "")
        XCTAssertTrue(toasts.values.isEmpty)
    }

    func testHangWhileDebuggerIsVisibleIsTagged() {
        let visibility = PassthroughSubject<Bool, Never>()
        let visible = VisibleFlag()
        visible.value = true
        let toasts = ToastLog()
        let monitor = makeMonitor(visibility: visibility, visible: visible, toasts: toasts)
        let now = CACurrentMediaTime()
        monitor.recordHang(hang(from: now + 10, duration: 0.5))
        XCTAssertEqual(monitor.recentEvents.first?.isDuringDonkUI, true)
        XCTAssertTrue(toasts.values.isEmpty)
    }

    func testHangWhileADonkScreenIsOnScreenIsTagged() {
        let monitor = makeMonitor(visibility: PassthroughSubject(), visible: VisibleFlag(), toasts: ToastLog())
        let now = CACurrentMediaTime()
        monitor.donkScreenDidAppear(at: now - 30)
        XCTAssertTrue(monitor.isDonkUIInvolved(from: now, to: now + 1))
        monitor.donkScreenDidDisappear(at: now - 20)
        XCTAssertFalse(monitor.isDonkUIInvolved(from: now, to: now + 1))
        XCTAssertTrue(monitor.isDonkUIInvolved(from: now - 20.1, to: now - 19.8))
    }

    func testUnrelatedHangStillAlerts() {
        let visibility = PassthroughSubject<Bool, Never>()
        let toasts = ToastLog()
        let monitor = makeMonitor(visibility: visibility, visible: VisibleFlag(), toasts: toasts)
        let now = CACurrentMediaTime()
        visibility.send(true)
        visibility.send(false)
        monitor.recordHang(hang(from: now + 5, duration: 0.8))

        let event = monitor.recentEvents.first
        XCTAssertEqual(event?.isDuringDonkUI, false)
        XCTAssertEqual(event?.title, "Main thread hung for 800 ms")
        XCTAssertEqual(toasts.values.count, 1)
    }
}

final class DashboardSeriesTests: XCTestCase {
    func testSeriesFollowsTheChartWindow() {
        var samples: [PerformanceSample] = []
        for index in 0..<10 {
            let value = Double(index)
            let gpu: Double? = index.isMultiple(of: 2) ? value : nil
            let fps: Double? = index == 9 ? nil : 50
            samples.append(
                PerformanceSample(
                    uptime: value * 10,
                    cpu: value,
                    mainThreadCPU: value / 2,
                    footprint: UInt64(index) * 1_048_576,
                    gpuMillisecondsPerSecond: gpu,
                    fps: fps,
                    hitchRatio: 3,
                    droppedFrames: 2,
                    maximumFPS: 120,
                    isForeground: index != 8
                )
            )
        }
        let series = DashboardSeries(samples: samples, window: 35)
        XCTAssertEqual(series.cpu, [6, 7, 8, 9])
        XCTAssertEqual(series.mainThread, [3, 3.5, 4, 4.5])
        XCTAssertEqual(series.memory, [6, 7, 8, 9])
        XCTAssertEqual(series.gpu, [6, 8])
        XCTAssertEqual(series.fps, [50, 50])
        XCTAssertEqual(series.maximumFPS, [120, 120])
        XCTAssertEqual(series.hitch, [3, 3])
        XCTAssertEqual(series.droppedFrames, 4)
        XCTAssertEqual(DashboardSeries(samples: [], window: 60), DashboardSeries())
    }

    func testHUDKeyboardPreferenceDefaultsToOff() throws {
        XCTAssertFalse(PerformancePreferences().hudStaysAboveKeyboard)
        let legacy = Data(#"{"isHUDVisible":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PerformancePreferences.self, from: legacy)
        XCTAssertFalse(decoded.hudStaysAboveKeyboard)
        XCTAssertTrue(decoded.isHUDVisible)
    }
}

final class VisibleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }
}

final class ToastLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }
}
