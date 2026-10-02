import DonkJSON
import XCTest
@testable import DonkStorage

final class PlistTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_759_320_000)

    private var sample: [String: Any] {
        [
            "name": "donk",
            "enabled": true,
            "count": 3,
            "ratio": 0.5,
            "created": date,
            "token": Data([0x01, 0xAB, 0xFF]),
            "items": [1, ["deep": Data()], "x"],
            "nested": ["inner": ["flag": false]],
        ]
    }

    func testTreeConversionSpecialCasesDateAndData() {
        let tree = PlistTree.jsonValue(from: sample)
        guard case let .object(members) = tree else { return XCTFail("Expected an object") }
        XCTAssertEqual(members.map(\.key), ["count", "created", "enabled", "items", "name", "nested", "ratio", "token"])
        XCTAssertEqual(tree["name"], .string("donk"))
        XCTAssertEqual(tree["enabled"], .bool(true))
        XCTAssertEqual(tree["count"], .number("3"))
        XCTAssertEqual(tree["ratio"], .number("0.5"))
        XCTAssertEqual(tree["created"], .string("Date(2025-10-01T12:00:00Z)"))
        XCTAssertEqual(tree["token"], .string("Data(3 bytes · 01abff)"))
        XCTAssertEqual(tree["items"], .array([.number("1"), .object([JSONMember(key: "deep", value: .string("Data(0 bytes)"))]), .string("x")]))
        XCTAssertEqual(tree["nested"]?["inner"]?["flag"], .bool(false))
    }

    func testBinaryAndXMLRoundTripPreservesFormat() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: sample, format: .binary, options: 0)
        let document = try PlistDocument.load(binary)
        XCTAssertEqual(document.format, .binary)
        XCTAssertEqual(document.formatName, "Binary plist")

        let xml = try PlistDocument.xmlText(for: document.object)
        XCTAssertTrue(xml.contains("<key>created</key>"))
        XCTAssertTrue(xml.contains("<date>2025-10-01T12:00:00Z</date>"))

        let edited = xml.replacingOccurrences(of: "<string>donk</string>", with: "<string>edited</string>")
        let object = try PlistDocument.parseXML(edited).get()
        let encoded = try PlistDocument.encode(object, format: document.format)
        XCTAssertTrue(encoded.starts(with: Array("bplist00".utf8)))
        let reloaded = try PlistDocument.load(encoded)
        XCTAssertEqual(reloaded.format, .binary)
        let dictionary = reloaded.object as? [String: Any]
        XCTAssertEqual(dictionary?["name"] as? String, "edited")
        XCTAssertEqual(dictionary?["created"] as? Date, date)
        XCTAssertEqual(dictionary?["token"] as? Data, Data([0x01, 0xAB, 0xFF]))

        let xmlData = try PlistDocument.encode(object, format: .xml)
        XCTAssertEqual(try PlistDocument.load(xmlData).format, .xml)
    }

    func testXMLValidationRejectsBrokenAndNonXMLInput() {
        let broken = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>a</key></plist>"
        guard case let .failure(error) = PlistDocument.parseXML(broken) else { return XCTFail("Expected failure") }
        XCTAssertFalse(error.message.isEmpty)
        if case .success = PlistDocument.parseXML("hello") {
            XCTFail("OpenStep text must not pass as XML")
        }
        if case .success = PlistDocument.parseXML("") {
            XCTFail("Empty text must fail")
        }
    }
}
