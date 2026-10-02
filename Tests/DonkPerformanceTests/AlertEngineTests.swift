import XCTest
@testable import DonkPerformance

final class AlertEngineTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 1000
    }

    private let megabyte: UInt64 = 1_048_576
    private var clock = Clock()

    override func setUp() {
        super.setUp()
        clock = Clock()
    }

    private func makeEngine(_ configure: (inout PerformanceAlertSettings) -> Void = { _ in }) -> AlertEngine {
        var settings = PerformanceAlertSettings.default
        configure(&settings)
        let clock = clock
        return AlertEngine(settings: settings, clock: { clock.now })
    }

    private func sample(
        cpu: Double = 10,
        footprint: UInt64 = 100 * 1_048_576,
        limit: UInt64? = nil,
        fps: Double? = 60,
        hitch: Double? = 0,
        foreground: Bool = true
    ) -> PerformanceSample {
        PerformanceSample(
            uptime: clock.now,
            cpu: cpu,
            footprint: footprint,
            memoryLimit: limit,
            fps: fps,
            hitchRatio: hitch,
            isForeground: foreground
        )
    }

    @discardableResult
    private func feed(
        _ engine: AlertEngine,
        seconds: ClosedRange<Int>,
        start: TimeInterval = 1000,
        make: (Int) -> PerformanceSample
    ) -> [(Int, PerformanceAlert)] {
        var fired: [(Int, PerformanceAlert)] = []
        for second in seconds {
            clock.now = start + TimeInterval(second)
            for alert in engine.evaluate(make(second)) {
                fired.append((second, alert))
            }
        }
        return fired
    }

    // MARK: - CPU

    func testCPUAlertFiresOnlyAfterSustainedWindow() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...10) { _ in self.sample(cpu: 92) }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.0, 10)
        XCTAssertEqual(fired.first?.1.kind, .cpu)
        XCTAssertEqual(fired.first?.1.message, "CPU 92% for 10 s")
        XCTAssertEqual(fired.first?.1.severity, .warning)
    }

    func testCPUWindowRestartsWhenValueDrops() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...19) { second in
            self.sample(cpu: second == 9 ? 40 : 95)
        }
        XCTAssertTrue(fired.isEmpty)
        clock.now = 1020
        let alerts = engine.evaluate(sample(cpu: 95))
        XCTAssertEqual(alerts.map(\.kind), [.cpu])
    }

    func testCPUIgnoredInBackground() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...30) { _ in self.sample(cpu: 150, foreground: false) }
        XCTAssertTrue(fired.isEmpty)
    }

    func testSampleGapResetsSustainedWindow() {
        let engine = makeEngine()
        XCTAssertTrue(feed(engine, seconds: 0...6) { _ in self.sample(cpu: 95) }.isEmpty)
        let fired = feed(engine, seconds: 20...29) { _ in self.sample(cpu: 95) }
        XCTAssertTrue(fired.isEmpty)
        clock.now = 1030
        XCTAssertEqual(engine.evaluate(sample(cpu: 95)).map(\.kind), [.cpu])
    }

    // MARK: - Cooldown

    func testCooldownSuppressesRepeatsOfTheSameType() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...45) { _ in self.sample(cpu: 90) }
        XCTAssertEqual(fired.map(\.0), [10, 40])
        XCTAssertEqual(fired.last?.1.message, "CPU 90% for 40 s")
    }

    func testCooldownIsPerType() {
        let engine = makeEngine()
        XCTAssertNotNil(engine.hang(duration: 0.5))
        XCTAssertNotNil(engine.memoryWarning())
        clock.now += 5
        XCTAssertNil(engine.hang(duration: 0.9))
        XCTAssertNil(engine.memoryWarning())
        clock.now += 26
        XCTAssertNotNil(engine.hang(duration: 0.9))
    }

    func testCustomCooldown() {
        let engine = makeEngine { $0.cooldown = 5 }
        XCTAssertNotNil(engine.hang(duration: 0.5))
        clock.now += 4
        XCTAssertNil(engine.hang(duration: 0.5))
        clock.now += 1.5
        XCTAssertNotNil(engine.hang(duration: 0.5))
    }

    // MARK: - Memory

    func testMemoryGrowthDetected() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...40) { second in
            self.sample(footprint: (100 + UInt64(second) * 2) * self.megabyte)
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.0, 26)
        XCTAssertEqual(fired.first?.1.kind, .memoryGrowth)
        XCTAssertTrue(fired.first?.1.message.hasPrefix("Memory grew 52.0 MB") == true, fired.first?.1.message ?? "")
    }

    func testMemoryGrowthRestartsAfterDrop() {
        let engine = makeEngine()
        var footprints: [UInt64] = []
        footprints += (0...20).map { 100 + UInt64($0) * 2 }
        footprints += [125]
        footprints += (1...20).map { 125 + UInt64($0) * 2 }
        let fired = feed(engine, seconds: 0...(footprints.count - 1)) { second in
            self.sample(footprint: footprints[second] * self.megabyte)
        }
        XCTAssertTrue(fired.isEmpty, "\(fired.map(\.1.message))")
    }

    func testSlowGrowthOutsideWindowIsIgnored() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...600) { second in
            self.sample(footprint: 100 * self.megabyte + UInt64(second) * self.megabyte / 6)
        }
        XCTAssertTrue(fired.isEmpty)
    }

    func testMemoryLimitAlert() {
        let engine = makeEngine { $0.memoryGrowth.isEnabled = false }
        clock.now = 1000
        XCTAssertTrue(engine.evaluate(sample(footprint: 700 * megabyte, limit: 1000 * megabyte)).isEmpty)
        clock.now = 1001
        let alerts = engine.evaluate(sample(footprint: 850 * megabyte, limit: 1000 * megabyte))
        XCTAssertEqual(alerts.map(\.kind), [.memoryLimit])
        XCTAssertEqual(alerts.first?.severity, .warning)
        clock.now = 1100
        XCTAssertEqual(engine.evaluate(sample(footprint: 970 * megabyte, limit: 1000 * megabyte)).first?.severity, .critical)
    }

    func testMemoryLimitNeedsKnownLimit() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...5) { _ in self.sample(footprint: 4000 * self.megabyte, limit: nil) }
        XCTAssertTrue(fired.filter { $0.1.kind == .memoryLimit }.isEmpty)
    }

    // MARK: - Frames

    func testLowFPSSustained() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...6) { _ in self.sample(fps: 32) }
        XCTAssertEqual(fired.map(\.0), [5])
        XCTAssertEqual(fired.first?.1.message, "FPS 32 for 5 s")
    }

    func testLowFPSIgnoredWithoutFramesOrInBackground() {
        let engine = makeEngine()
        XCTAssertTrue(feed(engine, seconds: 0...10) { _ in self.sample(fps: nil) }.isEmpty)
        XCTAssertTrue(feed(engine, seconds: 11...30) { _ in self.sample(fps: 20, foreground: false) }.isEmpty)
    }

    func testHitchRatioSustained() {
        let engine = makeEngine()
        let fired = feed(engine, seconds: 0...5) { _ in self.sample(hitch: 15) }
        XCTAssertEqual(fired.map(\.0), [5])
        XCTAssertEqual(fired.first?.1.kind, .hitches)
        XCTAssertEqual(fired.first?.1.severity, .critical)
    }

    // MARK: - Events

    func testHangThresholdAndSeverity() {
        let engine = makeEngine()
        XCTAssertNil(engine.hang(duration: 0.2))
        let alert = engine.hang(duration: 0.64)
        XCTAssertEqual(alert?.message, "Main thread hung for 640 ms")
        XCTAssertEqual(alert?.severity, .warning)
        clock.now += 31
        let severe = engine.hang(duration: 2.5)
        XCTAssertEqual(severe?.severity, .critical)
        XCTAssertEqual(severe?.message, "Main thread hung for 2.5 s")
    }

    func testThermalStates() {
        let engine = makeEngine()
        XCTAssertNil(engine.thermalChanged(.nominal))
        XCTAssertNil(engine.thermalChanged(.fair))
        XCTAssertEqual(engine.thermalChanged(.serious)?.severity, .warning)
        clock.now += 31
        XCTAssertEqual(engine.thermalChanged(.critical)?.severity, .critical)

        let criticalOnly = makeEngine { $0.thermal.threshold = Double(ProcessInfo.ThermalState.critical.rawValue) }
        XCTAssertNil(criticalOnly.thermalChanged(.serious))
        XCTAssertNotNil(criticalOnly.thermalChanged(.critical))
    }

    func testMemoryWarning() {
        let engine = makeEngine()
        let alert = engine.memoryWarning()
        XCTAssertEqual(alert?.kind, .memoryWarning)
        XCTAssertEqual(alert?.severity, .critical)
    }

    // MARK: - Settings

    func testDisabledRulesProduceNoAlerts() {
        let engine = makeEngine { settings in
            for kind in PerformanceAlertKind.allCases {
                settings[kind].isEnabled = false
            }
        }
        let fired = feed(engine, seconds: 0...200) { second in
            self.sample(
                cpu: 300,
                footprint: (100 + UInt64(second) * 5) * self.megabyte,
                limit: 200 * self.megabyte,
                fps: 10,
                hitch: 80
            )
        }
        XCTAssertTrue(fired.isEmpty)
        XCTAssertNil(engine.hang(duration: 5))
        XCTAssertNil(engine.thermalChanged(.critical))
        XCTAssertNil(engine.memoryWarning())
    }

    func testEditedThresholdsApply() {
        let engine = makeEngine { settings in
            settings.cpu.threshold = 50
            settings.cpu.duration = 3
            settings.hang.threshold = 1000
        }
        let fired = feed(engine, seconds: 0...3) { _ in self.sample(cpu: 60) }
        XCTAssertEqual(fired.map(\.0), [3])
        XCTAssertNil(engine.hang(duration: 0.8))
        XCTAssertNotNil(engine.hang(duration: 1.2))
    }

    func testSettingsDecodeMissingKeysWithDefaults() throws {
        let data = Data(#"{"cpu":{"isEnabled":false,"threshold":120,"duration":4},"cooldown":12}"#.utf8)
        let settings = try JSONDecoder().decode(PerformanceAlertSettings.self, from: data)
        XCTAssertFalse(settings.cpu.isEnabled)
        XCTAssertEqual(settings.cpu.threshold, 120)
        XCTAssertEqual(settings.cooldown, 12)
        XCTAssertEqual(settings.hang, PerformanceAlertSettings.default.hang)
        XCTAssertEqual(settings.lowFPS, PerformanceAlertSettings.default.lowFPS)
    }
}
