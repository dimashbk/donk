import DonkCrashC
import XCTest
@testable import DonkCrash

private var chainedSignalNumber: Int32 = 0
private var chainedSignalCount = 0

private let dummyHandler: @convention(c) (Int32) -> Void = { signal in
    chainedSignalNumber = signal
    chainedSignalCount += 1
}

private var laterReporterPrevious = sigaction()
private var laterReporterCount = 0
private var laterReporterActive = false
private var laterReporterRegainedControl = false
private var signalPendingAfterDonk = false
private var signalBlockedAfterDonk = false
private var deliveredAfterReporterCount = 0
private var deliveredWhileReporterActive = false

private let deliveredAfterReporter: @convention(c) (Int32) -> Void = { _ in
    deliveredAfterReporterCount += 1
    if laterReporterActive {
        deliveredWhileReporterActive = true
    }
}

private func crashlyticsStyleEntry(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    var reset = sigaction()
    sigemptyset(&reset.sa_mask)
    sigaction(signal, &reset, nil)
    var everything = sigset_t()
    sigfillset(&everything)
    sigprocmask(SIG_UNBLOCK, &everything, nil)
    sigaction(signal, &laterReporterPrevious, nil)
    laterReporterPrevious.__sigaction_u.__sa_sigaction?(signal, info, context)
}

private let laterReporter: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    laterReporterCount += 1
    crashlyticsStyleEntry(signal, info, context)
}

private let inspectingLaterReporter: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    laterReporterCount += 1
    laterReporterActive = true
    crashlyticsStyleEntry(signal, info, context)
    laterReporterRegainedControl = true
    var pending = sigset_t()
    sigpending(&pending)
    signalPendingAfterDonk = sigismember(&pending, signal) == 1
    var mask = sigset_t()
    pthread_sigmask(SIG_BLOCK, nil, &mask)
    signalBlockedAfterDonk = sigismember(&mask, signal) == 1
    var defuse = sigaction()
    defuse.__sigaction_u.__sa_handler = deliveredAfterReporter
    sigemptyset(&defuse.sa_mask)
    sigaction(signal, &defuse, nil)
    laterReporterActive = false
}

private var forkedPipe: Int32 = -1

private let forkedLaterReporter: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    crashlyticsStyleEntry(signal, info, context)
    var marker: UInt8 = 0x52
    _ = write(forkedPipe, &marker, 1)
}

private typealias ForkFunction = @convention(c) () -> pid_t

private let forkFunction: ForkFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else { return nil }
    return unsafeBitCast(symbol, to: ForkFunction.self)
}()

final class SignalChainTests: XCTestCase {
    private var savedActions: [Int32: sigaction] = [:]

    override func setUp() {
        super.setUp()
        donk_crash_uninstall()
        donk_crash_debug_reset_guard()
        chainedSignalNumber = 0
        chainedSignalCount = 0
        laterReporterCount = 0
        laterReporterActive = false
        laterReporterRegainedControl = false
        signalPendingAfterDonk = false
        signalBlockedAfterDonk = false
        deliveredAfterReporterCount = 0
        deliveredWhileReporterActive = false
        for signal in allSignals() + [SIGPIPE] {
            var action = sigaction()
            sigaction(signal, nil, &action)
            savedActions[signal] = action
        }
    }

    override func tearDown() {
        donk_crash_uninstall()
        donk_crash_debug_reset_guard()
        for (signal, action) in savedActions {
            var copy = action
            sigaction(signal, &copy, nil)
        }
        super.tearDown()
    }

    private func allSignals() -> [Int32] {
        var count = 0
        let pointer = donk_crash_signals(&count)
        return (0..<count).map { pointer[$0] }
    }

    private func installDummy(on signal: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = dummyHandler
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(signal, &action, nil)
    }

    private var dummyAddress: UnsafeMutableRawPointer {
        unsafeBitCast(dummyHandler, to: UnsafeMutableRawPointer.self)
    }

    func testHandledSignalsMatchCrashlytics() {
        XCTAssertEqual(Set(allSignals()), [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP])
    }

