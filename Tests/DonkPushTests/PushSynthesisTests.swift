import UIKit
import UserNotifications
import XCTest
@testable import DonkPush

final class PushSynthesisTests: XCTestCase {
    private func request(trigger: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        let content = PushContentMapper.makeContent(payload: PushTestSupport.dictionary(#"{"aps":{"alert":{"title":"T","body":"B"}},"id":7}"#))
        return UNNotificationRequest(identifier: "donk.sim.synth", content: content, trigger: trigger)
    }

    func testPushTriggerSynthesisDoesNotCrash() {
        let trigger = PushSynthesizer.makePushTrigger()
        if let trigger {
            XCTAssertTrue(trigger is UNPushNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            let request = request(trigger: trigger)
            XCTAssertTrue(request.trigger is UNPushNotificationTrigger)
        }
    }

    func testNotificationSynthesisReturnsObjectOrFailsGracefully() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        switch PushSynthesizer.makeNotification(request: request(trigger: PushSynthesizer.makePushTrigger()), date: date) {
        case let .success(notification):
            XCTAssertEqual(notification.request.identifier, "donk.sim.synth")
            XCTAssertEqual(notification.request.content.title, "T")
            XCTAssertEqual(notification.request.content.userInfo["id"] as? Int, 7)
            XCTAssertEqual(notification.date, date)
        case let .failure(error):
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testSynthesisWithAttachmentAndNullValuesDoesNotCrash() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let fileURL = PushTestSupport.temporaryDirectory().appendingPathComponent("attachment.png")
        try XCTUnwrap(image.pngData()).write(to: fileURL)
        let content = PushContentMapper.makeContent(payload: PushTestSupport.dictionary(#"{"aps":{"alert":"x","mutable-content":1},"missing":null,"list":[null,1]}"#))
        content.attachments = [try UNNotificationAttachment(identifier: "image", url: fileURL)]
        let request = UNNotificationRequest(identifier: "donk.sim.attachment", content: content, trigger: PushSynthesizer.makePushTrigger())

        switch PushSynthesizer.makeNotification(request: request) {
        case let .success(notification):
            XCTAssertEqual(notification.request.content.attachments.count, 1)
            XCTAssertTrue(notification.request.content.userInfo["missing"] is NSNull)
            if case let .success(response) = PushSynthesizer.makeResponse(notification: notification, actionIdentifier: "REPLY", userText: "Hi") {
                XCTAssertEqual(response.notification.request.content.attachments.count, 1)
                XCTAssertEqual((response as? UNTextInputNotificationResponse)?.userText, "Hi")
            }
        case let .failure(error):
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testResponseSynthesisDefaultCustomAndTextInput() throws {
        guard case let .success(notification) = PushSynthesizer.makeNotification(request: request()) else {
            throw XCTSkip("UNNotification synthesis unavailable on this OS")
        }
        switch PushSynthesizer.makeResponse(notification: notification) {
        case let .success(response):
            XCTAssertEqual(response.actionIdentifier, UNNotificationDefaultActionIdentifier)
            XCTAssertEqual(response.notification.request.identifier, "donk.sim.synth")
            XCTAssertFalse(response is UNTextInputNotificationResponse)
        case let .failure(error):
            XCTAssertFalse(error.message.isEmpty)
        }
        if case let .success(custom) = PushSynthesizer.makeResponse(notification: notification, actionIdentifier: "MARK_READ") {
            XCTAssertEqual(custom.actionIdentifier, "MARK_READ")
        }
        if case let .success(text) = PushSynthesizer.makeResponse(notification: notification, actionIdentifier: "REPLY", userText: "Hello") {
            let textResponse = try XCTUnwrap(text as? UNTextInputNotificationResponse)
            XCTAssertEqual(textResponse.userText, "Hello")
            XCTAssertEqual(textResponse.actionIdentifier, "REPLY")
        }
    }
}
