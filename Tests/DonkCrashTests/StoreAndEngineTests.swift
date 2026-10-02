import Combine
import DonkCrashC
import XCTest
@testable import DonkCrash

final class StoreAndEngineTests: XCTestCase {
    func testReportsPersistAcrossStoreInstances() throws {
        let directory = makeCrashTemporaryDirectory()
        let store = CrashReportStore(directory: directory)
        var older = sampleReport(date: Date(timeIntervalSince1970: 100))
        older.id = UUID()
        var newer = sampleReport(date: Date(timeIntervalSince1970: 200))
        newer.id = UUID()
        store.add([older, newer])
        XCTAssertEqual(store.count, 2)

        let reloaded = CrashReportStore(directory: directory).all()
        XCTAssertEqual(reloaded, [newer, older])

        store.delete([older.id])
        XCTAssertEqual(CrashReportStore(directory: directory).all(), [newer])
        store.deleteAll()
        XCTAssertTrue(CrashReportStore(directory: directory).all().isEmpty)
    }

    func testStoreSkipsCorruptFilesAndPrunesToLimit() throws {
        let directory = makeCrashTemporaryDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let store = CrashReportStore(directory: directory, limit: 3)
        XCTAssertEqual(store.count, 0)
        let reports = (0..<5).map { offset -> CrashReport in
            var report = sampleReport(date: Date(timeIntervalSince1970: TimeInterval(offset)))
            report.id = UUID()
            return report
        }
        store.add(reports)
        XCTAssertEqual(store.all().map(\.date.timeIntervalSince1970), [4, 3, 2])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") && $0 != "broken.json" }
        XCTAssertEqual(files.count, 3)
    }

    func testStorePublishesChanges() {
        let store = CrashReportStore(directory: makeCrashTemporaryDirectory())
        var received: [[CrashReport]] = []
        let cancellable = store.changes.sink { received.append($0) }
        store.add(sampleReport())
        store.deleteAll()
        cancellable.cancel()
        XCTAssertEqual(received.map(\.count), [1, 0])
    }

    func testCodableRoundTripPreservesEverything() throws {
        let report = sampleReport()
        let data = try XCTUnwrap(CrashJSON.encode(report))
        XCTAssertEqual(CrashJSON.decode(CrashReport.self, from: data), report)
        let export = try XCTUnwrap(CrashExport.json(for: report))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: export) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "signal")
        XCTAssertNotNil(object["frames"] as? [Any])
    }

    func testEngineTurnsPendingFilesIntoReportsOnNextLaunch() throws {
        let root = makeCrashTemporaryDirectory()
        let paths = CrashPaths(root: root.appendingPathComponent("Crashes"), settingsDirectory: root)
        try FileManager.default.createDirectory(at: paths.raw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)

        let address = cFunctionAddress(donk_crash_is_installed)
        _ = writeSyntheticRawReport(to: paths.pending, signal: SIGTRAP, code: 1, faultAddress: 0, pc: address + 4, lr: 0, returnAddresses: [address + 8], message: "Fatal error: from the previous launch")
        try XCTUnwrap(CrashJSON.encode(testLaunchInfo(version: "7.0"))).write(to: paths.launch)
        let marker = SessionMarker(version: "7.0", build: "34", osVersion: "17.0", launchDate: Date(), activeDate: Date(), processID: 1)
        try XCTUnwrap(CrashJSON.encode(marker)).write(to: paths.session)
        FileManager.default.createFile(atPath: paths.exception.path, contents: Data())

        let engine = CrashEngine(paths: paths)
        XCTAssertNotNil(engine.moveToInbox())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.exception.path))
        engine.processInbox()

        let reports = engine.store.all()
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.kind, .signal)
        XCTAssertEqual(report.title, "EXC_BREAKPOINT / SIGTRAP")
        XCTAssertEqual(report.appVersion, "7.0")
        XCTAssertEqual(report.primaryMessage, "Fatal error: from the previous launch")
        XCTAssertEqual(report.frames.first?.symbol, "donk_crash_is_installed")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)).isEmpty)
        XCTAssertEqual(CrashReportStore(directory: paths.root).count, 1)
    }

    func testEngineReportsUncleanExitWhenOnlyTheMarkerRemains() throws {
        let root = makeCrashTemporaryDirectory()
        let paths = CrashPaths(root: root.appendingPathComponent("Crashes"), settingsDirectory: root)
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let current = LaunchInfo.current()
        try XCTUnwrap(CrashJSON.encode(current)).write(to: paths.launch)
        let marker = SessionMarker(version: current.version, build: current.build, osVersion: current.osVersion, launchDate: Date(timeIntervalSince1970: 10), activeDate: Date(timeIntervalSince1970: 20), processID: 99)
        try XCTUnwrap(CrashJSON.encode(marker)).write(to: paths.session)

        let engine = CrashEngine(paths: paths)
        engine.moveToInbox()
        engine.processInbox()
        XCTAssertEqual(engine.store.all().map(\.kind), [.uncleanExit])

        try XCTUnwrap(CrashJSON.encode(marker)).write(to: paths.session)
        engine.detectsUncleanExits = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.session.path))
        try XCTUnwrap(CrashJSON.encode(marker)).write(to: paths.session)
        engine.moveToInbox()
        engine.processInbox()
        XCTAssertEqual(engine.store.count, 1)
    }

    func testEngineIgnoresCleanLaunches() throws {
        let root = makeCrashTemporaryDirectory()
        let paths = CrashPaths(root: root.appendingPathComponent("Crashes"), settingsDirectory: root)
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        try XCTUnwrap(CrashJSON.encode(LaunchInfo.current())).write(to: paths.launch)
        FileManager.default.createFile(atPath: paths.pending.path, contents: Data())
        let engine = CrashEngine(paths: paths)
        engine.moveToInbox()
        engine.processInbox()
        XCTAssertEqual(engine.store.count, 0)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)).isEmpty)
    }

    func testMetricKitDiagnosticsAreDeduplicated() {
        let root = makeCrashTemporaryDirectory()
        let engine = CrashEngine(paths: CrashPaths(root: root.appendingPathComponent("Crashes"), settingsDirectory: root))
        let diagnostic = MetricKitDiagnostic(
            category: .hang,
            title: "Hang · 2.50 s",
            date: Date(timeIntervalSince1970: 500),
            version: "1.0",
            build: "1",
            osVersion: "iPhone OS 17.0",
            deviceType: "iPhone15,2",
            architecture: "arm64",
            processID: nil,
            details: [CrashDetail("Hang duration", "2.50 s")],
            callStackJSON: nil,
            signature: "hang-500-abc"
        )
        engine.ingest([diagnostic])
        engine.ingest([diagnostic])
        XCTAssertEqual(engine.store.count, 1)
        XCTAssertEqual(engine.store.all().first?.title, "Hang · 2.50 s")
        XCTAssertEqual(engine.store.all().first?.kind, .metricKit)
    }
}
