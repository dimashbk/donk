import Foundation
import QuartzCore
import UIKit

final class CPUBurner: ObservableObject {
    @Published var threadCount = 2
    @Published private(set) var secondsLeft = 0

    private var token: BurnToken?
    private var timer: Timer?

    var isBurning: Bool {
        secondsLeft > 0
    }

    func burn(for seconds: Int = 10) {
        stop()
        let token = BurnToken(deadline: CACurrentMediaTime() + Double(seconds))
        self.token = token
        for index in 0..<threadCount {
            let thread = Thread {
                CPUBurner.spin(until: token)
            }
            thread.name = "demo.cpu-burner.\(index + 1)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        secondsLeft = seconds
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.secondsLeft = max(0, self.secondsLeft - 1)
            if self.secondsLeft == 0 {
                timer.invalidate()
                self.timer = nil
            }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        timer?.invalidate()
        timer = nil
        secondsLeft = 0
    }

    private static func spin(until token: BurnToken) {
        var value: UInt64 = 0x9E37_79B9_7F4A_7C15
        while !token.isFinished {
            for _ in 0..<20_000 {
                value ^= value << 13
                value ^= value >> 7
                value ^= value << 17
            }
        }
        token.sink(value)
    }
}

final class BurnToken: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: CFTimeInterval
    private var cancelled = false
    private var checksum: UInt64 = 0

    init(deadline: CFTimeInterval) {
        self.deadline = deadline
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || CACurrentMediaTime() >= deadline
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func sink(_ value: UInt64) {
        lock.lock()
        checksum ^= value
        lock.unlock()
    }
}

final class MemoryHog: ObservableObject {
    static let chunkSize = 50 * 1_048_576

    @Published private(set) var chunkCount = 0
    @Published private(set) var isAllocating = false

    private var chunks: [UnsafeMutableRawPointer] = []

    var totalBytes: Int {
        chunkCount * Self.chunkSize
    }

    func allocateChunk() {
        guard !isAllocating else { return }
        isAllocating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let pointer = malloc(Self.chunkSize)
            if let pointer {
                memset(pointer, 0x5A, Self.chunkSize)
            }
            DispatchQueue.main.async {
                if let pointer {
                    self.chunks.append(pointer)
                    self.chunkCount = self.chunks.count
                }
                self.isAllocating = false
            }
        }
    }

    func releaseAll() {
        chunks.forEach { free($0) }
        chunks.removeAll()
        chunkCount = 0
    }

    deinit {
        chunks.forEach { free($0) }
    }
}

enum MainThreadStall {
    @inline(never)
    static func simulateHeavyWork(seconds: TimeInterval) {
        let deadline = CACurrentMediaTime() + seconds
        var accumulator = 0.0
        while CACurrentMediaTime() < deadline {
            accumulator += expensiveStep(accumulator)
        }
        if accumulator.isNaN {
            print(accumulator)
        }
    }

    @inline(never)
    private static func expensiveStep(_ seed: Double) -> Double {
        var value = seed
        for index in 0..<2_000 {
            value = sin(value + Double(index)) * cos(value)
        }
        return value
    }
}
