import DonkCrashC
import XCTest
@testable import DonkCrash

private struct AlternateStackProbe {
    var installed: Int32 = -2
    var repeated: Int32 = -2
    var base: UInt = 0
    var size = 0
    var guardProtection: vm_prot_t = -1
    var guardIsAdjacent = false

    static func runOnFreshThread() -> AlternateStackProbe {
        let box = ProbeBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = measure()
            done.signal()
        }
        thread.start()
        _ = done.wait(timeout: .now() + 5)
        return box.value
    }

    private static func measure() -> AlternateStackProbe {
        var probe = AlternateStackProbe()
        var before = stack_t()
        sigaltstack(nil, &before)
        guard before.ss_flags & SS_DISABLE != 0 else { return probe }
        probe.installed = donk_crash_install_alternate_stack()
        probe.repeated = donk_crash_install_alternate_stack()
        var stack = stack_t()
        sigaltstack(nil, &stack)
        guard let pointer = stack.ss_sp else { return probe }
        probe.base = UInt(bitPattern: pointer)
        probe.size = stack.ss_size
        var address = vm_address_t(probe.base - 1)
        var regionSize: vm_size_t = 0
        var info = vm_region_basic_info_data_64_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        var object: mach_port_t = 0
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                vm_region_64(mach_task_self_, &address, &regionSize, VM_REGION_BASIC_INFO_64, $0, &count, &object)
            }
        }
        if result == KERN_SUCCESS {
            probe.guardProtection = info.protection
            probe.guardIsAdjacent = address <= probe.base - 1 && address + regionSize == probe.base
        }
        return probe
    }
}

private final class ProbeBox: @unchecked Sendable {
    var value = AlternateStackProbe()
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }
}

private let earlierReporter: @convention(c) (Int32) -> Void = { _ in }

final class CrashHardeningTests: XCTestCase {
    private var savedActions: [Int32: sigaction] = [:]

    override func setUp() {
        super.setUp()
        donk_crash_uninstall()
        donk_crash_debug_reset_guard()
        var count = 0
        let pointer = donk_crash_signals(&count)
        for signal in (0..<count).map({ pointer[$0] }) {
            var action = sigaction()
            sigaction(signal, nil, &action)
            savedActions[signal] = action
        }
    }

    override func tearDown() {
        donk_crash_uninstall()
        donk_crash_debug_reset_guard()
        donk_crash_track_session_marker(nil)
        for (signal, action) in savedActions {
            var copy = action
            sigaction(signal, &copy, nil)
        }
        super.tearDown()
    }

    private func makePaths() throws -> CrashPaths {
        let root = makeCrashTemporaryDirectory()
        let paths = CrashPaths(root: root.appendingPathComponent("Crashes"), settingsDirectory: root)
        try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        return paths
    }

    private func contents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - Alternate stack

    func testAlternateStacksArePerThreadWithAGuardPage() {
        let first = AlternateStackProbe.runOnFreshThread()
        let second = AlternateStackProbe.runOnFreshThread()

        XCTAssertEqual(first.installed, 1)
        XCTAssertEqual(first.repeated, 0, "a thread that already has a large enough stack keeps it")
        XCTAssertEqual(first.size, donk_crash_alternate_stack_size())
        XCTAssertGreaterThanOrEqual(first.size, 256 * 1024)
        XCTAssertEqual(first.guardProtection, 0, "guard page must be PROT_NONE")
        XCTAssertTrue(first.guardIsAdjacent, "the PROT_NONE page must sit directly below the stack")
        XCTAssertEqual(second.installed, 1)
        XCTAssertNotEqual(first.base, 0)
        XCTAssertNotEqual(first.base, second.base, "every thread gets its own stack")
    }

    func testInstallingOffTheMainThreadLeavesTheWorkerWithoutAnAlternateStack() {
        let workerHasStack = FlagBox()
        let workerDone = expectation(description: "worker")
        let thread = Thread {
            CrashEngine.installMainThreadAlternateStack()
            var stack = stack_t()
            sigaltstack(nil, &stack)
            workerHasStack.set(stack.ss_flags & SS_DISABLE == 0)
            workerDone.fulfill()
        }
        thread.start()
        wait(for: [workerDone], timeout: 5)
        XCTAssertFalse(workerHasStack.value)

        let mainChecked = expectation(description: "main")
        DispatchQueue.main.async {
            var stack = stack_t()
            sigaltstack(nil, &stack)
            XCTAssertEqual(stack.ss_flags & SS_DISABLE, 0)
            XCTAssertGreaterThanOrEqual(stack.ss_size, donk_crash_alternate_stack_size())
            mainChecked.fulfill()
        }
        wait(for: [mainChecked], timeout: 5)
    }

