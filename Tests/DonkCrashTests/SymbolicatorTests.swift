import XCTest
@testable import DonkCrash

final class SymbolicatorTests: XCTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"

    private func previousImages() -> [RawImage] {
        [
            RawImage(index: 0, loadAddress: 0x1_0000_0000, slide: 0, textSize: 0x10000, uuid: uuid, cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 2, path: "/old/Bundle/Demo.app/Demo"),
            RawImage(index: 1, loadAddress: 0x1_0002_0000, slide: 0, textSize: 0x4000, uuid: "99999999-2222-3333-4444-555555555555", cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 6, path: "/old/Bundle/Demo.app/Frameworks/Kit.framework/Kit"),
            RawImage(index: 2, loadAddress: 0x1_9000_0000, slide: 0, textSize: 0x40_0000, uuid: nil, cpuType: 0x0100_000C, cpuSubtype: 2, fileType: 6, path: "/usr/lib/libsystem_c.dylib"),
            RawImage(index: 3, loadAddress: 0x1_A000_0000, slide: 0, textSize: 0x1000, uuid: "77777777-2222-3333-4444-555555555555", cpuType: 0x0100_000C, cpuSubtype: 0, fileType: 6, path: "/usr/lib/libchanged.dylib"),
        ]
    }

    private func makeSymbolicator(lookups: LookupRecorder) -> Symbolicator {
        let loaded = [
            LoadedImage(loadAddress: 0x2_0000_0000, textSize: 0x10000, uuid: uuid, path: "/new/Bundle/Demo.app/Demo", fileType: 2),
            LoadedImage(loadAddress: 0x2_9000_0000, textSize: 0x40_0000, uuid: nil, path: "/usr/lib/libsystem_c.dylib", fileType: 6),
            LoadedImage(loadAddress: 0x2_A000_0000, textSize: 0x1000, uuid: "88888888-2222-3333-4444-555555555555", path: "/usr/lib/libchanged.dylib", fileType: 6),
        ]
        return Symbolicator(loaded: loaded, currentBundlePath: "/new/Bundle/Demo.app") { address in
            lookups.append(address)
            switch address {
            case 0x2_0000_1200..<0x2_0000_1300:
                return ResolvedSymbol(name: "$s4Demo3fooyyF", start: 0x2_0000_1200)
            case 0x2_9000_0000..<0x2_9000_0100:
                return ResolvedSymbol(name: "abort", start: 0x2_9000_0000)
            default:
                return nil
            }
        }
    }

    func testTranslatesAddressesAcrossASLRByUUID() {
        let lookups = LookupRecorder()
        let symbolicator = makeSymbolicator(lookups: lookups)
        let index = ImageIndex(images: previousImages())
        let image = index.image(containing: 0x1_0000_1234)
        XCTAssertEqual(image?.index, 0)
        XCTAssertEqual(image.flatMap { symbolicator.currentAddress(for: 0x1_0000_1234, in: $0) }, 0x2_0000_1234)

        let frame = symbolicator.frame(index: 0, address: 0x1_0000_1234, isReturnAddress: false, images: index)
        XCTAssertEqual(frame.imageName, "Demo")
        XCTAssertEqual(frame.imageLoadAddress, 0x1_0000_0000)
        XCTAssertEqual(frame.imageOffset, 0x1234)
        XCTAssertEqual(frame.symbol, "Demo.foo() -> ()")
        XCTAssertEqual(frame.symbolOffset, 0x34)
        XCTAssertTrue(frame.isAppFrame)
        XCTAssertEqual(lookups.values.last, 0x2_0000_1234)
    }

    func testReturnAddressesAreLookedUpOneByteEarlier() {
        let lookups = LookupRecorder()
        let symbolicator = makeSymbolicator(lookups: lookups)
        let index = ImageIndex(images: previousImages())
        let frame = symbolicator.frame(index: 3, address: 0x1_0000_1300, isReturnAddress: true, images: index)
        XCTAssertEqual(lookups.values.last, 0x2_0000_12FF)
        XCTAssertEqual(frame.symbol, "Demo.foo() -> ()")
        XCTAssertEqual(frame.symbolOffset, 0x100)
    }

    func testFallsBackToPathWhenUUIDIsMissing() {
        let symbolicator = makeSymbolicator(lookups: LookupRecorder())
        let index = ImageIndex(images: previousImages())
        let frame = symbolicator.frame(index: 0, address: 0x1_9000_0010, isReturnAddress: false, images: index)
        XCTAssertEqual(frame.symbol, "abort")
        XCTAssertEqual(frame.symbolOffset, 0x10)
        XCTAssertFalse(frame.isAppFrame)
    }

    func testDoesNotSymbolicateAgainstADifferentBuild() {
        let symbolicator = makeSymbolicator(lookups: LookupRecorder())
        let index = ImageIndex(images: previousImages())
        let frame = symbolicator.frame(index: 0, address: 0x1_A000_0010, isReturnAddress: false, images: index, fallbackSymbol: "fallback")
        XCTAssertEqual(frame.imageName, "libchanged.dylib")
        XCTAssertEqual(frame.imageOffset, 0x10)
        XCTAssertEqual(frame.symbol, "fallback")
        XCTAssertNil(frame.symbolOffset)
    }

    func testAppFramesIncludeEmbeddedFrameworks() {
        let index = ImageIndex(images: previousImages())
        let images = previousImages()
        XCTAssertTrue(index.isApp(images[0]))
        XCTAssertTrue(index.isApp(images[1]))
        XCTAssertFalse(index.isApp(images[2]))
    }

    func testAddressOutsideAnyImage() {
        let symbolicator = makeSymbolicator(lookups: LookupRecorder())
        let index = ImageIndex(images: previousImages())
        XCTAssertNil(index.image(containing: 0x1_0001_0000))
        XCTAssertNil(index.image(containing: 0x1000))
        let frame = symbolicator.frame(index: 0, address: 0x1000, isReturnAddress: false, images: index)
        XCTAssertNil(frame.imageName)
        XCTAssertNil(frame.symbol)
    }

    func testSwiftDemangling() {
        XCTAssertTrue(CrashDemangler.isSwiftDemanglerAvailable)
        XCTAssertEqual(CrashDemangler.demangle("$s4Demo3fooyyF"), "Demo.foo() -> ()")
        XCTAssertEqual(CrashDemangler.demangle("_$s4Demo3fooyyF"), "Demo.foo() -> ()")
        XCTAssertEqual(CrashDemangler.demangle("$sSS5countSivg"), "Swift.String.count.getter : Swift.Int")
        XCTAssertEqual(CrashDemangler.demangle("objc_msgSend"), "objc_msgSend")
        XCTAssertEqual(CrashDemangler.demangle("-[NSArray objectAtIndex:]"), "-[NSArray objectAtIndex:]")
        XCTAssertEqual(CrashDemangler.demangle("_ZN3foo3barEv"), "foo::bar()")
    }

    func testRealSwiftSymbolIsDemangledThroughDladdr() throws {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        let pointer = try XCTUnwrap(dlsym(handle, "$sSS5countSivg"))
        let address = UInt64(UInt(bitPattern: pointer))
        let resolved = try XCTUnwrap(Symbolicator.dladdrResolver(address))
        XCTAssertEqual(resolved.start, address)
        XCTAssertEqual(CrashDemangler.demangle(resolved.name), "Swift.String.count.getter : Swift.Int")
    }

    func testCallStackSymbolParsing() {
        let line = "3   DonkDemo                            0x0000000104a5c3c8 $s8DonkDemo11DemoCrashesO19raiseRangeExceptions5NeverOyFZ + 120"
        XCTAssertEqual(CrashDemangler.symbol(fromCallStackSymbol: line), "static DonkDemo.DemoCrashes.raiseRangeException() -> Swift.Never")
        XCTAssertEqual(CrashDemangler.symbol(fromCallStackSymbol: "0   CoreFoundation   0x0000000180431234 __exceptionPreprocess + 164"), "__exceptionPreprocess")
        XCTAssertNil(CrashDemangler.symbol(fromCallStackSymbol: "5   libsystem   0x0000000180431234 <redacted> + 1"))
    }

    func testCurrentImagesComeFromTheCTable() {
        let images = Symbolicator.currentImages()
        XCTAssertGreaterThan(images.count, 10)
        XCTAssertTrue(images.contains { $0.fileType == 2 })
        XCTAssertTrue(images.contains { $0.path.hasSuffix("libswiftCore.dylib") })
        XCTAssertTrue(images.filter { $0.fileType == 2 }.allSatisfy { $0.uuid != nil && $0.textSize > 0 })
    }
}

final class LookupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    func append(_ value: UInt64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
