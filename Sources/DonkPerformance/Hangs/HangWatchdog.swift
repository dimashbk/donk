import Darwin
import DonkCore
import Foundation
import QuartzCore

struct HangReport: Sendable {
    var duration: TimeInterval
    var endedAt: Date
    var addresses: [UInt]
    var capturedAfter: TimeInterval?
    var startedUptime: CFTimeInterval = 0
    var endedUptime: CFTimeInterval = 0
}

enum HangFilter {
    static func effectiveDuration(measured: TimeInterval, watchdogStall: TimeInterval) -> TimeInterval {
        max(0, measured - watchdogStall)
    }

    static func isWholeProcessStop(measured: TimeInterval, watchdogStall: TimeInterval, threshold: TimeInterval, tolerance: TimeInterval, isTraced: Bool) -> Bool {
        guard watchdogStall > 0 else { return false }
        if effectiveDuration(measured: measured, watchdogStall: watchdogStall) < threshold + tolerance {
            return true
        }
        return isTraced && watchdogStall >= threshold
    }
}

enum ProcessTracing {
    static func isTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}

final class HangWatchdog: @unchecked Sendable {
    struct Configuration {
        var threshold: TimeInterval = 0.25
        var captureThreshold: TimeInterval = 1
        var pingInterval: TimeInterval = 0.1
        var stallSlack: TimeInterval = 0.05
    }

    private final class Session: @unchecked Sendable {
        let lock = DonkLock()
        let wake = DispatchSemaphore(value: 0)
        var isRunning = true
        var isPaused = false
        var generation = 0
        var lastPong: (id: UInt64, time: CFTimeInterval)?
    }

    private let lock = DonkLock()
    private let queue: DispatchQueue
    private let target: thread_t
    private var session: Session?
    private var configuration: Configuration
    private var handler: (@Sendable (HangReport) -> Void)?

    private let isTraced: @Sendable () -> Bool

    init(
        queue: DispatchQueue = .main,
        target: thread_t = CPUSampler.mainThreadPort,
        configuration: Configuration = Configuration(),
        isTraced: @escaping @Sendable () -> Bool = { ProcessTracing.isTraced() }
    ) {
        self.queue = queue
        self.target = target
        self.configuration = configuration
        self.isTraced = isTraced
    }

    var isRunning: Bool {
        lock.withLock { session != nil }
    }

    func start(onHang: @escaping @Sendable (HangReport) -> Void) {
        let session: Session? = lock.withLock {
            guard self.session == nil else { return nil }
            let session = Session()
            self.session = session
            handler = onHang
            return session
        }
        guard let session else { return }
        let configuration = lock.withLock { self.configuration }
        let thread = Thread { [weak self] in
            self?.run(session, configuration: configuration)
        }
        thread.name = "io.github.donk.performance.watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let session: Session? = lock.withLock {
            defer {
                self.session = nil
                handler = nil
            }
            return self.session
        }
        guard let session else { return }
        session.lock.withLock { session.isRunning = false }
        session.wake.signal()
    }

    func setPaused(_ paused: Bool) {
        guard let session = lock.withLock({ session }) else { return }
        session.lock.withLock {
            guard session.isPaused != paused else { return }
            session.isPaused = paused
            session.generation += 1
        }
    }

    // MARK: - Loop

    private func run(_ session: Session, configuration: Configuration) {
        let scratch = BacktraceCapture.Scratch()
        var pingID: UInt64 = 0
        var sentAt: CFTimeInterval = 0
        var awaiting = false
        var observedGeneration = 0
        var addresses: [UInt] = []
        var capturedAfter: TimeInterval?
        var stall: TimeInterval = 0

        func clear() {
            awaiting = false
            addresses = []
            capturedAfter = nil
            stall = 0
        }

        while true {
            let state = session.lock.withLock { (session.isRunning, session.isPaused, session.generation) }
            guard state.0 else { break }
            if state.2 != observedGeneration {
                observedGeneration = state.2
                clear()
            }
            if state.1 {
                _ = session.wake.wait(timeout: .now() + configuration.pingInterval * 3)
                continue
            }
            if !awaiting {
                pingID &+= 1
                let id = pingID
                sentAt = CACurrentMediaTime()
                awaiting = true
                queue.async { [weak session] in
                    guard let session else { return }
                    let now = CACurrentMediaTime()
                    session.lock.withLock { session.lastPong = (id, now) }
                }
            }
            let waitStarted = CACurrentMediaTime()
            _ = session.wake.wait(timeout: .now() + configuration.pingInterval)
            let overshoot = CACurrentMediaTime() - waitStarted - configuration.pingInterval
            if overshoot > configuration.stallSlack {
                stall += overshoot
            }
            let check = session.lock.withLock { (session.isRunning, session.generation, session.lastPong) }
            guard check.0 else { break }
            guard check.1 == observedGeneration else { continue }
            if let pong = check.2, pong.id == pingID {
                let measured = pong.time - sentAt
                if measured >= configuration.threshold {
                    let traced = stall >= configuration.threshold && isTraced()
                    if !HangFilter.isWholeProcessStop(measured: measured, watchdogStall: stall, threshold: configuration.threshold, tolerance: configuration.pingInterval, isTraced: traced) {
                        let report = HangReport(
                            duration: HangFilter.effectiveDuration(measured: measured, watchdogStall: stall),
                            endedAt: Date(),
                            addresses: addresses,
                            capturedAfter: capturedAfter,
                            startedUptime: sentAt,
                            endedUptime: pong.time
                        )
                        lock.withLock { handler }?(report)
                    }
                }
                clear()
            } else {
                let elapsed = CACurrentMediaTime() - sentAt
                if elapsed - stall >= configuration.captureThreshold, capturedAfter == nil {
                    addresses = BacktraceCapture.capture(thread: target, scratch: scratch)
                    capturedAfter = elapsed - stall
                }
            }
        }
    }
}