    func testInstallSavesPreviousActionsAndLeavesSIGPIPEAlone() throws {
        installDummy(on: SIGBUS)
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        let exception = directory.appendingPathComponent("exception")
        let pipeBefore = donk_crash_current_handler(SIGPIPE)

        XCTAssertEqual(donk_crash_install(pending.path, exception.path), 0)
        XCTAssertEqual(donk_crash_is_installed(), 1)
        XCTAssertEqual(donk_crash_install(pending.path, exception.path), 0)

        for signal in allSignals() {
            XCTAssertEqual(donk_crash_current_handler(signal), donk_crash_handler_address(), "signal \(signal)")
        }
        XCTAssertEqual(donk_crash_current_handler(SIGPIPE), pipeBefore)

        var previous = sigaction()
        XCTAssertEqual(donk_crash_previous_action(SIGBUS, &previous), 1)
        let previousHandler = previous.__sigaction_u.__sa_handler.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        XCTAssertEqual(previousHandler, dummyAddress)
        XCTAssertEqual(previous.sa_flags & SA_SIGINFO, 0)

        var current = sigaction()
        sigaction(SIGSEGV, nil, &current)
        XCTAssertEqual(current.sa_flags & (SA_SIGINFO | SA_ONSTACK), SA_SIGINFO | SA_ONSTACK)
        XCTAssertEqual(donk_crash_installed_after_other_handler(), 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(try Data(contentsOf: pending).count, 0)

        donk_crash_uninstall()
        XCTAssertEqual(donk_crash_is_installed(), 0)
        XCTAssertEqual(donk_crash_current_handler(SIGBUS), dummyAddress)
    }

    func testRaisedSignalIsRecordedAndChainedToThePreviousHandler() throws {
        installDummy(on: SIGBUS)
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)

        raise(SIGBUS)

        XCTAssertEqual(chainedSignalNumber, SIGBUS)
        XCTAssertEqual(chainedSignalCount, 1)
        XCTAssertEqual(donk_crash_current_handler(SIGBUS), dummyAddress)

        let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: pending)))
        XCTAssertEqual(raw.signal, SIGBUS)
        XCTAssertTrue(raw.isComplete)
        XCTAssertEqual(raw.isMainThread, Thread.isMainThread)
        XCTAssertNotNil(raw.pc)
        XCTAssertGreaterThan(raw.frames.count, 3)

        let builder = CrashReportBuilder(symbolicator: Symbolicator(), fallbackLaunch: testLaunchInfo())
        let report = try XCTUnwrap(builder.build(raw: raw, exception: nil, launch: nil))
        let symbols = report.frames.compactMap(\.symbol)
        XCTAssertTrue(symbols.contains { $0.contains("testRaisedSignalIsRecordedAndChainedToThePreviousHandler") }, symbols.joined(separator: "\n"))
        XCTAssertTrue(report.frames.contains { $0.imageName == "libsystem_kernel.dylib" || $0.imageName == "libsystem_c.dylib" || $0.imageName == "libsystem_pthread.dylib" })

        raise(SIGBUS)
        XCTAssertEqual(chainedSignalCount, 2)
    }

    private func installLaterReporter(_ handler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void, on signal: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = handler
        action.sa_flags = SA_SIGINFO | SA_ONSTACK
        sigemptyset(&action.sa_mask)
        sigaction(signal, &action, &laterReporterPrevious)
        let saved = laterReporterPrevious.__sigaction_u.__sa_sigaction.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        XCTAssertEqual(saved, donk_crash_handler_address())
    }

    private func installDefault(on signal: Int32) {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        sigaction(signal, &action, nil)
    }

    func testReporterInstalledAfterDonkCallsDonkDirectlyAndDonkChains() throws {
        installDummy(on: SIGBUS)
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)
        installLaterReporter(laterReporter, on: SIGBUS)

        raise(SIGBUS)

        XCTAssertEqual(laterReporterCount, 1)
        XCTAssertEqual(chainedSignalCount, 1)
        XCTAssertEqual(donk_crash_current_handler(SIGBUS), dummyAddress)
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: pending)))
        XCTAssertEqual(raw.signal, SIGBUS)
        XCTAssertTrue(raw.isComplete)
    }

    func testSoftwareSignalUnderCrashlyticsStyleReporterIsDeliveredOnlyAfterTheReporterReturns() throws {
        for signal in allSignals() {
            installDefault(on: signal)
        }
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)

        for signal in allSignals() {
            donk_crash_debug_reset_guard()
            laterReporterCount = 0
            laterReporterRegainedControl = false
            signalPendingAfterDonk = false
            signalBlockedAfterDonk = false
            deliveredAfterReporterCount = 0
            deliveredWhileReporterActive = false
            installLaterReporter(inspectingLaterReporter, on: signal)

            raise(signal)

            let name = CrashSignals.name(signal)
            XCTAssertEqual(laterReporterCount, 1, name)
            XCTAssertTrue(laterReporterRegainedControl, "\(name): donk terminated inside its own frames instead of returning")
            XCTAssertTrue(signalPendingAfterDonk, "\(name): donk must leave the re-raised signal pending")
            XCTAssertTrue(signalBlockedAfterDonk, "\(name): donk must block the re-raised signal until the outer sigreturn")
            XCTAssertEqual(deliveredAfterReporterCount, 1, name)
            XCTAssertFalse(deliveredWhileReporterActive, name)
            var mask = sigset_t()
            pthread_sigmask(SIG_BLOCK, nil, &mask)
            XCTAssertEqual(sigismember(&mask, signal), 0, "\(name): the original mask is restored after the outer handler returns")
            let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: pending)), name)
            XCTAssertEqual(raw.signal, signal)
            XCTAssertTrue(raw.isComplete, name)
        }
    }

    func testAbortUnderCrashlyticsStyleReporterTerminatesAfterTheReporterReturns() throws {
        let fork = try XCTUnwrap(forkFunction)
        installDefault(on: SIGABRT)
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        forkedPipe = descriptors[1]
        _ = forkedLaterReporter
        _ = crashlyticsStyleEntry

        let child = fork()
        if child == 0 {
            close(descriptors[0])
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = forkedLaterReporter
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(SIGABRT, &action, &laterReporterPrevious)
            raise(SIGABRT)
            var survived: UInt8 = 0x53
            _ = write(forkedPipe, &survived, 1)
            _exit(0)
        }
        close(descriptors[1])
        XCTAssertGreaterThan(child, 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child, &status, 0), child)
        var output: [UInt8] = []
        var byte: UInt8 = 0
        while read(descriptors[0], &byte, 1) == 1 {
            output.append(byte)
        }
        close(descriptors[0])

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "R", "R = the reporter regained control after donk returned; S = the process survived")
        let terminationSignal = status & 0x7F
        XCTAssertEqual(terminationSignal, SIGABRT, "child status \(status)")
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: pending)))
        XCTAssertEqual(raw.signal, SIGABRT)
        XCTAssertTrue(raw.isComplete)
    }

    func testInstallDetectsAReporterInstalledEarlier() {
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        installDummy(on: SIGSEGV)
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)
        XCTAssertEqual(donk_crash_installed_after_other_handler(), 1)
        donk_crash_uninstall()
        XCTAssertEqual(donk_crash_installed_after_other_handler(), 0)

        installDefault(on: SIGSEGV)
        installDummy(on: SIGTRAP)
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)
        XCTAssertEqual(donk_crash_installed_after_other_handler(), 1)
        donk_crash_uninstall()

        installDefault(on: SIGTRAP)
        installDummy(on: SIGBUS)
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGSEGV, &ignore, nil)
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)
        XCTAssertEqual(donk_crash_installed_after_other_handler(), 0)
    }

    func testHandlersAreInstalledAndChainEvenWhenTheRecordCannotBeOpened() throws {
        installDummy(on: SIGBUS)
        let directory = makeCrashTemporaryDirectory()
        let missing = directory.appendingPathComponent("missing/pending")
        XCTAssertEqual(donk_crash_install(missing.path, nil), 1)
        XCTAssertEqual(donk_crash_is_installed(), 1)
        XCTAssertEqual(donk_crash_current_handler(SIGBUS), donk_crash_handler_address())

        raise(SIGBUS)
        XCTAssertEqual(chainedSignalCount, 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(donk_crash_open_records(missing.path, nil), 0)
        var donkAction = sigaction()
        donkAction.__sigaction_u.__sa_sigaction = unsafeBitCast(donk_crash_handler_address(), to: (@convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void).self)
        donkAction.sa_flags = SA_SIGINFO | SA_ONSTACK
        sigemptyset(&donkAction.sa_mask)
        sigaction(SIGBUS, &donkAction, nil)
        donk_crash_debug_reset_guard()
        raise(SIGBUS)
        XCTAssertEqual(chainedSignalCount, 2)
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: missing)))
        XCTAssertEqual(raw.signal, SIGBUS)
    }

    func testSecondCrashDoesNotOverwriteTheFirstRecord() throws {
        installDummy(on: SIGBUS)
        installDummy(on: SIGILL)
        let directory = makeCrashTemporaryDirectory()
        let pending = directory.appendingPathComponent("pending")
        XCTAssertEqual(donk_crash_install(pending.path, nil), 0)

        raise(SIGBUS)
        raise(SIGILL)

        XCTAssertEqual(chainedSignalCount, 2)
        XCTAssertEqual(chainedSignalNumber, SIGILL)
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(contentsOf: pending)))
        XCTAssertEqual(raw.signal, SIGBUS)
    }

    func testExceptionFileIsWrittenThroughTheInstalledDescriptor() throws {
        let directory = makeCrashTemporaryDirectory()
        let exception = directory.appendingPathComponent("exception")
        XCTAssertEqual(donk_crash_install(nil, exception.path), 0)
        let first = Data(String(repeating: "a", count: 100).utf8)
        let second = Data("short".utf8)
        first.withUnsafeBytes { XCTAssertEqual(donk_crash_write_exception($0.baseAddress!, $0.count), 0) }
        second.withUnsafeBytes { XCTAssertEqual(donk_crash_write_exception($0.baseAddress!, $0.count), 0) }
        XCTAssertEqual(try Data(contentsOf: exception), second)
    }
}
