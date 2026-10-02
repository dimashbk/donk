import DonkCrashC
import XCTest
@testable import DonkCrash

final class RawCrashParserTests: XCTestCase {
    private let golden = """
    donk-crash 1
    arch arm64
    signal 11
    code 1
    addr 0x10
    time 1700000123.456789
    pid 4242
    main 1
    thread 0x103
    pc 0x100001234
    lr 0x100001100
    fp 0x16fdff000
    sp 0x16fdfefe0
    esr 0x92000046
    far 0x10
    frame 0x100001234
    frame 0x100002000
    frame 0x190001000
    crashinfo 3 message Fatal error: boom\\nsecond line \\\\ tab\\there \\x01
    crashinfo 3 signature sig
    image 0 0x100000000 0x0 0x8000 11111111222233334444555555555555 16777228 0 2 /private/var/containers/Bundle/Application/ABC/My App.app/My App
    image 3 0x190000000 0x10000 0x400000 aaaaaaaabbbbccccddddeeeeeeeeeeee 16777228 2 6 /usr/lib/swift/libswiftCore.dylib
    image 4 0x1a0000000 0x0 0x1000 00000000000000000000000000000000 16777228 0 6
    threadname worker\\tone
    queue com.apple.main-thread
    end

    """

    func testParsesGoldenFile() throws {
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(golden.utf8)))
        XCTAssertEqual(raw.version, 1)
        XCTAssertEqual(raw.architecture, "arm64")
        XCTAssertEqual(raw.signal, SIGSEGV)
        XCTAssertEqual(raw.code, 1)
        XCTAssertEqual(raw.faultAddress, 0x10)
        XCTAssertEqual(raw.time?.timeIntervalSince1970 ?? 0, 1_700_000_123.456789, accuracy: 0.000_01)
        XCTAssertEqual(raw.processID, 4242)
        XCTAssertEqual(raw.isMainThread, true)
        XCTAssertEqual(raw.thread, 0x103)
        XCTAssertEqual(raw.pc, 0x1_0000_1234)
        XCTAssertEqual(raw.lr, 0x1_0000_1100)
        XCTAssertEqual(raw.esr, 0x9200_0046)
        XCTAssertEqual(raw.frames, [0x1_0000_1234, 0x1_0000_2000, 0x1_9000_1000])
        XCTAssertEqual(raw.crashInfo.count, 2)
        XCTAssertEqual(raw.crashInfo[0].imageIndex, 3)
        XCTAssertEqual(raw.crashInfo[0].field, "message")
        XCTAssertEqual(raw.crashInfo[0].text, "Fatal error: boom\nsecond line \\ tab\there \u{01}")
        XCTAssertEqual(raw.images.count, 3)
        XCTAssertEqual(raw.images[0].path, "/private/var/containers/Bundle/Application/ABC/My App.app/My App")
        XCTAssertEqual(raw.images[0].name, "My App")
        XCTAssertEqual(raw.images[0].uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertTrue(raw.images[0].isMainExecutable)
        XCTAssertEqual(raw.images[1].slide, 0x10000)
        XCTAssertEqual(raw.images[1].architecture, "arm64e")
        XCTAssertEqual(raw.images[1].textSize, 0x40_0000)
        XCTAssertNil(raw.images[2].uuid)
        XCTAssertEqual(raw.images[2].path, "")
        XCTAssertEqual(raw.threadName, "worker\tone")
        XCTAssertEqual(raw.queue, "com.apple.main-thread")
        XCTAssertTrue(raw.isComplete)
    }

    func testRejectsForeignAndEmptyData() {
        XCTAssertNil(RawCrashParser.parse(Data()))
        XCTAssertNil(RawCrashParser.parse(Data("hello world\nsignal 11\n".utf8)))
        XCTAssertNil(RawCrashParser.parse(Data("donk-crash 1\narch arm64\n".utf8)))
    }

    func testTruncatedFileIsMarkedIncomplete() throws {
        let truncated = golden.components(separatedBy: "crashinfo")[0]
        let raw = try XCTUnwrap(RawCrashParser.parse(Data(truncated.utf8)))
        XCTAssertFalse(raw.isComplete)
        XCTAssertEqual(raw.frames.count, 3)
        XCTAssertTrue(raw.images.isEmpty)
    }

    func testSyntheticReportFromCWriter() throws {
        let directory = makeCrashTemporaryDirectory()
        let url = directory.appendingPathComponent("pending.donkcrash")
        let first = cFunctionAddress(donk_crash_is_installed)
        let second = UInt64(UInt(bitPattern: unsafeBitCast(donk_crash_image_count as @convention(c) () -> Int, to: UnsafeRawPointer.self)))
        let third = UInt64(UInt(bitPattern: unsafeBitCast(donk_crash_address_mask as @convention(c) () -> UInt64, to: UnsafeRawPointer.self)))
        let data = writeSyntheticRawReport(
            to: url,
            signal: SIGSEGV,
            code: 2,
            faultAddress: 0xDEAD_0000,
            pc: first + 4,
            lr: second + 8,
            returnAddresses: [second + 8, third + 12],
            message: "Fatal error: synthetic\nsecond line"
        )
        let raw = try XCTUnwrap(RawCrashParser.parse(data))
        XCTAssertEqual(raw.signal, SIGSEGV)
        XCTAssertEqual(raw.code, 2)
        XCTAssertEqual(raw.faultAddress, 0xDEAD_0000)
        XCTAssertEqual(raw.frames, [first + 4, second + 8, third + 12])
        XCTAssertTrue(raw.isComplete)
        XCTAssertEqual(raw.processID, getpid())
        XCTAssertTrue(raw.crashInfo.contains { $0.imageIndex == -1 && $0.text == "Fatal error: synthetic\nsecond line" })
        XCTAssertGreaterThan(raw.images.count, 10)
        XCTAssertTrue(raw.images.contains { $0.isMainExecutable })

        let builder = CrashReportBuilder(symbolicator: Symbolicator(), fallbackLaunch: testLaunchInfo())
        let report = try XCTUnwrap(builder.build(raw: raw, exception: nil, launch: nil))
        XCTAssertEqual(report.kind, .signal)
        XCTAssertEqual(report.title, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(report.signal?.codeName, "SEGV_ACCERR")
        XCTAssertEqual(report.signal?.faultAddress, 0xDEAD_0000)
        XCTAssertEqual(report.frames.count, 3)
        XCTAssertEqual(report.frames[0].symbol, "donk_crash_is_installed")
        XCTAssertEqual(report.frames[0].symbolOffset, 4)
        XCTAssertEqual(report.frames[1].symbol, "donk_crash_image_count")
        XCTAssertEqual(report.frames[2].symbol, "donk_crash_address_mask")
        XCTAssertEqual(report.frames[2].symbolOffset, 12)
        XCTAssertNotNil(report.frames[0].imageName)
        XCTAssertEqual(report.primaryMessage, "Fatal error: synthetic\nsecond line")
        XCTAssertTrue(report.binaryImages.contains { $0.loadAddress == report.frames[0].imageLoadAddress })
    }

    func testLinkRegisterIsInsertedOnlyForLeafFunctions() throws {
        let directory = makeCrashTemporaryDirectory()
        let url = directory.appendingPathComponent("pending.donkcrash")
        let leaf = cFunctionAddress(donk_crash_is_installed)
        let caller = UInt64(UInt(bitPattern: unsafeBitCast(donk_crash_image_count as @convention(c) () -> Int, to: UnsafeRawPointer.self)))
        let grandCaller = UInt64(UInt(bitPattern: unsafeBitCast(donk_crash_address_mask as @convention(c) () -> UInt64, to: UnsafeRawPointer.self)))
        let builder = CrashReportBuilder(symbolicator: Symbolicator(), fallbackLaunch: testLaunchInfo())

        let leafData = writeSyntheticRawReport(to: url, signal: SIGTRAP, code: 1, faultAddress: 0, pc: leaf + 4, lr: caller + 8, returnAddresses: [grandCaller + 8], message: nil)
        let leafReport = try XCTUnwrap(builder.build(raw: XCTUnwrap(RawCrashParser.parse(leafData)), exception: nil, launch: nil))
        XCTAssertEqual(leafReport.frames.map(\.symbol), ["donk_crash_is_installed", "donk_crash_image_count", "donk_crash_address_mask"])

        let innerData = writeSyntheticRawReport(to: url, signal: SIGTRAP, code: 1, faultAddress: 0, pc: leaf + 4, lr: leaf + 8, returnAddresses: [grandCaller + 8], message: nil)
        let innerReport = try XCTUnwrap(builder.build(raw: XCTUnwrap(RawCrashParser.parse(innerData)), exception: nil, launch: nil))
        XCTAssertEqual(innerReport.frames.map(\.symbol), ["donk_crash_is_installed", "donk_crash_address_mask"])

        let duplicateData = writeSyntheticRawReport(to: url, signal: SIGTRAP, code: 1, faultAddress: 0, pc: leaf + 4, lr: grandCaller + 8, returnAddresses: [grandCaller + 8], message: nil)
        let duplicateReport = try XCTUnwrap(builder.build(raw: XCTUnwrap(RawCrashParser.parse(duplicateData)), exception: nil, launch: nil))
        XCTAssertEqual(duplicateReport.frames.count, 2)
    }

    func testUnescapeHandlesAllSequences() {
        XCTAssertEqual(RawCrashParser.unescape(Array("a\\nb\\rc\\td\\\\e\\x41\\q".utf8)), "a\nb\rc\td\\eA\\q")
        XCTAssertEqual(RawCrashParser.unescape(Array("trailing\\".utf8)), "trailing\\")
        XCTAssertEqual(RawCrashParser.unescape(Array("Кириллица ✓".utf8)), "Кириллица ✓")
    }
}
