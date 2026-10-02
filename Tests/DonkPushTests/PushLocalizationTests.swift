import XCTest
@testable import DonkPush

final class PushLocalizationTests: XCTestCase {
    private var bundle: Bundle!

    override func setUpWithError() throws {
        let root = PushTestSupport.temporaryDirectory().appendingPathComponent("Strings.bundle", isDirectory: true)
        let strings = """
        "GREETING_TITLE" = "Hello, %@!";
        "TRANSFER_BODY" = "%2$@ sent you %1$@";
        "PERCENT_BODY" = "%@ is 100%% done";
        "SUBTITLE_KEY" = "From %@";
        """
        for folder in ["", "en.lproj", "Base.lproj"] {
            let directory = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try strings.write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        bundle = try XCTUnwrap(Bundle(url: root))
    }

    func testSequentialArguments() {
        XCTAssertEqual(PushLocalization.format("%@ and %@", arguments: ["A", "B"]), "A and B")
    }

    func testPositionalArguments() {
        XCTAssertEqual(PushLocalization.format("%2$@ before %1$@", arguments: ["one", "two"]), "two before one")
    }

    func testPercentEscapesAndMissingArguments() {
        XCTAssertEqual(PushLocalization.format("100%% of %@", arguments: []), "100% of ")
        XCTAssertEqual(PushLocalization.format("trailing %", arguments: []), "trailing %")
        XCTAssertEqual(PushLocalization.format("%d stays", arguments: ["x"]), "%d stays")
    }

    func testResolvesKeysThroughBundle() {
        XCTAssertEqual(PushLocalization.resolve(key: "GREETING_TITLE", arguments: ["Ivan"], bundle: bundle), "Hello, Ivan!")
        XCTAssertEqual(PushLocalization.resolve(key: "TRANSFER_BODY", arguments: ["25 000 ₸", "Aruzhan"], bundle: bundle), "Aruzhan sent you 25 000 ₸")
        XCTAssertEqual(PushLocalization.resolve(key: "PERCENT_BODY", arguments: ["Upload"], bundle: bundle), "Upload is 100% done")
    }

    func testMissingKeyFallsBackToKey() {
        XCTAssertEqual(PushLocalization.resolve(key: "UNKNOWN_KEY", arguments: [], bundle: bundle), "UNKNOWN_KEY")
    }

    func testAlertLocKeysOverridePlainValues() {
        let payload = PushTestSupport.dictionary("""
        {"aps":{"alert":{
          "title":"plain title","title-loc-key":"GREETING_TITLE","title-loc-args":["Ivan"],
          "subtitle-loc-key":"SUBTITLE_KEY","subtitle-loc-args":["Bank"],
          "body":"plain body","loc-key":"TRANSFER_BODY","loc-args":[25000,"Aruzhan"]
        }}}
        """)
        let mapped = PushContentMapper.map(payload, bundle: bundle)
        XCTAssertEqual(mapped.title, "Hello, Ivan!")
        XCTAssertEqual(mapped.subtitle, "From Bank")
        XCTAssertEqual(mapped.body, "Aruzhan sent you 25000")
    }
}
