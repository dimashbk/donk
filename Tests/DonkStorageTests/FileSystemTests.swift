import XCTest
@testable import DonkStorage

final class FileSystemTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("donk-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testListingWithSizesAndSorting() throws {
        let manager = FileManager.default
        try write("b.txt", bytes: 300, modified: Date(timeIntervalSince1970: 3_000))
        try write("A.json", bytes: 10, modified: Date(timeIntervalSince1970: 1_000))
        try write("c10.log", bytes: 50, modified: Date(timeIntervalSince1970: 2_000))
        try write("c9.log", bytes: 60, modified: Date(timeIntervalSince1970: 4_000))
        try write(".hidden", bytes: 5, modified: Date(timeIntervalSince1970: 5_000))
        let big = root.appendingPathComponent("big", isDirectory: true)
        let small = root.appendingPathComponent("small", isDirectory: true)
        try manager.createDirectory(at: big.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try manager.createDirectory(at: small, withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: big.appendingPathComponent("nested/payload.bin"))
        try Data(count: 1_000).write(to: big.appendingPathComponent("top.bin"))
        try Data(count: 20).write(to: small.appendingPathComponent("tiny.bin"))

        let items = try DirectoryListing.list(root)
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first { $0.name == ".hidden" }?.isHidden, true)
        XCTAssertEqual(items.first { $0.name == "b.txt" }?.size, 300)
        XCTAssertEqual(items.first { $0.name == "big" }?.isDirectory, true)
        XCTAssertNil(items.first { $0.name == "big" }?.size)
        XCTAssertEqual(items.first { $0.name == "A.json" }?.kind, .json)

        let visible = DirectoryListing.filtered(items, query: "", includeHidden: false)
        XCTAssertEqual(visible.count, 6)
        XCTAssertEqual(DirectoryListing.filtered(items, query: "LOG", includeHidden: false).map(\.name).sorted(), ["c10.log", "c9.log"])

        let byName = DirectoryListing.sorted(visible, by: FileSort(field: .name, ascending: true))
        XCTAssertEqual(byName.map(\.name), ["big", "small", "A.json", "b.txt", "c9.log", "c10.log"])

        let byNameDescending = DirectoryListing.sorted(visible, by: FileSort(field: .name, ascending: false))
        XCTAssertEqual(byNameDescending.map(\.name), ["small", "big", "c10.log", "c9.log", "b.txt", "A.json"])

        let bigSize = FolderSizeCache.computeSize(of: big)
        let smallSize = FolderSizeCache.computeSize(of: small)
        XCTAssertEqual(bigSize, 5_000)
        XCTAssertEqual(smallSize, 20)

        let sizes = [big.path: bigSize, small.path: smallSize]
        let bySize = DirectoryListing.sorted(visible, by: FileSort(field: .size, ascending: false), folderSizes: sizes)
        XCTAssertEqual(bySize.map(\.name), ["big", "small", "b.txt", "c9.log", "c10.log", "A.json"])

        let byDate = DirectoryListing.sorted(visible.filter { !$0.isDirectory }, by: FileSort(field: .date, ascending: false))
        XCTAssertEqual(byDate.map(\.name), ["c9.log", "b.txt", "c10.log", "A.json"])
    }

    func testFolderSizeCacheComputesAndInvalidates() async throws {
        let folder = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 128).write(to: folder.appendingPathComponent("a.bin"))
        let cache = FolderSizeCache()
        let first = await cache.size(of: folder)
        XCTAssertEqual(first, 128)
        XCTAssertEqual(cache.cachedSize(of: folder), 128)
        try Data(count: 64).write(to: folder.appendingPathComponent("b.bin"))
        XCTAssertEqual(cache.cachedSize(of: folder), 128)
        cache.invalidate(folder.appendingPathComponent("b.bin"))
        XCTAssertNil(cache.cachedSize(of: folder))
        let second = await cache.size(of: folder)
        XCTAssertEqual(second, 192)
    }

    func testListingPerformanceWithManyFiles() throws {
        for index in 0..<1_500 {
            try Data("file \(index)".utf8).write(to: root.appendingPathComponent("file-\(index).txt"))
        }
        measure {
            let items = (try? DirectoryListing.list(root)) ?? []
            let sorted = DirectoryListing.sorted(items, by: FileSort(field: .name, ascending: true))
            XCTAssertEqual(sorted.count, 1_500)
        }
    }

    func testTextFileSaveIsAtomicAndKeepsPermissions() throws {
        let url = root.appendingPathComponent("notes.txt")
        try FileOperations.writeText("first", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileOperations.writeText("second ✓\nline", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second ✓\nline")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, ["notes.txt"])
    }

    func testCreateRenameDelete() throws {
        let folder = try FileOperations.createFolder(named: "Folder", in: root)
        XCTAssertThrowsError(try FileOperations.createFolder(named: "Folder", in: root))
        let file = try FileOperations.createTextFile(named: "draft.txt", in: folder)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "")
        XCTAssertThrowsError(try FileOperations.createTextFile(named: "draft.txt", in: folder))
        let renamed = try FileOperations.rename(file, to: "final.md")
        XCTAssertEqual(renamed.lastPathComponent, "final.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let caseChange = try FileOperations.rename(renamed, to: "FINAL.md")
        XCTAssertEqual(caseChange.lastPathComponent, "FINAL.md")
        try FileOperations.delete(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNotNil(FileOperations.validateName(""))
        XCTAssertNotNil(FileOperations.validateName("a/b"))
        XCTAssertNotNil(FileOperations.validateName(".."))
        XCTAssertNil(FileOperations.validateName("ok.txt"))
    }

    func testKindDetectionByContent() throws {
        try write("data", contents: Data(#"  {"a": 1}"#.utf8))
        try write("plain", contents: Data("hello world".utf8))
        try write("image.bin", contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        try write("binary", contents: Data([0x00, 0x01, 0x02, 0xFF]))
        try write("prefs", contents: try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0))
        try write("prefs.xml", contents: try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0))
        try write("empty.db", contents: Data())
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("data")), .json)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("plain")), .text)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("image.bin")), .image)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("binary")), .binary)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("prefs")), .plist)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("prefs.xml")), .plist)
        XCTAssertEqual(FileKind.detect(url: root.appendingPathComponent("empty.db")), .text)
        XCTAssertEqual(FilePreviewRoute.route(for: .json, size: 10), .text(json: true))
        XCTAssertEqual(FilePreviewRoute.route(for: .text, size: FilePreviewRoute.textLimit + 1), .hex)
        XCTAssertEqual(FilePreviewRoute.route(for: .pdf, size: 10), .quickLook)
    }

    func testHexDump() {
        let dump = HexDump.dump(Data(Array("ABCDEFGHIJKLMNOPQ".utf8)))
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), "0000  41 42 43 44 45 46 47 48  49 4a 4b 4c 4d 4e 4f 50  |ABCDEFGHIJKLMNOP|")
        XCTAssertTrue(lines[1].hasPrefix("0010  51 "))
        XCTAssertTrue(lines[1].hasSuffix("|Q|"))
        XCTAssertTrue(HexDump.dump(Data(count: 40), limit: 16).hasSuffix("… 24 more bytes not shown"))
        XCTAssertEqual(HexDump.hex(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]), grouped: true), "deadbeef 01")
        XCTAssertEqual(HexDump.hex(Data(count: 20), grouped: true), "00000000 00000000 00000000 00000000\n00000000")
        let narrow = HexDump.dump(Data(Array("ABCDEFGHIJ".utf8)), bytesPerLine: 8).split(separator: "\n")
        XCTAssertEqual(narrow.count, 2)
        XCTAssertEqual(String(narrow[0]), "0000  41 42 43 44 45 46 47 48  |ABCDEFGH|")
        XCTAssertTrue(narrow[1].hasSuffix("|IJ|"))
    }

    func testProtectedDonkDirectories() {
        let donk = StorageLocations.donkDirectories[0]
        XCTAssertTrue(StorageLocations.isProtected(donk))
        XCTAssertTrue(StorageLocations.isProtected(donk.appendingPathComponent("rules.json")))
        XCTAssertFalse(StorageLocations.isProtected(donk.deletingLastPathComponent()))
        XCTAssertFalse(StorageLocations.isProtected(root))
        XCTAssertEqual(StorageLocations.displayPath(StorageLocations.home), "~")
    }

    private func write(_ name: String, bytes: Int, modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func write(_ name: String, contents: Data) throws {
        try contents.write(to: root.appendingPathComponent(name))
    }
}
