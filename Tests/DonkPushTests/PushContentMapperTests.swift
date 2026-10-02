import UserNotifications
import XCTest
@testable import DonkPush

final class PushContentMapperTests: XCTestCase {
    func testStringAlertMapsToBody() {
        let mapped = PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"alert":"Hello there"}}"#))
        XCTAssertTrue(mapped.hasAPS)
        XCTAssertEqual(mapped.title, "")
        XCTAssertEqual(mapped.subtitle, "")
        XCTAssertEqual(mapped.body, "Hello there")
    }

    func testDictionaryAlertMapsTitleSubtitleBodyAndLaunchImage() {
        let mapped = PushContentMapper.map(PushTestSupport.dictionary(
            #"{"aps":{"alert":{"title":"T","subtitle":"S","body":"B","launch-image":"Launch.png"}}}"#
        ))
        XCTAssertEqual(mapped.title, "T")
        XCTAssertEqual(mapped.subtitle, "S")
        XCTAssertEqual(mapped.body, "B")
        XCTAssertEqual(mapped.launchImageName, "Launch.png")
        XCTAssertTrue(mapped.hasAlert)
    }

    func testMissingAPSProducesEmptyContent() {
        let mapped = PushContentMapper.map(PushTestSupport.dictionary(#"{"type":"sync"}"#))
        XCTAssertFalse(mapped.hasAPS)
        XCTAssertEqual(mapped, PushMappedContent())
    }

    func testBadgeVariants() {
        XCTAssertEqual(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"badge":5}}"#)).badge, 5)
        XCTAssertEqual(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"badge":0}}"#)).badge, 0)
        XCTAssertEqual(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"badge":"3"}}"#)).badge, 3)
        XCTAssertNil(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{}}"#)).badge)
    }

    func testSoundVariants() {
        XCTAssertEqual(PushContentMapper.sound("default"), .systemDefault)
        XCTAssertEqual(PushContentMapper.sound("DEFAULT"), .systemDefault)
        XCTAssertEqual(PushContentMapper.sound("chime.caf"), .named("chime.caf"))
        XCTAssertNil(PushContentMapper.sound(""))
        XCTAssertNil(PushContentMapper.sound(nil))
        XCTAssertEqual(PushContentMapper.sound(["critical": 1, "name": "default", "volume": 0.5]), .critical(name: nil, volume: 0.5))
        XCTAssertEqual(PushContentMapper.sound(["critical": 1, "name": "alarm.caf"]), .critical(name: "alarm.caf", volume: 1))
        XCTAssertEqual(PushContentMapper.sound(["critical": 1, "volume": 3.0]), .critical(name: nil, volume: 1))
        XCTAssertEqual(PushContentMapper.sound(["critical": 0, "name": "ping.aiff"]), .named("ping.aiff"))
        XCTAssertEqual(PushContentMapper.sound(["name": "default"]), .systemDefault)
    }

    func testSoundFromPayloadDictionary() {
        let mapped = PushContentMapper.map(PushTestSupport.dictionary(
            #"{"aps":{"sound":{"critical":1,"name":"default","volume":0.8}}}"#
        ))
        XCTAssertEqual(mapped.sound, .critical(name: nil, volume: 0.8))
    }

    func testIdentifiersLevelsAndScores() {
        let mapped = PushContentMapper.map(PushTestSupport.dictionary("""
        {"aps":{"thread-id":"chat-1","category":"MESSAGE","interruption-level":"time-sensitive",
        "relevance-score":0.75,"target-content-id":"screen-9","filter-criteria":"work",
        "mutable-content":1,"content-available":1}}
        """))
        XCTAssertEqual(mapped.threadIdentifier, "chat-1")
        XCTAssertEqual(mapped.categoryIdentifier, "MESSAGE")
        XCTAssertEqual(mapped.interruptionLevel, .timeSensitive)
        XCTAssertEqual(mapped.relevanceScore, 0.75)
        XCTAssertEqual(mapped.targetContentIdentifier, "screen-9")
        XCTAssertEqual(mapped.filterCriteria, "work")
        XCTAssertTrue(mapped.isMutableContent)
        XCTAssertTrue(mapped.isContentAvailable)
    }

    func testAllInterruptionLevels() {
        for level in PushInterruptionLevel.allCases {
            let mapped = PushContentMapper.map(["aps": ["interruption-level": level.rawValue]])
            XCTAssertEqual(mapped.interruptionLevel, level)
        }
        XCTAssertNil(PushContentMapper.map(["aps": ["interruption-level": "loud"]]).interruptionLevel)
    }

    func testRelevanceScoreIsClamped() {
        XCTAssertEqual(PushContentMapper.map(["aps": ["relevance-score": 4]]).relevanceScore, 1)
        XCTAssertEqual(PushContentMapper.map(["aps": ["relevance-score": -1]]).relevanceScore, 0)
    }

    func testSilentDetection() {
        XCTAssertTrue(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"content-available":1}}"#)).isSilent)
        XCTAssertFalse(PushContentMapper.map(PushTestSupport.dictionary(#"{"aps":{"content-available":1,"badge":1}}"#)).isSilent)
        XCTAssertTrue(PushTestSupport.payload(#"{"aps":{"content-available":1},"x":1}"#).isSilent)
        XCTAssertFalse(PushTestSupport.payload(#"{"aps":{"alert":"Hi","content-available":1}}"#).isSilent)
    }

    func testApplyToNotificationContent() {
        let payload = PushTestSupport.dictionary("""
        {"aps":{"alert":{"title":"T","subtitle":"S","body":"B"},"badge":2,"sound":"default",
        "thread-id":"th","category":"CAT","interruption-level":"passive","relevance-score":0.5,
        "target-content-id":"target"},"custom":{"a":[1,2,3]}}
        """)
        let content = PushContentMapper.makeContent(payload: payload)
        XCTAssertEqual(content.title, "T")
        XCTAssertEqual(content.subtitle, "S")
        XCTAssertEqual(content.body, "B")
        XCTAssertEqual(content.badge, NSNumber(value: 2))
        XCTAssertNotNil(content.sound)
        XCTAssertEqual(content.threadIdentifier, "th")
        XCTAssertEqual(content.categoryIdentifier, "CAT")
        XCTAssertEqual(content.interruptionLevel, .passive)
        XCTAssertEqual(content.relevanceScore, 0.5)
        XCTAssertEqual(content.targetContentIdentifier, "target")
        XCTAssertTrue(NSDictionary(dictionary: content.userInfo).isEqual(to: payload))
    }

    func testApplyLeavesOptionalFieldsUnset() {
        let content = PushContentMapper.makeContent(payload: PushTestSupport.dictionary(#"{"aps":{"alert":"Body"}}"#))
        XCTAssertNil(content.badge)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertNil(content.targetContentIdentifier)
    }

    func testPayloadValidation() {
        guard case let .failure(notObject) = PushPayload.parse("[1,2]") else { return XCTFail("Array accepted") }
        XCTAssertTrue(notObject.message.contains("object"))
        guard case .failure = PushPayload.parse("{\"aps\":") else { return XCTFail("Invalid JSON accepted") }
        guard case .failure = PushPayload.parse("   ") else { return XCTFail("Empty accepted") }
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"x","mutable-content":1},"n":null}"#)
        XCTAssertTrue(payload.hasAPS)
        XCTAssertTrue(payload.isMutableContent)
        XCTAssertTrue(payload.containsNull)
        XCTAssertEqual(payload.byteCount, #"{"aps":{"alert":"x","mutable-content":1},"n":null}"#.utf8.count)
    }

    func testUserInfoToJSONKeepsTypes() {
        let userInfo: [AnyHashable: Any] = [
            "z": "last",
            "aps": ["badge": 1, "mutable-content": true],
            "a": [1.5, NSNull(), "s"],
        ]
        let text = PushJSON.text(fromUserInfo: userInfo)
        XCTAssertTrue(text.hasPrefix("{\n  \"aps\""))
        let parsed = PushTestSupport.dictionary(text)
        XCTAssertTrue(NSDictionary(dictionary: parsed).isEqual(to: userInfo))
        XCTAssertTrue(text.contains("\"mutable-content\": true"))
    }
}