    // MARK: - Install order

    func testEngineFlagsInstallationAfterAnotherReporter() throws {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = earlierReporter
        sigemptyset(&action.sa_mask)
        sigaction(SIGSEGV, &action, nil)

        let engine = CrashEngine(paths: try makePaths())
        engine.install(handlesSignals: true, observesLifecycle: false, subscribesToMetricKit: false)
        XCTAssertTrue(engine.waitForProcessing(timeout: 5))

        XCTAssertTrue(engine.isInstalled)
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(engine.installedAfterAnotherReporter)
        XCTAssertTrue(CrashEngine.installOrderWarning.contains("Donk.installCrashReporter() before FirebaseApp.configure()"))
    }

    func testEngineIsNotFlaggedWhenInstalledFirst() throws {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        sigaction(SIGSEGV, &action, nil)
        sigaction(SIGTRAP, &action, nil)

        let engine = CrashEngine(paths: try makePaths())
        engine.install(handlesSignals: true, observesLifecycle: false, subscribesToMetricKit: false)
        XCTAssertTrue(engine.waitForProcessing(timeout: 5))
        XCTAssertFalse(engine.installedAfterAnotherReporter)
    }

    func testEngineReopensRecordFilesThatFailedAtLaunch() throws {
        let paths = try makePaths()
        try FileManager.default.removeItem(at: paths.raw)
        try Data().write(to: paths.raw)

        let engine = CrashEngine(paths: paths)
        engine.install(handlesSignals: true, observesLifecycle: false, subscribesToMetricKit: false)
        XCTAssertTrue(engine.waitForProcessing(timeout: 5))
        XCTAssertTrue(engine.isInstalled)
        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(donk_crash_is_installed(), 1)

        try FileManager.default.removeItem(at: paths.raw)
        XCTAssertTrue(engine.reopenRecords())
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pending.path))
    }

    // MARK: - Inbox

    func testBatchIsKeptWhenItsFilesCannotBeReadAndProcessedLater() throws {
        let paths = try makePaths()
        let address = cFunctionAddress(donk_crash_is_installed)
        _ = writeSyntheticRawReport(to: paths.pending, signal: SIGSEGV, code: 1, faultAddress: 0x10, pc: address + 4, lr: 0, returnAddresses: [address + 8], message: nil)
        try XCTUnwrap(CrashJSON.encode(testLaunchInfo())).write(to: paths.launch)
        let engine = CrashEngine(paths: paths)
        XCTAssertNotNil(engine.moveToInbox())

        engine.processInbox(reader: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertEqual(engine.store.count, 0)
        XCTAssertEqual(contents(paths.inbox).count, 2)

        engine.processInbox()
        XCTAssertEqual(engine.store.count, 1)
        XCTAssertEqual(engine.store.all().first?.signal?.name, "SIGSEGV")
        XCTAssertTrue(contents(paths.inbox).isEmpty)
    }

    func testUnparsableBatchIsRetriedThenQuarantined() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.raw, withIntermediateDirectories: true)
        try Data("garbage that is not a donk record".utf8).write(to: paths.pending)
        try XCTUnwrap(CrashJSON.encode(testLaunchInfo())).write(to: paths.launch)
        let engine = CrashEngine(paths: paths)
        let batch = try XCTUnwrap(engine.moveToInbox())

        for attempt in 1...CrashEngine.parseAttemptLimit {
            engine.processInbox()
            XCTAssertEqual(contents(paths.inbox).count, 2, "attempt \(attempt)")
            XCTAssertEqual(engine.settings.settings.inboxAttempts[batch], attempt)
        }
        engine.processInbox()

        XCTAssertTrue(contents(paths.inbox).isEmpty)
        XCTAssertEqual(contents(paths.quarantine), ["\(batch).launch", "\(batch).signal"])
        XCTAssertTrue(engine.settings.settings.inboxAttempts.isEmpty)
        XCTAssertEqual(engine.store.count, 0)
    }

    func testQuarantineKeepsOnlyTheNewestBatches() throws {
        let paths = try makePaths()
        let engine = CrashEngine(paths: paths)
        for index in 0..<(CrashEngine.quarantineLimit + 2) {
            let name = "\(1_700_000_000_000 + index)-AAAAAAAA"
            try Data("junk".utf8).write(to: paths.inbox.appendingPathComponent("\(name).signal"))
            engine.settings.update { $0.inboxAttempts[name] = CrashEngine.parseAttemptLimit }
        }
        engine.processInbox()
        let kept = contents(paths.quarantine)
        XCTAssertEqual(kept.count, CrashEngine.quarantineLimit)
        XCTAssertFalse(kept.contains { $0.hasPrefix("1700000000000-") })
        XCTAssertTrue(kept.contains { $0.hasPrefix(String(1_700_000_000_000 + CrashEngine.quarantineLimit + 1)) })
    }

    // MARK: - Session marker

    func testDebuggerSessionsAreNotReportedAsUncleanExits() throws {
        let current = testLaunchInfo()
        var marker = SessionMarker(version: "1.2", build: "34", osVersion: "17.0", launchDate: Date(timeIntervalSince1970: 100), activeDate: Date(timeIntervalSince1970: 200), processID: 77)
        marker.debuggerAttached = true
        XCTAssertNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: current, launch: nil))
        marker.debuggerAttached = false
        XCTAssertNotNil(UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: true, current: current, launch: nil))

        let legacy = Data(#"{"activeDate":200,"build":"34","launchDate":100,"osVersion":"17.0","processID":77,"version":"1.2"}"#.utf8)
        let decoded = try XCTUnwrap(CrashJSON.decode(SessionMarker.self, from: legacy))
        XCTAssertNil(decoded.debuggerAttached)
        XCTAssertNotNil(UncleanExitDetector.report(marker: decoded, hasCrash: false, isEnabled: true, current: current, launch: nil))

        XCTAssertTrue([0, 1].contains(donk_crash_debugger_attached()))
    }

    func testExitHandlerRemovesTheSessionMarker() throws {
        let url = makeCrashTemporaryDirectory().appendingPathComponent("session.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(donk_crash_track_session_marker(url.path), 0)
        donk_crash_debug_remove_session_marker()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try Data("{}".utf8).write(to: url)
        donk_crash_track_session_marker(nil)
        donk_crash_debug_remove_session_marker()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Stripped builds

    func testImageHeaderAndDistantSymbolsAreShownAsUnsymbolicated() {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let previous = [RawImage(index: 0, loadAddress: 0x1_0000_0000, slide: 0, textSize: 0x10_0000, uuid: uuid, cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 2, path: "/old/Demo.app/Demo")]
        let loaded = [LoadedImage(loadAddress: 0x2_0000_0000, textSize: 0x10_0000, uuid: uuid, path: "/new/Demo.app/Demo", fileType: 2)]
        let symbolicator = Symbolicator(loaded: loaded, currentBundlePath: "/new/Demo.app") { address in
            switch address {
            case 0x2_0000_8000..<0x2_0000_9000:
                return ResolvedSymbol(name: "_mh_execute_header", start: 0x2_0000_0000)
            case 0x2_0003_0000..<0x2_0003_1000:
                return ResolvedSymbol(name: "$s4Demo3fooyyF", start: 0x2_0001_0000)
            case 0x2_0005_0000..<0x2_0005_1000:
                return ResolvedSymbol(name: "$s4Demo3baryyF", start: 0x2_0005_0000)
            default:
                return nil
            }
        }
        let index = ImageIndex(images: previous)

        let header = symbolicator.frame(index: 0, address: 0x1_0000_8010, isReturnAddress: false, images: index)
        XCTAssertNil(header.symbol)
        XCTAssertEqual(header.imageOffset, 0x8010)
        XCTAssertTrue(header.isUnsymbolicated)
        XCTAssertTrue(CrashTextFormatter.frameLine(header).hasSuffix("0x100000000 + 32784"))

        let distant = symbolicator.frame(index: 1, address: 0x1_0003_0010, isReturnAddress: true, images: index)
        XCTAssertNil(distant.symbol)
        XCTAssertTrue(distant.isUnsymbolicated)

        let near = symbolicator.frame(index: 2, address: 0x1_0005_0010, isReturnAddress: true, images: index)
        XCTAssertEqual(near.symbol, "Demo.bar() -> ()")
        XCTAssertEqual(near.symbolOffset, 0x10)
        XCTAssertFalse(near.isUnsymbolicated)

        var report = sampleReport(frames: [header, distant, near])
        report.binaryImages = [CrashBinaryImage(name: "Demo", path: "/old/Demo.app/Demo", loadAddress: 0x1_0000_0000, size: 0x10_0000, uuid: uuid, architecture: "arm64", isApp: true, isMainExecutable: true)]
        XCTAssertTrue(CrashTextFormatter.text(for: report).contains("App frames are unsymbolicated"))
    }
}
