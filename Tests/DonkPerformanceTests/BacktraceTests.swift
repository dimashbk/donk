import Darwin
import XCTest
@testable import DonkPerformance

public final class BacktraceParking: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var port: thread_t = 0

    public init() {}

    public var threadPort: thread_t {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    public func start() {
        let thread = Thread { [self] in
            self.parkForBacktrace()
        }
        thread.name = "donk.test.parked"
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        Thread.sleep(forTimeInterval: 0.15)
    }

    public func finish() {
        release.signal()
    }

    @inline(never)
    public func parkForBacktrace() {
        lock.lock()
        port = pthread_mach_thread_np(pthread_self())
        lock.unlock()
        ready.signal()
        release.wait()
    }
}

final class BacktraceTests: XCTestCase {
    func testCapturesSymbolicatedStackOfBlockedThread() {
        let parking = BacktraceParking()
        parking.start()
        defer { parking.finish() }
        let port = parking.threadPort
        XCTAssertNotEqual(port, 0)

        let addresses = BacktraceCapture.capture(thread: port)
        XCTAssertGreaterThanOrEqual(addresses.count, 3, "expected a multi-frame stack")
        XCTAssertTrue(addresses.allSatisfy { $0 != 0 })

        let frames = Symbolicator.symbolicate(addresses)
        XCTAssertEqual(frames.count, addresses.count)
        let symbolicated = frames.filter { $0.symbol != nil && $0.image != nil }
        XCTAssertGreaterThanOrEqual(symbolicated.count, 2, frames.map(\.line).joined(separator: "\n"))
        let symbols = frames.compactMap(\.symbol).joined(separator: "\n")
        XCTAssertTrue(
            symbols.contains("semaphore") || symbols.contains("dispatch") || symbols.contains("wait"),
            "blocking frame missing:\n\(symbols)"
        )
        XCTAssertTrue(symbols.contains("parkForBacktrace"), "demangled test frame missing:\n\(symbols)")
        XCTAssertFalse(symbols.contains("$s"), "Swift symbols should be demangled:\n\(symbols)")
    }

    func testCapturingCurrentThreadIsRefused() {
        let port = pthread_mach_thread_np(pthread_self())
        XCTAssertTrue(BacktraceCapture.capture(thread: port).isEmpty)
    }

    func testDemangleSwiftSymbol() {
        XCTAssertEqual(Symbolicator.demangle("$s4main3fooyyF"), "main.foo() -> ()")
        XCTAssertEqual(Symbolicator.demangle("objc_msgSend"), "objc_msgSend")
    }

    func testSimplifyRemovesPrivateDiscriminators() {
        let symbol = "static DonkDemo.MainThreadStall.(expensiveStep in _C11F09A39F70C68E6226AB9191470C55)(Swift.Double) -> Swift.Double"
        XCTAssertEqual(Symbolicator.simplify(symbol), "static DonkDemo.MainThreadStall.expensiveStep(Swift.Double) -> Swift.Double")
        XCTAssertEqual(Symbolicator.simplify("closure #1 in foo()"), "closure #1 in foo()")
    }

    func testBacktraceTextLayout() {
        let backtrace = PerformanceBacktrace(
            threadName: "com.apple.main-thread",
            capturedAfter: 1.2,
            frames: [
                PerformanceStackFrame(index: 0, address: 0x1_0000_1000, image: "libsystem_kernel.dylib", symbol: "mach_msg2_trap", offset: 8),
                PerformanceStackFrame(index: 1, address: 0x1_0000_2000, image: nil, symbol: nil, offset: 0),
            ]
        )
        let lines = backtrace.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Thread 0 name: com.apple.main-thread")
        XCTAssertEqual(lines[1], "Captured 1.2 s into the hang")
        XCTAssertTrue(lines[3].hasPrefix("0   libsystem_kernel.dylib"))
        XCTAssertTrue(lines[3].hasSuffix("0x0000000100001000 mach_msg2_trap + 8"))
        XCTAssertTrue(lines[4].contains("???"))
        XCTAssertEqual(backtrace.compactText.components(separatedBy: "\n")[0], "0  libsystem_kernel.dylib  0x100001000")
        XCTAssertEqual(backtrace.compactText.components(separatedBy: "\n")[1], "    mach_msg2_trap + 8")
    }
}

final class HangWatchdogTests: XCTestCase {
    func testReportsHangOnceWhenQueueIsBlocked() {
        let queue = DispatchQueue(label: "donk.test.watched")
        var configuration = HangWatchdog.Configuration()
        configuration.captureThreshold = .infinity
        let watchdog = HangWatchdog(queue: queue, configuration: configuration)
        let reported = expectation(description: "hang reported")
        let reports = ReportList()
        watchdog.start { report in
            reports.append(report)
            reported.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        queue.async {
            Thread.sleep(forTimeInterval: 0.6)
        }
        wait(for: [reported], timeout: 3)
        Thread.sleep(forTimeInterval: 0.4)
        watchdog.stop()
        let captured = reports.values
        XCTAssertEqual(captured.count, 1)
        XCTAssertGreaterThanOrEqual(captured.first?.duration ?? 0, 0.45)
        XCTAssertLessThan(captured.first?.duration ?? 10, 1.2)
        XCTAssertTrue(captured.first?.addresses.isEmpty ?? false)
    }

    func testShortStallIsNotReported() {
        let queue = DispatchQueue(label: "donk.test.short")
        let watchdog = HangWatchdog(queue: queue)
        let notReported = expectation(description: "no hang")
        notReported.isInverted = true
        watchdog.start { _ in notReported.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)
        queue.async {
            Thread.sleep(forTimeInterval: 0.12)
        }
        wait(for: [notReported], timeout: 1)
        watchdog.stop()
    }

    func testCapturesStackWhileQueueIsStillHung() {
        let queue = DispatchQueue(label: "donk.test.parked-queue")
        var configuration = HangWatchdog.Configuration()
        configuration.captureThreshold = 0.4
        let portBox = PortBox()
        queue.sync {
            portBox.set(pthread_mach_thread_np(pthread_self()))
        }
        let watchdog = HangWatchdog(queue: queue, target: portBox.value, configuration: configuration)
        let reported = expectation(description: "hang with stack")
        let reportBox = ReportBox()
        watchdog.start { report in
            reportBox.set(report)
            reported.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.25)
        queue.async {
            Thread.sleep(forTimeInterval: 0.8)
        }
        wait(for: [reported], timeout: 4)
        watchdog.stop()
        let report = reportBox.value
        XCTAssertNotNil(report)
        XCTAssertGreaterThanOrEqual(report?.duration ?? 0, 0.6)
        XCTAssertGreaterThanOrEqual(report?.capturedAfter ?? 0, 0.4)
        XCTAssertFalse(report?.addresses.isEmpty ?? true, "stack should be captured while the queue is hung")
    }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: thread_t = 0

    var value: thread_t {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    func set(_ value: thread_t) {
        lock.lock()
        port = value
        lock.unlock()
    }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: HangReport?

    var value: HangReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    func set(_ value: HangReport) {
        lock.lock()
        report = value
        lock.unlock()
    }
}

final class ReportList: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [HangReport] = []

    var values: [HangReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    func append(_ report: HangReport) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }
}
