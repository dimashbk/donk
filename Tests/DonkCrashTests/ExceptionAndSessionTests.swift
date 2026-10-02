import DonkCrashC
import XCTest
@testable import DonkCrash

final class ExceptionAndSessionTests: XCTestCase {
    func testExceptionRecordJSONRoundTrip() throws {
        let exception = NSException(name: .rangeException, reason: "index 5 beyond bounds [0 .. 2]", userInfo: ["b": 2, "a": "one"])
        let images = [RawImage(index: 0, loadAddress: 0x1_0000_0000, slide: 0x4000, textSize: 0x8000, uuid: "11111111-2222-3333-4444-555555555555", cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 2, path: "/x/Demo.app/Demo")]
        let record = ExceptionRecord(exception: exception, images: images, time: Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(record.name, "NSRangeException")
        XCTAssertEqual(record.userInfo, [CrashDetail("a", "one"), CrashDetail("b", "2")])
        XCTAssertTrue(record.isMainThread)
        let data = try XCTUnwrap(record.encoded())
        let decoded = try XCTUnwrap(ExceptionRecord.decode(data))
        XCTAssertEqual(decoded, record)
        XCTAssertNil(ExceptionRecord.decode(Data()))
        XCTAssertNil(ExceptionRecord.decode(Data("{".utf8)))
    }

    func testExceptionValuesAreTruncated() {
        let long = String(repeating: "x", count: ExceptionRecord.valueLimit + 10)
        let truncated = ExceptionRecord.truncate(long)
        XCTAssertEqual(truncated.count, ExceptionRecord.valueLimit + 1)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    func testExceptionMergesWithAbortSignal() throws {
        let directory = makeCrashTemporaryDirectory()
        let address = cFunctionAddress(donk_crash_is_installed)
        let rawData = writeSyntheticRawReport(to: directory.appendingPathComponent("raw"), signal: SIGABRT, code: 0, faultAddress: 0, pc: address + 4, lr: 0, returnAddresses: [address + 8], message: "abort() called")
        let raw = try XCTUnwrap(RawCrashParser.parse(rawData))
        let record = ExceptionRecord(
            name: "NSInvalidArgumentException",
            reason: "-[NSNull length]: unrecognized selector",
            userInfo: [],
            addresses: [address + 16, address + 20],
            symbols: ["0   CoreFoundation   0x0000000180431234 __exceptionPreprocess + 164", "1   libobjc.A.dylib   0x0000000180431238 objc_exception_throw + 60"],
            time: Date(timeIntervalSince1970: 1_700_000_000),
            threadName: nil,
            isMainThread: true,
            images: []
        )
        let builder = CrashReportBuilder(symbolicator: Symbolicator(), fallbackLaunch: testLaunchInfo())
        let report = try XCTUnwrap(builder.build(raw: raw, exception: record, launch: testLaunchInfo(version: "9.9")))
        XCTAssertEqual(report.kind, .exception)
        XCTAssertEqual(report.title, "NSInvalidArgumentException")
        XCTAssertEqual(report.subtitle, "-[NSNull length]: unrecognized selector")
        XCTAssertEqual(report.signal?.name, "SIGABRT")
        XCTAssertEqual(report.signal?.machException, "EXC_CRASH")
        XCTAssertEqual(report.frames.count, 2)
        XCTAssertEqual(report.frames[0].symbol, "donk_crash_is_installed")
        XCTAssertEqual(report.signalFrames.count, 2)
        XCTAssertEqual(report.appVersion, "9.9")
        XCTAssertEqual(report.exception?.symbols.count, 2)
    }

    func testExceptionWithoutSignalUsesItsOwnImagesAndSymbols() throws {
        let record = ExceptionRecord(
            name: "NSGenericException",
            reason: nil,
            userInfo: [],
            addresses: [0x1_0000_1000, 0x5],
            symbols: ["0   Demo   0x0000000100001000 $s4Demo3fooyyF + 4", "1   ???   0x0000000000000005 0x0 + 5"],
            time: Date(timeIntervalSince1970: 1_700_000_000),
            threadName: "worker",
            isMainThread: false,
            images: [RawImage(index: 0, loadAddress: 0x1_0000_0000, slide: 0, textSize: 0x8000, uuid: "ABABABAB-2222-3333-4444-555555555555", cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 2, path: "/x/Demo.app/Demo")]
        )
        let builder = CrashReportBuilder(symbolicator: Symbolicator(loaded: [], currentBundlePath: "/y") { _ in nil }, fallbackLaunch: testLaunchInfo())
        let report = try XCTUnwrap(builder.build(raw: nil, exception: record, launch: nil))
        XCTAssertNil(report.signal)
        XCTAssertEqual(report.frames[0].symbol, "Demo.foo() -> ()")
        XCTAssertEqual(report.frames[0].imageName, "Demo")
        XCTAssertTrue(report.frames[0].isAppFrame)
        XCTAssertEqual(report.threadName, "worker")
        XCTAssertEqual(report.isMainThread, false)
        XCTAssertEqual(report.binaryImages.map(\.name), ["Demo"])
        XCTAssertTrue(CrashTextFormatter.text(for: report).contains("Exception Type:  EXC_CRASH (SIGABRT)"))
    }

    func testUncleanExitDetection() {
        let current = testLaunchInfo()
        let marker = SessionMarker(version: "1.2", build: "34", osVersion: "17.0", launchDate: Date(timeIntervalSince1970: 100), activeDate: Date(timeIntervalSince1970: 200), processID: 77)
        let report = UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: current, launch: nil)
        XCTAssertEqual(report?.kind, .uncleanExit)
        XCTAssertEqual(report?.date, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(report?.processID, 77)
        XCTAssertEqual(report?.subtitle, "Possibly killed by the system (OOM/watchdog) or a debugger")

        XCTAssertNil(UncleanExitDetector.report(marker: nil, hasCrash: false, isEnabled: true, current: current, launch: nil))
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: true, isEnabled: true, current: current, launch: nil))
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: false, current: current, launch: nil))
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: testLaunchInfo(version: "1.3"), launch: nil))
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: testLaunchInfo(build: "35"), launch: nil))
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: testLaunchInfo(os: "17.1"), launch: nil))
    }

    func testSettingsPersistAndDefaultToDetectingUncleanExits() {
        let directory = makeCrashTemporaryDirectory()
        let store = CrashSettingsStore(directory: directory)
        XCTAssertTrue(store.settings.detectsUncleanExits)
        store.update { $0.detectsUncleanExits = false }
        XCTAssertFalse(CrashSettingsStore(directory: directory).settings.detectsUncleanExits)
        let legacy = Data(#"{"seenMetricKitPayloads":["a"]}"#.utf8)
        try? legacy.write(to: directory.appendingPathComponent("crash-settings.json"))
        let reloaded = CrashSettingsStore(directory: directory).settings
        XCTAssertTrue(reloaded.detectsUncleanExits)
        XCTAssertEqual(reloaded.seenMetricKitPayloads, ["a"])
    }
}
