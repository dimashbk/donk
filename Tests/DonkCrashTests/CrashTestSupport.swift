import DonkCrashC
import Foundation
import XCTest
@testable import DonkCrash

func makeCrashTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("donk-crash-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        XCTFail("cannot create temp directory: \(error)", file: file, line: line)
    }
    return url
}

func testLaunchInfo(version: String = "1.2", build: String = "34", os: String = "17.0", pid: Int32 = 4242) -> LaunchInfo {
    LaunchInfo(
        appName: "DonkDemo",
        bundleID: "io.github.dimashbk.donkdemo",
        version: version,
        build: build,
        osVersion: os,
        deviceModel: "iPhone15,2",
        launchDate: Date(timeIntervalSince1970: 1_700_000_000),
        processID: pid,
        bundlePath: "/private/var/containers/Bundle/Application/ABC/DonkDemo.app"
    )
}

func sampleReport(
    kind: CrashReport.Kind = .signal,
    date: Date = Date(timeIntervalSince1970: 1_700_000_100),
    frames: [CrashFrame]? = nil
) -> CrashReport {
    let images = [
        CrashBinaryImage(
            name: "DonkDemo",
            path: "/private/var/containers/Bundle/Application/ABC/DonkDemo.app/DonkDemo",
            loadAddress: 0x1_0000_0000,
            size: 0x8000,
            uuid: "11111111-2222-3333-4444-555555555555",
            architecture: "arm64",
            isApp: true,
            isMainExecutable: true
        ),
        CrashBinaryImage(
            name: "libswiftCore.dylib",
            path: "/usr/lib/swift/libswiftCore.dylib",
            loadAddress: 0x1_9000_0000,
            size: 0x40_0000,
            uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            architecture: "arm64e",
            isApp: false,
            isMainExecutable: false
        ),
    ]
    let defaultFrames = [
        CrashFrame(index: 0, address: 0x1_9000_1000, imageName: "libswiftCore.dylib", imageLoadAddress: 0x1_9000_0000, imageOffset: 0x1000, symbol: "Swift._assertionFailure(_:_:file:line:flags:) -> Swift.Never", symbolOffset: 196),
        CrashFrame(index: 1, address: 0x1_0000_1234, imageName: "DonkDemo", imageLoadAddress: 0x1_0000_0000, imageOffset: 0x1234, symbol: "DonkDemo.DemoCrashes.callFatalError() -> Swift.Never", symbolOffset: 52, isAppFrame: true),
        CrashFrame(index: 2, address: 0x1_0000_2000, imageName: "DonkDemo", imageLoadAddress: 0x1_0000_0000, imageOffset: 0x2000, isAppFrame: true),
    ]
    return CrashReport(
        id: UUID(uuidString: "6A1B2C3D-0000-4000-8000-123456789ABC") ?? UUID(),
        date: date,
        kind: kind,
        appName: "DonkDemo",
        bundleID: "io.github.dimashbk.donkdemo",
        appVersion: "1.2",
        appBuild: "34",
        osVersion: "17.0",
        deviceModel: "iPhone15,2",
        architecture: "arm64",
        processID: 4242,
        launchDate: Date(timeIntervalSince1970: 1_700_000_000),
        signal: kind == .signal ? CrashReport.SignalInfo(number: SIGSEGV, name: "SIGSEGV", code: 1, codeName: "SEGV_MAPERR", faultAddress: 0x10, machException: "EXC_BAD_ACCESS") : nil,
        crashInfo: [CrashInfoMessage(imageName: "libswiftCore.dylib", field: "message", text: "DonkDemo/CrashTriggers.swift:82: Fatal error: boom\n")],
        threadName: nil,
        isMainThread: true,
        frames: frames ?? defaultFrames,
        registers: [CrashDetail("pc", "0x0000000190001000"), CrashDetail("lr", "0x0000000100001234")],
        binaryImages: images,
        loadedImageCount: 412
    )
}

final class FakeFrameStack {
    let memory: UnsafeMutablePointer<UInt64>
    let returnAddresses: [UInt64]

    init(returnAddresses: [UInt64]) {
        self.returnAddresses = returnAddresses
        let count = returnAddresses.count * 2 + 2
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count * 8, alignment: 16)
        memory = raw.bindMemory(to: UInt64.self, capacity: count)
        memory.initialize(repeating: 0, count: count)
        for (index, address) in returnAddresses.enumerated() {
            let record = memory + index * 2
            let isLast = index == returnAddresses.count - 1
            record[0] = isLast ? 0 : UInt64(UInt(bitPattern: memory + (index + 1) * 2))
            record[1] = address
        }
    }

    var framePointer: UInt64 { UInt64(UInt(bitPattern: memory)) }

    deinit {
        UnsafeMutableRawPointer(memory).deallocate()
    }
}

final class FakeAnnotations {
    let message: UnsafeMutablePointer<CChar>
    let storage: UnsafeMutablePointer<UInt64>

    init(message text: String) {
        message = strdup(text)
        storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 8)
        storage.initialize(repeating: 0, count: 8)
        storage[0] = 5
        storage[1] = UInt64(UInt(bitPattern: message))
    }

    var pointer: UnsafeRawPointer { UnsafeRawPointer(storage) }

    deinit {
        free(message)
        storage.deallocate()
    }
}

func cFunctionAddress(_ function: @convention(c) () -> Int32) -> UInt64 {
    UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
}

func writeSyntheticRawReport(to url: URL, signal: Int32, code: Int32, faultAddress: UInt64, pc: UInt64, lr: UInt64, returnAddresses: [UInt64], message: String?) -> Data {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_WRONLY)
    defer { close(fd) }
    let stack = FakeFrameStack(returnAddresses: returnAddresses)
    let annotations = message.map(FakeAnnotations.init(message:))
    donk_crash_debug_write_report(fd, signal, code, faultAddress, pc, lr, stack.framePointer, stack.framePointer, annotations?.pointer)
    withExtendedLifetime((stack, annotations)) {}
    return (try? Data(contentsOf: url)) ?? Data()
}
