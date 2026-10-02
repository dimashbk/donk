import XCTest
@testable import DonkCrash

final class TextReportTests: XCTestCase {
    func testAppleStyleSections() {
        let text = CrashTextFormatter.text(for: sampleReport())
        XCTAssertTrue(text.hasPrefix("Incident Identifier: 6A1B2C3D-0000-4000-8000-123456789ABC\n"))
        XCTAssertTrue(text.contains("Hardware Model:      iPhone15,2\n"))
        XCTAssertTrue(text.contains("Process:             DonkDemo [4242]\n"))
        XCTAssertTrue(text.contains("Path:                /private/var/containers/Bundle/Application/ABC/DonkDemo.app/DonkDemo\n"))
        XCTAssertTrue(text.contains("Identifier:          io.github.dimashbk.donkdemo\n"))
        XCTAssertTrue(text.contains("Version:             1.2 (34)\n"))
        XCTAssertTrue(text.contains("Code Type:           ARM-64 (Native)\n"))
        XCTAssertTrue(text.contains("OS Version:          iOS 17.0\n"))
        XCTAssertTrue(text.contains("Exception Type:  EXC_BAD_ACCESS (SIGSEGV)\n"))
        XCTAssertTrue(text.contains("Exception Subtype: KERN_INVALID_ADDRESS at 0x0000000000000010\n"))
        XCTAssertTrue(text.contains("Termination Reason: SIGNAL 11 Segmentation fault: 11\n"))
        XCTAssertTrue(text.contains("Application Specific Information:\nlibswiftCore.dylib: DonkDemo/CrashTriggers.swift:82: Fatal error: boom\n"))
        XCTAssertTrue(text.contains("Thread 0 name:  Dispatch queue: com.apple.main-thread\nThread 0 Crashed:\n"))
        XCTAssertTrue(text.contains("Thread 0 crashed with ARM Thread State (64-bit):\n      pc: 0x0000000190001000     lr: 0x0000000100001234\n"))
        XCTAssertTrue(text.hasSuffix("EOF\n"))
    }

    func testExceptionSubtypes() {
        XCTAssertEqual(CrashSignals.exceptionSubtype(signal: SIGSEGV, code: 1, faultAddress: 0x10), "KERN_INVALID_ADDRESS")
        XCTAssertEqual(CrashSignals.exceptionSubtype(signal: SIGSEGV, code: 2, faultAddress: 0x10), "KERN_INVALID_ADDRESS")
        XCTAssertEqual(CrashSignals.exceptionSubtype(signal: SIGSEGV, code: 2, faultAddress: 0x1_6D1A_3FC8), "KERN_PROTECTION_FAILURE")
        XCTAssertNil(CrashSignals.exceptionSubtype(signal: SIGTRAP, code: 1))
        XCTAssertEqual(CrashSignals.codeName(signal: SIGFPE, code: 7), "FPE_INTDIV")
        XCTAssertEqual(CrashSignals.codeName(signal: SIGBUS, code: 0x10001), "SI_USER")
        XCTAssertEqual(CrashSignals.machException(SIGILL), "EXC_BAD_INSTRUCTION")
    }

    func testFrameLines() {
        let report = sampleReport()
        XCTAssertEqual(
            CrashTextFormatter.frameLine(report.frames[1]),
            "1   DonkDemo                        \t0x0000000100001234 DonkDemo.DemoCrashes.callFatalError() -> Swift.Never + 52"
        )
        XCTAssertEqual(
            CrashTextFormatter.frameLine(report.frames[2]),
            "2   DonkDemo                        \t0x0000000100002000 0x100000000 + 8192"
        )
        XCTAssertEqual(
            CrashTextFormatter.frameLine(CrashFrame(index: 7, address: 0x42)),
            "7   ???                             \t0x0000000000000042 ???"
        )
    }

    func testBinaryImagesSectionWorksWithAtos() {
        let report = sampleReport()
        let text = CrashTextFormatter.text(for: report)
        XCTAssertTrue(text.contains("\nBinary Images:\n"))
        XCTAssertTrue(text.contains("       0x100000000 -        0x100007fff DonkDemo arm64  <11111111222233334444555555555555> /private/var/containers/Bundle/Application/ABC/DonkDemo.app/DonkDemo\n"))
        XCTAssertTrue(text.contains("       0x190000000 -        0x1903fffff libswiftCore.dylib arm64e  <aaaaaaaabbbbccccddddeeeeeeeeeeee> /usr/lib/swift/libswiftCore.dylib\n"))
        XCTAssertTrue(text.contains("(410 more loaded images omitted"))
        let command = "atos -o DonkDemo.app.dSYM/Contents/Resources/DWARF/DonkDemo -arch arm64 -l 0x100000000 0x100001234"
        XCTAssertEqual(CrashTextFormatter.atosCommand(for: report), command)
        XCTAssertTrue(text.contains(command + "\n"))
    }

    func testAtosCommandForFrameworkFrame() {
        let report = sampleReport()
        let frame = CrashFrame(index: 0, address: 0x1_9000_1000, imageName: "libswiftCore.dylib", imageLoadAddress: 0x1_9000_0000, imageOffset: 0x1000)
        XCTAssertEqual(
            CrashTextFormatter.atosCommand(for: report, frame: frame),
            "atos -o libswiftCore.dylib.dSYM/Contents/Resources/DWARF/libswiftCore.dylib -arch arm64e -l 0x190000000 0x190001000"
        )
    }

