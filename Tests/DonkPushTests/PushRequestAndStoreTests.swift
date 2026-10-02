import UserNotifications
import XCTest
@testable import DonkPush

final class PushRequestBuilderTests: XCTestCase {
    private let payloadText = """
    {
      "aps": {"alert": {"title": "Payment received", "body": "+25 000 ₸"}, "sound": "default", "badge": 3, "mutable-content": 1},
      "navigation": "paymentHistory",
      "paymentId": "42",
      "amount": 25000.5,
      "flags": [true, false, 1, 0],
      "nested": {"deep": {"list": [{"k": "v"}, "x", 7]}},
      "fcm_options": {"image": "https://picsum.photos/seed/donk/600/400"}
    }
    """

    func testScheduledRequestUserInfoDeepEqualsPayload() throws {
        let payload = PushTestSupport.payload(payloadText)
        let request = PushPipeline.makeRequest(payload: payload, delay: 5)
        XCTAssertTrue(request.identifier.hasPrefix("donk.sim."))
        XCTAssertTrue(NSDictionary(dictionary: request.content.userInfo).isEqual(to: payload.dictionary))
        let aps = try XCTUnwrap(request.content.userInfo["aps"] as? [String: Any])
        XCTAssertEqual(aps["mutable-content"] as? Int, 1)
        XCTAssertEqual(request.content.title, "Payment received")
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 5)
        XCTAssertFalse(trigger.repeats)
    }

    func testDelayIsAtLeastOneSecond() throws {
        let request = PushPipeline.makeRequest(payload: PushTestSupport.payload(#"{"aps":{"alert":"x"}}"#), delay: 0)
        XCTAssertEqual(try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger).timeInterval, 1)
    }

    func testUserInfoWithNullAndUnicodeSurvivesRoundTrip() {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"Сәлем 👋"},"value":null,"emoji":"🎉"}"#)
        let request = PushPipeline.makeRequest(payload: payload, delay: 1)
        XCTAssertTrue(NSDictionary(dictionary: request.content.userInfo).isEqual(to: payload.dictionary))
        XCTAssertTrue(request.content.userInfo["value"] is NSNull)
    }

    func testPrepareWithoutMutableContentSkipsProcessing() async {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"x"},"image":"https://x.test/a.png"}"#)
        let prepared = await PushPipeline.prepare(payload: payload, keyPaths: ["image"], processor: { _ in
            XCTFail("Processor must not run without mutable-content")
            return UNNotificationContent()
        })
        XCTAssertTrue(prepared.steps.isEmpty)
        XCTAssertTrue(prepared.content.attachments.isEmpty)
    }

    func testPrepareRunsHostProcessorForMutableContent() async {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":{"title":"Original"},"mutable-content":1},"k":"v"}"#)
        let prepared = await PushPipeline.prepare(payload: payload, keyPaths: [], processor: { content in
            content.title = "Processed \(content.userInfo["k"] as? String ?? "")"
            return content
        })
        XCTAssertEqual(prepared.content.title, "Processed v")
        XCTAssertEqual(prepared.steps.first?.kind, .success)
        XCTAssertTrue(NSDictionary(dictionary: prepared.content.userInfo).isEqual(to: payload.dictionary))
    }

    func testPrepareReportsMissingAttachmentURL() async {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"x","mutable-content":1}}"#)
        let prepared = await PushPipeline.prepare(payload: payload, keyPaths: ["image"], processor: nil)
        XCTAssertEqual(prepared.steps.first?.kind, .info)
        XCTAssertTrue(prepared.content.attachments.isEmpty)
    }
}

final class PushHistoryStoreTests: XCTestCase {
    private func record(_ index: Int, path: PushRecord.Path = .foreground) -> PushRecord {
        PushRecord(path: path, payload: #"{"aps":{"alert":"\#(index)"}}"#, isSimulated: index % 2 == 0, requestIdentifier: "id-\(index)")
    }

    func testNewestFirstAndCap() {
        let store = PushHistoryStore(directory: PushTestSupport.temporaryDirectory())
        for index in 0..<130 {
            store.append(record(index))
        }
        XCTAssertEqual(store.count, 100)
        XCTAssertEqual(store.records.first?.requestIdentifier, "id-129")
        XCTAssertEqual(store.records.last?.requestIdentifier, "id-30")
    }

    func testPersistenceRoundTrip() {
        let directory = PushTestSupport.temporaryDirectory()
        let store = PushHistoryStore(directory: directory)
        let first = record(1, path: .tap)
        var second = record(2, path: .silent)
        second.actionIdentifier = "REPLY"
        second.userText = "On my way"
        store.append(first)
        store.append(second)
        store.update(first.id) { $0.appResponse = "banner, sound" }
        store.flush()

        let reloaded = PushHistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.records[0], second)
        XCTAssertEqual(reloaded.records[1].appResponse, "banner, sound")
        XCTAssertEqual(reloaded.records[1].path, .tap)
    }

    func testCapAppliesWhenLoadingLargerFile() {
        let directory = PushTestSupport.temporaryDirectory()
        let big = PushHistoryStore(directory: directory, limit: 150)
        for index in 0..<150 {
            big.append(record(index))
        }
        big.flush()
        let capped = PushHistoryStore(directory: directory)
        XCTAssertEqual(capped.count, 100)
        XCTAssertEqual(capped.records.first?.requestIdentifier, "id-149")
    }

    func testRemoveAndClear() {
        let directory = PushTestSupport.temporaryDirectory()
        let store = PushHistoryStore(directory: directory)
        let items = (0..<3).map { record($0) }
        items.forEach(store.append)
        store.remove([items[1].id])
        XCTAssertEqual(store.records.map(\.id), [items[2].id, items[0].id])
        store.clear()
        store.flush()
        XCTAssertEqual(PushHistoryStore(directory: directory).count, 0)
    }

    func testTemplateStoreSaveRenameDelete() {
        let directory = PushTestSupport.temporaryDirectory()
        let store = PushTemplateStore(directory: directory)
        let saved = store.add(name: "  Promo  ", payload: #"{"aps":{"alert":"Sale"}}"#)
        let other = store.add(name: "", payload: #"{"aps":{"badge":1}}"#)
        XCTAssertEqual(saved.name, "Promo")
        XCTAssertEqual(other.name, "Untitled")
        store.rename(saved.id, to: "Black Friday")
        store.remove(other.id)

        let reloaded = PushTemplateStore(directory: directory)
        XCTAssertEqual(reloaded.templates.count, 1)
        XCTAssertEqual(reloaded.templates.first?.name, "Black Friday")
        XCTAssertEqual(reloaded.templates.first?.payload, #"{"aps":{"alert":"Sale"}}"#)
    }
}
