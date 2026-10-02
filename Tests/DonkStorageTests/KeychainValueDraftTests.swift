import XCTest
@testable import DonkStorage

final class KeychainValueDraftTests: XCTestCase {
    private let binary = Data([0x00, 0x01, 0xFA, 0xFB, 0x7F, 0x80])

    func testBinaryValueStartsAsBase64() {
        let draft = KeychainValueDraft(data: binary)
        XCTAssertEqual(draft.encoding, .base64)
        XCTAssertEqual(draft.text, binary.base64EncodedString())
        XCTAssertEqual(draft.data, binary)
    }

    func testRejectedUTF8ConversionKeepsBase64TextUntouched() {
        let draft = KeychainValueDraft(data: binary)
        XCTAssertEqual(draft.converted(to: .utf8), .failure(.notText))
        XCTAssertEqual(draft.converted(to: .base64), .success(draft))
        XCTAssertEqual(draft.data, binary)
    }

    func testRepeatedTapsNeverDoubleEncode() {
        var draft = KeychainValueDraft(data: binary)
        for _ in 0..<3 {
            if case let .success(next) = draft.converted(to: .utf8) {
                draft = next
            }
            if case let .success(next) = draft.converted(to: .base64) {
                draft = next
            }
        }
        XCTAssertEqual(draft.encoding, .base64)
        XCTAssertEqual(draft.data, binary)
    }

    func testTextRoundTrip() {
        let draft = KeychainValueDraft(data: Data("token-key: 42".utf8))
        XCTAssertEqual(draft.encoding, .utf8)
        guard case let .success(encoded) = draft.converted(to: .base64) else { return XCTFail("expected base64") }
        XCTAssertEqual(encoded.text, Data("token-key: 42".utf8).base64EncodedString())
        XCTAssertEqual(encoded.data, Data("token-key: 42".utf8))
        XCTAssertEqual(encoded.converted(to: .utf8), .success(draft))
    }

    func testInvalidBase64CannotSwitchOrSave() {
        let draft = KeychainValueDraft(encoding: .base64, text: "not base64!")
        XCTAssertNil(draft.data)
        XCTAssertEqual(draft.converted(to: .utf8), .failure(.invalidBase64))
    }

    func testEmptyValue() {
        let draft = KeychainValueDraft(data: Data())
        XCTAssertEqual(draft.encoding, .utf8)
        XCTAssertEqual(draft.data, Data())
    }
}
