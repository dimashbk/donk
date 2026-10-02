import XCTest
@testable import DonkPerformance

final class HitchCalculatorTests: XCTestCase {
    private func run(_ calculator: inout HitchCalculator, timestamps: [Double], rate: Double) -> [FrameResult] {
        let duration = 1 / rate
        return timestamps.map { calculator.frame(timestamp: $0, targetTimestamp: $0 + duration) }
    }

    func testSteadySixtyHertzHasNoHitches() {
        var calculator = HitchCalculator()
        let timestamps = (0..<120).map { 100 + Double($0) / 60 }
        let results = run(&calculator, timestamps: timestamps, rate: 60)
        XCTAssertEqual(results.filter(\.isHitch).count, 0)
        XCTAssertEqual(results.reduce(0) { $0 + $1.droppedFrames }, 0)
        XCTAssertEqual(results.last?.frameDuration ?? 0, 1.0 / 60, accuracy: 1e-9)
    }

    func testSingleSkippedFrameIsOneFrameLate() {
        var calculator = HitchCalculator()
        let timestamps = [0, 1, 3, 4].map { 10 + Double($0) / 60 }
        let results = run(&calculator, timestamps: timestamps, rate: 60)
        XCTAssertFalse(results[1].isHitch)
        XCTAssertTrue(results[2].isHitch)
        XCTAssertEqual(results[2].hitchTime, 1.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(results[2].droppedFrames, 1)
        XCTAssertFalse(results[3].isHitch)
    }

    func testLongStallCountsDroppedFrames() {
        var calculator = HitchCalculator()
        let results = run(&calculator, timestamps: [0, 1.0 / 60, 0.5], rate: 60)
        XCTAssertEqual(results[2].hitchTime, 0.5 - 2.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(results[2].droppedFrames, 28)
    }

    func testOneHundredTwentyHertzSkip() {
        var calculator = HitchCalculator()
        let timestamps = [0, 1, 2, 4, 5].map { Double($0) / 120 }
        let results = run(&calculator, timestamps: timestamps, rate: 120)
        XCTAssertEqual(results.filter(\.isHitch).count, 1)
        XCTAssertEqual(results[3].hitchTime, 1.0 / 120, accuracy: 1e-6)
        XCTAssertEqual(results[3].droppedFrames, 1)
    }

    func testSmallJitterIsNotAHitch() {
        var calculator = HitchCalculator()
        let timestamps = [0.0, 1.0 / 60 + 0.0004, 2.0 / 60 + 0.0002, 3.0 / 60 + 0.003]
        let results = run(&calculator, timestamps: timestamps, rate: 60)
        XCTAssertEqual(results.filter(\.isHitch).count, 0)
    }

    func testResetForgetsPreviousFrame() {
        var calculator = HitchCalculator()
        _ = calculator.frame(timestamp: 0, targetTimestamp: 1.0 / 60)
        calculator.reset()
        let result = calculator.frame(timestamp: 30, targetTimestamp: 30 + 1.0 / 60)
        XCTAssertFalse(result.isHitch)
    }

    func testAccumulatorComputesWindowMetrics() {
        var calculator = HitchCalculator()
        var accumulator = FrameAccumulator()
        accumulator.begin(at: 0)
        var timestamps = (0..<60).map { Double($0) / 60 }
        timestamps.remove(at: 30)
        for timestamp in timestamps {
            accumulator.record(calculator.frame(timestamp: timestamp, targetTimestamp: timestamp + 1.0 / 60), maximumFPS: 120)
        }
        let window = accumulator.drain(now: 1)
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.fps ?? 0, 59, accuracy: 0.01)
        XCTAssertEqual(window?.hitchRatio ?? 0, 1000.0 / 60, accuracy: 0.01)
        XCTAssertEqual(window?.droppedFrames, 1)
        XCTAssertEqual(window?.targetFPS, 60)
        let next = accumulator.drain(now: 2)
        XCTAssertEqual(next?.fps ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(next?.hitchRatio ?? -1, 0, accuracy: 0.001)
    }

    func testAccumulatorCapsHitchRatio() {
        var accumulator = FrameAccumulator()
        accumulator.begin(at: 0)
        accumulator.record(FrameResult(hitchTime: 3, droppedFrames: 180, frameDuration: 1.0 / 60), maximumFPS: 60)
        XCTAssertEqual(accumulator.drain(now: 1)?.hitchRatio, 1000)
    }

    func testStoppedAccumulatorReturnsNoWindow() {
        var accumulator = FrameAccumulator()
        XCTAssertNil(accumulator.drain(now: 5))
        accumulator.begin(at: 5)
        accumulator.stop()
        XCTAssertNil(accumulator.drain(now: 6))
    }
}