    func testExceptionReportSections() {
        var report = sampleReport(kind: .exception)
        report.exception = CrashReport.ExceptionInfo(name: "NSRangeException", reason: "index 5 beyond bounds [0 .. 2]", userInfo: [CrashDetail("key", "value")], symbols: [])
        report.signal = CrashReport.SignalInfo(number: SIGABRT, name: "SIGABRT", code: 0, codeName: nil, faultAddress: nil, machException: "EXC_CRASH")
        report.signalFrames = [CrashFrame(index: 0, address: 0x1_9000_2000, imageName: "libswiftCore.dylib", imageLoadAddress: 0x1_9000_0000, imageOffset: 0x2000, symbol: "__pthread_kill", symbolOffset: 8)]
        let text = CrashTextFormatter.text(for: report)
        XCTAssertTrue(text.contains("Exception Type:  EXC_CRASH (SIGABRT)\n"))
        XCTAssertTrue(text.contains("*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 5 beyond bounds [0 .. 2]'\n"))
        XCTAssertTrue(text.contains("userInfo[key]: value\n"))
        XCTAssertTrue(text.contains("Last Exception Backtrace:\n0   libswiftCore.dylib"))
        XCTAssertTrue(text.contains("Thread 0 Crashed:\n0   libswiftCore.dylib              \t0x0000000190002000 __pthread_kill + 8\n"))
        XCTAssertEqual(report.title, "NSRangeException")
        XCTAssertEqual(report.subtitle, "index 5 beyond bounds [0 .. 2]")
    }

    func testPresentationTitles() {
        let report = sampleReport()
        XCTAssertEqual(report.title, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(report.subtitle, "boom · CrashTriggers.swift:82")
        XCTAssertEqual(report.primaryMessage, "DonkDemo/CrashTriggers.swift:82: Fatal error: boom")
        XCTAssertEqual(report.topAppFrame?.index, 1)
        XCTAssertEqual(report.versionLabel, "1.2 (34)")

        var unclean = sampleReport(kind: .uncleanExit)
        unclean.crashInfo = []
        XCTAssertEqual(unclean.title, "Unclean exit")
        XCTAssertEqual(unclean.subtitle, CrashReport.uncleanExitExplanation)
        XCTAssertTrue(CrashTextFormatter.text(for: unclean).contains("Exception Type:  Unclean exit (no crash was recorded)"))
    }

    func testCondensedMessagesAndShortSymbols() {
        XCTAssertEqual(CrashReport.condensedMessage("Swift/ContiguousArrayBuffer.swift:691: Fatal error: Index out of range"), "Index out of range · ContiguousArrayBuffer.swift:691")
        XCTAssertEqual(CrashReport.condensedMessage("Fatal error: "), "Fatal error")
        XCTAssertEqual(CrashReport.condensedMessage("abort() called"), "abort() called")
        XCTAssertTrue(CrashReport.isEnvironmentNote("CoreSimulator 1048 - Device: iPhone 14 Plus"))
        XCTAssertTrue(CrashReport.isEnvironmentNote("dyld4 config: DYLD_LIBRARY_PATH=/usr/lib"))
        XCTAssertFalse(CrashReport.isEnvironmentNote("Fatal error: boom"))

        XCTAssertEqual(CrashSymbolFormatter.short("static DonkDemo.DemoCrashes.callFatalError() -> Swift.Never"), "DemoCrashes.callFatalError()")
        XCTAssertEqual(CrashSymbolFormatter.short("static DonkDemo.DemoCrashes.recurse(Swift.Int) -> Swift.Int"), "DemoCrashes.recurse(Int)")
        XCTAssertEqual(CrashSymbolFormatter.short("closure #1 @Swift.MainActor () -> () in static DonkDemo.CrashDemoLaunch.handleArguments() -> ()"), "closure in CrashDemoLaunch.handleArguments()")
        XCTAssertEqual(CrashSymbolFormatter.short("DonkDemo.Model.apply(_: (Swift.Int) -> Swift.Bool) -> ()"), "Model.apply(_: (Int) -> Bool)")
        XCTAssertEqual(CrashSymbolFormatter.short("-[NSArray objectAtIndex:]"), "-[NSArray objectAtIndex:]")
        XCTAssertEqual(CrashSymbolFormatter.short("main"), "main")
        XCTAssertEqual(
            CrashSymbolFormatter.short("closure #1 (Swift.UnsafeMutablePointer<Swift.Optional<Swift.UnsafeMutablePointer<Swift.Int8>>>) -> Swift.Never in SwiftUI.(KitRendererCommon in _ACC2C5639A7D76F611E170E831FCA491)(Swift.AnyObject.Type) -> Swift.Never"),
            "closure in SwiftUI.KitRendererCommon(AnyObject.Type)"
        )
        XCTAssertEqual(CrashSymbolFormatter.short("static (extension in SwiftUI):SwiftUI.App.main() -> ()"), "App.main()")
    }

    func testDaySections() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_050_000)
        let reports = [
            sampleReport(date: now),
            sampleReport(date: now.addingTimeInterval(-60)),
            sampleReport(date: now.addingTimeInterval(-86_400 * 3)),
        ].enumerated().map { offset, report -> CrashReport in
            var copy = report
            copy.id = UUID()
            copy.frames = [CrashFrame(index: offset, address: 1)]
            return copy
        }
        let sections = CrashDaySection.group(reports, calendar: calendar)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].reports.count, 2)
        XCTAssertEqual(CrashDayFormatter.title(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(CrashDayFormatter.title(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
    }
}
