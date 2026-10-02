import XCTest
@testable import DonkJSON

final class JSONParsingTests: XCTestCase {
    // MARK: - Structure

    func testObjectKeyOrderIsPreserved() throws {
        let value = try JSONValue.parse(#"{"zeta":1,"alpha":2,"mid":3,"beta":4}"#)
        guard case let .object(members) = value else { return XCTFail("expected object") }
        XCTAssertEqual(members.map(\.key), ["zeta", "alpha", "mid", "beta"])
        XCTAssertEqual(value.compact(), #"{"zeta":1,"alpha":2,"mid":3,"beta":4}"#)
    }

    func testDuplicateKeysAreKeptInOrderAndSubscriptReturnsFirst() throws {
        let value = try JSONValue.parse(#"{"a":1,"b":2,"a":3}"#)
        XCTAssertEqual(value.childCount, 3)
        XCTAssertEqual(value["a"], .number("1"))
        XCTAssertEqual(value.compact(), #"{"a":1,"b":2,"a":3}"#)
    }

    func testNestedStructures() throws {
        let value = try JSONValue.parse(#"{"user":{"id":7,"tags":["a",{"deep":[true,false,null]}]},"list":[[1],[2,[3]]]}"#)
        XCTAssertEqual(value["user"]?["id"], .number("7"))
        guard case let .array(tags)? = value["user"]?["tags"] else { return XCTFail("expected tags array") }
        XCTAssertEqual(tags.first, .string("a"))
        XCTAssertEqual(tags.last?["deep"], .array([.bool(true), .bool(false), .null]))
        XCTAssertEqual(value["list"], .array([.array([.number("1")]), .array([.number("2"), .array([.number("3")])])]))
        XCTAssertEqual(value["missing"], nil)
        XCTAssertNil(JSONValue.array([])["key"])
    }

    func testEmptyContainers() throws {
        XCTAssertEqual(try JSONValue.parse("{}"), .object([]))
        XCTAssertEqual(try JSONValue.parse("[]"), .array([]))
        XCTAssertEqual(try JSONValue.parse(" { \n } "), .object([]))
        XCTAssertEqual(try JSONValue.parse("[ \t ]"), .array([]))
        XCTAssertEqual(try JSONValue.parse(#"{"a":{},"b":[]}"#).compact(), #"{"a":{},"b":[]}"#)
    }

    func testTopLevelScalars() throws {
        XCTAssertEqual(try JSONValue.parse("true"), .bool(true))
        XCTAssertEqual(try JSONValue.parse("false"), .bool(false))
        XCTAssertEqual(try JSONValue.parse("null"), .null)
        XCTAssertEqual(try JSONValue.parse(#""text""#), .string("text"))
        XCTAssertEqual(try JSONValue.parse("  42  "), .number("42"))
    }

    func testTypeInformation() throws {
        let value = try JSONValue.parse(#"{"o":{},"a":[1,2],"s":"x","n":1,"b":true,"z":null}"#)
        XCTAssertTrue(value.isContainer)
        XCTAssertEqual(value.childCount, 6)
        XCTAssertEqual(value["o"]?.typeName, "object")
        XCTAssertEqual(value["a"]?.typeName, "array")
        XCTAssertEqual(value["a"]?.childCount, 2)
        XCTAssertEqual(value["s"]?.typeName, "string")
        XCTAssertEqual(value["n"]?.typeName, "number")
        XCTAssertEqual(value["b"]?.typeName, "bool")
        XCTAssertEqual(value["z"]?.typeName, "null")
        XCTAssertFalse(value["s"]?.isContainer ?? true)
        XCTAssertEqual(value["s"]?.childCount, 0)
    }

    // MARK: - Strings

    func testSimpleEscapes() throws {
        let value = try JSONValue.parse(#""quote\" backslash\\ slash\/ b\b f\f n\n r\r t\t""#)
        XCTAssertEqual(value, .string("quote\" backslash\\ slash/ b\u{08} f\u{0C} n\n r\r t\t"))
    }

    func testUnicodeEscapes() throws {
        XCTAssertEqual(try JSONValue.parse(#""\u0041\u00e9\u00E9\u4e2d""#), .string("Aéé中"))
        XCTAssertEqual(try JSONValue.parse(#""\u0000""#), .string("\u{0}"))
    }

    func testSurrogatePairs() throws {
        XCTAssertEqual(try JSONValue.parse(#""\ud83d\ude00""#), .string("😀"))
        XCTAssertEqual(try JSONValue.parse(#""\uD834\uDD1E clef""#), .string("𝄞 clef"))
    }

    func testInvalidSurrogatesBecomeReplacementCharacter() throws {
        XCTAssertEqual(try JSONValue.parse(#""\ud83d""#), .string("\u{FFFD}"))
        XCTAssertEqual(try JSONValue.parse(#""\ude00""#), .string("\u{FFFD}"))
        XCTAssertEqual(try JSONValue.parse(#""\ud83dx""#), .string("\u{FFFD}x"))
        XCTAssertEqual(try JSONValue.parse(#""\ud83d\u0041""#), .string("\u{FFFD}A"))
        XCTAssertEqual(try JSONValue.parse(#""\ud83d\ud83d\ude00""#), .string("\u{FFFD}😀"))
    }

    func testRawUnicodeIsKept() throws {
        XCTAssertEqual(try JSONValue.parse(#""привет 😀 ✓""#), .string("привет 😀 ✓"))
    }

    func testInvalidEscapesThrow() {
        XCTAssertThrowsError(try JSONValue.parse(#""\x""#))
        XCTAssertThrowsError(try JSONValue.parse(#""\'""#))
        XCTAssertThrowsError(try JSONValue.parse(#""\u12""#))
        XCTAssertThrowsError(try JSONValue.parse(#""\uZZZZ""#))
        XCTAssertThrowsError(try JSONValue.parse(#""\ud83d\uZZZZ""#))
        XCTAssertThrowsError(try JSONValue.parse("\"abc\\"))
    }

    func testUnescapedControlCharactersThrow() {
        XCTAssertThrowsError(try JSONValue.parse("\"line\nbreak\""))
        XCTAssertThrowsError(try JSONValue.parse("\"tab\there\""))
        XCTAssertThrowsError(try JSONValue.parse(Data([0x22, 0x00, 0x22])))
        XCTAssertNoThrow(try JSONValue.parse("\"del\u{7F}\""))
    }

    func testInvalidUTF8InStringThrows() {
        XCTAssertThrowsError(try JSONValue.parse(Data([0x22, 0x61, 0xFF, 0x22])))
        XCTAssertThrowsError(try JSONValue.parse(Data([0x22, 0xC3, 0x22])))
    }

    func testUnterminatedStringThrows() {
        XCTAssertThrowsError(try JSONValue.parse(#""abc"#))
        XCTAssertThrowsError(try JSONValue.parse(#"{"key: 1}"#))
    }

    // MARK: - Numbers

    func testNumbersKeepRawLiteral() throws {
        let literals = ["0", "-0", "1", "-1", "3.14", "-2.5", "1e10", "1E+10", "2.5e-3", "-1.0E-7", "0.0"]
        for literal in literals {
            XCTAssertEqual(try JSONValue.parse(literal), .number(literal), literal)
            XCTAssertEqual(try JSONValue.parse(literal).compact(), literal, literal)
        }
    }

    func testBigIntegersAreKeptAsLiteral() throws {
        let big = "123456789012345678901234567890"
        let value = try JSONValue.parse(#"{"id":\#(big),"f":0.10000000000000000555}"#)
        XCTAssertEqual(value["id"], .number(big))
        XCTAssertEqual(value.compact(), #"{"id":\#(big),"f":0.10000000000000000555}"#)
    }

    func testInvalidNumbersThrow() {
        for input in ["01", "-01", "00", "1.", ".5", "+1", "-", "1e", "1e+", "--1", "1.e5", "0x10", "NaN", "Infinity", "[01]", "[1.]"] {
            XCTAssertThrowsError(try JSONValue.parse(input), input)
        }
    }

    // MARK: - Invalid documents

    func testTrailingCommasThrow() {
        XCTAssertThrowsError(try JSONValue.parse("[1,2,]"))
        XCTAssertThrowsError(try JSONValue.parse(#"{"a":1,}"#))
        XCTAssertThrowsError(try JSONValue.parse("[,]"))
        XCTAssertThrowsError(try JSONValue.parse("[1,,2]"))
    }

    func testTrailingGarbageThrows() {
        XCTAssertThrowsError(try JSONValue.parse("{} x"))
        XCTAssertThrowsError(try JSONValue.parse("[1] [2]"))
        XCTAssertThrowsError(try JSONValue.parse("truex"))
        XCTAssertThrowsError(try JSONValue.parse("nulls"))
        XCTAssertThrowsError(try JSONValue.parse(#""a" "b""#))
    }

    func testStructuralErrorsThrow() {
        for input in ["", "   ", "{", "[", "}", "]", #"{"a"}"#, #"{"a" 1}"#, #"{a:1}"#, "{1:2}", "[1 2]", #"{"a":1 "b":2}"#, "tru", "nul", "fals", "'single'"] {
            XCTAssertThrowsError(try JSONValue.parse(input), input)
        }
    }

    func testErrorCarriesOffset() {
        XCTAssertThrowsError(try JSONValue.parse("[1, x]")) { error in
            guard let parseError = error as? JSONParseError else { return XCTFail("unexpected error type") }
            XCTAssertEqual(parseError.offset, 4)
            XCTAssertFalse(parseError.description.isEmpty)
        }
    }

    func testDepthLimit() throws {
        let allowed = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        XCTAssertNoThrow(try JSONValue.parse(allowed))
        let tooDeep = String(repeating: "[", count: 201) + String(repeating: "]", count: 201)
        XCTAssertThrowsError(try JSONValue.parse(tooDeep))
        let objects = String(repeating: #"{"a":"#, count: 201) + "1" + String(repeating: "}", count: 201)
        XCTAssertThrowsError(try JSONValue.parse(objects))
        let hostile = String(repeating: "[", count: 100_000)
        XCTAssertThrowsError(try JSONValue.parse(hostile))
    }

    func testByteOrderMarkIsSkipped() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a":1}"#.utf8)
        XCTAssertEqual(try JSONValue.parse(data), .object([JSONMember(key: "a", value: .number("1"))]))
        XCTAssertEqual(JSONFormatting.pretty(data), "{\n  \"a\": 1\n}")
        XCTAssertTrue(JSONFormatting.isValid(data))
    }

    func testWhitespaceVariants() throws {
        let value = try JSONValue.parse(" \t\r\n{ \"a\" \n:\r\n [ 1 ,\t2 ] }\n")
        XCTAssertEqual(value.compact(), #"{"a":[1,2]}"#)
        XCTAssertThrowsError(try JSONValue.parse("\u{0C}{}"))
    }
}

final class JSONWritingTests: XCTestCase {
    func testPrettyPrintedExactOutput() throws {
        let value = try JSONValue.parse(#"{"b":1,"a":[true,null,{"x":"y"}],"e":{},"f":[]}"#)
        let expected = """
        {
          "b": 1,
          "a": [
            true,
            null,
            {
              "x": "y"
            }
          ],
          "e": {},
          "f": []
        }
        """
        XCTAssertEqual(value.prettyPrinted(), expected)
    }

    func testPrettyPrintedCustomIndent() throws {
        let value = try JSONValue.parse(#"{"a":[1]}"#)
        XCTAssertEqual(value.prettyPrinted(indent: 4), "{\n    \"a\": [\n        1\n    ]\n}")
        XCTAssertEqual(value.prettyPrinted(indent: 0), "{\n\"a\": [\n1\n]\n}")
    }

    func testCompactExactOutput() throws {
        let value = try JSONValue.parse(" { \"k\" : [ 1 , \"two\" , { } , [ ] , false ] } ")
        XCTAssertEqual(value.compact(), #"{"k":[1,"two",{},[],false]}"#)
    }

    func testScalarOutput() {
        XCTAssertEqual(JSONValue.null.compact(), "null")
        XCTAssertEqual(JSONValue.bool(true).prettyPrinted(), "true")
        XCTAssertEqual(JSONValue.number("-1.5e3").compact(), "-1.5e3")
        XCTAssertEqual(JSONValue.string("s").prettyPrinted(), #""s""#)
    }

    func testStringEscapingOnOutput() {
        let value = JSONValue.string("q\" b\\ / \n \r \t \u{08} \u{0C} \u{01} \u{1F} \u{7F} é 😀")
        XCTAssertEqual(value.compact(), #""q\" b\\ / \n \r \t \b \f \u0001 \u001F \#u{7F} é 😀""#)
    }

    func testRoundTripPreservesValue() throws {
        let source = #"{"name":"Ünïcødé \"quoted\"","nums":[0,-0.5,1e100,12345678901234567890],"nested":{"empty":{},"list":[[],[null]]},"esc":"\n\t\u0002"}"#
        let value = try JSONValue.parse(source)
        XCTAssertEqual(try JSONValue.parse(value.compact()), value)
        XCTAssertEqual(try JSONValue.parse(value.prettyPrinted()), value)
        XCTAssertEqual(try JSONValue.parse(value.prettyPrinted(indent: 3)), value)
    }

    func testEscapeProducesQuotedLiteral() {
        XCTAssertEqual(JSONFormatting.escape("plain"), #""plain""#)
        XCTAssertEqual(JSONFormatting.escape(""), #""""#)
        XCTAssertEqual(JSONFormatting.escape("a\"b\\c\nd"), #""a\"b\\c\nd""#)
        XCTAssertEqual(JSONFormatting.escape("\u{0}"), #""\u0000""#)
        XCTAssertEqual(JSONFormatting.escape("😀"), "\"😀\"")
        XCTAssertEqual(try JSONValue.parse(JSONFormatting.escape("x\u{1}\"y")), .string("x\u{1}\"y"))
    }

    func testFormattingHelpers() {
        XCTAssertEqual(JSONFormatting.pretty(#"{"z":1,"a":2}"#), "{\n  \"z\": 1,\n  \"a\": 2\n}")
        XCTAssertNil(JSONFormatting.pretty(""))
        XCTAssertNil(JSONFormatting.pretty(Data()))
        XCTAssertNil(JSONFormatting.pretty("{bad}"))
        XCTAssertTrue(JSONFormatting.isValid("[1,2]"))
        XCTAssertFalse(JSONFormatting.isValid("[1,2"))
        XCTAssertFalse(JSONFormatting.isValid(""))
        XCTAssertTrue(JSONFormatting.isValid(Data("null".utf8)))
        XCTAssertFalse(JSONFormatting.isValid(Data()))
    }
}
