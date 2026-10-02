import DonkCore
import QuartzCore
import UIKit

// MARK: - Hitch math

struct FrameResult: Equatable {
    var hitchTime: TimeInterval
    var droppedFrames: Int
    var frameDuration: TimeInterval

    var isHitch: Bool {
        hitchTime > 0
    }
}

struct HitchCalculator {
    var lateTolerance: Double = 0.5
    private var previousTarget: CFTimeInterval?

    mutating func reset() {
        previousTarget = nil
    }

    mutating func frame(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) -> FrameResult {
        let duration = targetTimestamp - timestamp
        defer { previousTarget = targetTimestamp }
        guard let previousTarget, duration > 0 else {
            return FrameResult(hitchTime: 0, droppedFrames: 0, frameDuration: max(0, duration))
        }
        let lateness = timestamp - previousTarget
        guard lateness > duration * lateTolerance else {
            return FrameResult(hitchTime: 0, droppedFrames: 0, frameDuration: duration)
        }
        let dropped = max(1, Int((lateness / duration).rounded()))
        return FrameResult(hitchTime: lateness, droppedFrames: dropped, frameDuration: duration)
    }
}

struct FrameWindow: Equatable {
    var fps: Double
    var hitchRatio: Double
    var droppedFrames: Int
    var targetFPS: Int
    var elapsed: TimeInterval
}

struct FrameAccumulator {
    private(set) var frames = 0
    private(set) var hitchTime: TimeInterval = 0
    private(set) var droppedFrames = 0
    private(set) var start: CFTimeInterval?
    private(set) var targetFPS = 60

    mutating func begin(at time: CFTimeInterval) {
        frames = 0
        hitchTime = 0
        droppedFrames = 0
        start = time
    }

    mutating func record(_ result: FrameResult, maximumFPS: Int) {
        frames += 1
        hitchTime += result.hitchTime
        droppedFrames += result.droppedFrames
        if result.frameDuration > 0 {
            let rate = Int((1 / result.frameDuration).rounded())
            targetFPS = min(max(1, rate), max(maximumFPS, 1))
        }
    }

    mutating func drain(now: CFTimeInterval) -> FrameWindow? {
        guard let start else { return nil }
        let elapsed = now - start
        guard elapsed > 0.05 else { return nil }
        let window = FrameWindow(
            fps: Double(frames) / elapsed,
            hitchRatio: min(1000, hitchTime * 1000 / elapsed),
            droppedFrames: droppedFrames,
            targetFPS: targetFPS,
            elapsed: elapsed
        )
        begin(at: now)
        return window
    }

    mutating func stop() {
        frames = 0
        hitchTime = 0
        droppedFrames = 0
        start = nil
    }
}

// MARK: - Display link

final class FrameMonitor: @unchecked Sendable {
    private let lock = DonkLock()
    private var calculator = HitchCalculator()
    private var accumulator = FrameAccumulator()
    private var maximumFPSValue = 60
    private var isRunning = false
    private var isPaused = false
    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var prefersHighRefreshRate = false

    var maximumFPS: Int {
        lock.withLock { maximumFPSValue }
    }

    @MainActor
    func start(prefersHighRefreshRate: Bool) {
        guard link == nil else { return }
        let maximum = max(1, UIScreen.main.maximumFramesPerSecond)
        lock.withLock {
            maximumFPSValue = maximum
            isRunning = true
        }
        self.prefersHighRefreshRate = prefersHighRefreshRate
        let proxy = DisplayLinkProxy()
        proxy.monitor = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        applyFrameRate(to: link)
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
        let background = UIApplication.shared.applicationState == .background
        setPaused(background)
    }

    @MainActor
    func stop() {
        link?.invalidate()
        link = nil
        proxy = nil
        lock.withLock {
            isRunning = false
            calculator.reset()
            accumulator.stop()
        }
    }

    @MainActor
    func setPaused(_ paused: Bool) {
        guard let link else { return }
        link.isPaused = paused
        lock.withLock {
            isPaused = paused
            calculator.reset()
            if paused {
                accumulator.stop()
            } else {
                accumulator.begin(at: CACurrentMediaTime())
            }
        }
    }

    @MainActor
    func setPrefersHighRefreshRate(_ enabled: Bool) {
        prefersHighRefreshRate = enabled
        if let link {
            applyFrameRate(to: link)
        }
        lock.withLock { calculator.reset() }
    }

    func drain(now: CFTimeInterval = CACurrentMediaTime()) -> FrameWindow? {
        lock.withLock {
            guard isRunning, !isPaused else { return nil }
            return accumulator.drain(now: now)
        }
    }

    fileprivate func step(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let target = link.targetTimestamp
        lock.withLock {
            let result = calculator.frame(timestamp: timestamp, targetTimestamp: target)
            if accumulator.start == nil {
                accumulator.begin(at: timestamp)
            }
            accumulator.record(result, maximumFPS: maximumFPSValue)
        }
    }

    @MainActor
    private func applyFrameRate(to link: CADisplayLink) {
        let maximum = Float(lock.withLock { maximumFPSValue })
        if prefersHighRefreshRate, maximum > 60 {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: maximum, preferred: maximum)
        } else {
            link.preferredFrameRateRange = .default
        }
    }
}

private final class DisplayLinkProxy: NSObject {
    weak var monitor: FrameMonitor?

    @objc func step(_ link: CADisplayLink) {
        monitor?.step(link)
    }
}
