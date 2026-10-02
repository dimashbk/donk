import XCTest
@testable import DonkStorage

final class DefaultsStoreTests: XCTestCase {
    private var domain: DefaultsDomain!

    override func setUp() {
        super.setUp()
        domain = .suite("dev.donk.tests." + UUID().uuidString)
    }

    override func tearDown() {
        DefaultsStore.reset(domain)
        super.tearDown()
    }

    func testTypeDetectionDistinguishesBoolIntAndDouble() {
        XCTAssertEqual(DefaultsValueType.detect(true), .bool)
        XCTAssertEqual(DefaultsValueType.detect(false), .bool)
        XCTAssertEqual(DefaultsValueType.detect(NSNumber(value: true)), .bool)
        XCTAssertEqual(DefaultsValueType.detect(1), .int)
        XCTAssertEqual(DefaultsValueType.detect(0), .int)
        XCTAssertEqual(DefaultsValueType.detect(NSNumber(value: Int8(1))), .int)
        XCTAssertEqual(DefaultsValueType.detect(3.5), .double)
        XCTAssertEqual(DefaultsValueType.detect(Float(1.5)), .double)
        XCTAssertEqual(DefaultsValueType.detect("1"), .string)
        XCTAssertEqual(DefaultsValueType.detect(Date()), .date)
        XCTAssertEqual(DefaultsValueType.detect(Data([1, 2])), .data)
        XCTAssertEqual(DefaultsValueType.detect([1, 2]), .array)
        XCTAssertEqual(DefaultsValueType.detect(["a": 1]), .dictionary)
    }

    func testEntriesAfterWritingEveryTypeToSuite() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let values: [String: Any] = [
            "string": "hello",
            "int": 42,
            "double": 2.75,
            "boolTrue": true,
            "boolFalse": false,
            "one": 1,
            "date": date,
            "data": Data([0xDE, 0xAD]),
            "array": [1, "two", true],
            "dictionary": ["nested": ["x": 1]],
        ]
        for (key, value) in values {
            DefaultsStore.set(value, forKey: key, in: domain)
        }
        let entries = DefaultsStore.entries(in: domain)
        let types = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.type) })
        XCTAssertEqual(entries.count, values.count)
        XCTAssertEqual(entries.map(\.key), entries.map(\.key).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(types["string"], .string)
        XCTAssertEqual(types["int"], .int)
        XCTAssertEqual(types["one"], .int)
        XCTAssertEqual(types["double"], .double)
        XCTAssertEqual(types["boolTrue"], .bool)
        XCTAssertEqual(types["boolFalse"], .bool)
        XCTAssertEqual(types["date"], .date)
        XCTAssertEqual(types["data"], .data)
        XCTAssertEqual(types["array"], .array)
        XCTAssertEqual(types["dictionary"], .dictionary)
        XCTAssertEqual(DefaultsStore.count(in: domain), values.count)
        XCTAssertEqual(entries.first { $0.key == "boolTrue" }?.preview, "true")
        XCTAssertEqual(entries.first { $0.key == "data" }?.preview, "2 bytes · dead")
    }

    func testEditingRoundTripKeepsTypes() {
        DefaultsStore.set(7, forKey: "count", in: domain)
        DefaultsStore.set(DefaultsValues.parseInt(" -12 ")!, forKey: "count", in: domain)
        XCTAssertEqual((DefaultsStore.value(forKey: "count", in: domain) as? NSNumber)?.intValue, -12)
        XCTAssertEqual(DefaultsValueType.detect(DefaultsStore.value(forKey: "count", in: domain)!), .int)

        DefaultsStore.set(DefaultsValues.parseDouble("3,25")!, forKey: "ratio", in: domain)
        XCTAssertEqual(DefaultsValueType.detect(DefaultsStore.value(forKey: "ratio", in: domain)!), .double)
        XCTAssertEqual((DefaultsStore.value(forKey: "ratio", in: domain) as? NSNumber)?.doubleValue, 3.25)

        DefaultsStore.set(false, forKey: "flag", in: domain)
        DefaultsStore.set(true, forKey: "flag", in: domain)
        XCTAssertEqual(DefaultsValueType.detect(DefaultsStore.value(forKey: "flag", in: domain)!), .bool)

        let data = DefaultsValues.parseBase64("3q2+7w==")!
        DefaultsStore.set(data, forKey: "blob", in: domain)
        XCTAssertEqual(DefaultsStore.value(forKey: "blob", in: domain) as? Data, Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let parsed = try? DefaultsValues.parseCollection(#"{"b": [1, 2.5, true], "a": "x"}"#, as: .dictionary).get()
        XCTAssertNotNil(parsed)
        DefaultsStore.set(parsed!, forKey: "config", in: domain)
        let stored = DefaultsStore.value(forKey: "config", in: domain) as? [String: Any]
        XCTAssertEqual(stored?["a"] as? String, "x")
        let array = stored?["b"] as? [Any]
        XCTAssertEqual(array.map { DefaultsValueType.detect($0[2]) }, .bool)
        XCTAssertEqual(array.map { DefaultsValueType.detect($0[0]) }, .int)
        let json = DefaultsValues.jsonText(for: stored!)
        XCTAssertEqual(json, "{\n  \"a\" : \"x\",\n  \"b\" : [\n    1,\n    2.5,\n    true\n  ]\n}")

        DefaultsStore.remove("flag", in: domain)
        XCTAssertNil(DefaultsStore.value(forKey: "flag", in: domain))

        DefaultsStore.reset(domain)
        XCTAssertTrue(DefaultsStore.entries(in: domain).isEmpty)
    }

    func testCollectionParsingValidation() {
        if case .success = DefaultsValues.parseCollection("[1, null]", as: .array) {
            XCTFail("null must be rejected")
        }
        if case .success = DefaultsValues.parseCollection("{}", as: .array) {
            XCTFail("object must not be accepted as array")
        }
        if case .success = DefaultsValues.parseCollection("[1,", as: .array) {
            XCTFail("invalid JSON must be rejected")
        }
        XCTAssertNoThrow(try DefaultsValues.parseCollection("[]", as: .array).get())
        XCTAssertNil(DefaultsValues.jsonText(for: ["date": Date()]))
        XCTAssertNil(DefaultsValues.parseBase64("@@@"))
        XCTAssertEqual(DefaultsValues.parseBase64(""), Data())
        XCTAssertNil(DefaultsValues.parseInt("1.5"))
        XCTAssertNil(DefaultsValues.parseDouble("abc"))
    }

    func testStandardDomainUsesBundleIdentifier() {
        let standard = DefaultsDomain.standard
        XCTAssertEqual(standard.kind, .standard)
        XCTAssertEqual(standard.name, Bundle.main.bundleIdentifier ?? "")
        XCTAssertEqual(standard.title, "Standard")
    }
}
