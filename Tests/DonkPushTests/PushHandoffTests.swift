import DonkCore
import UserNotifications
import XCTest
@testable import DonkPush

@MainActor
final class PushHandoffTests: XCTestCase {
    private var hideCount = 0

    override func setUp() async throws {
        try await super.setUp()
        hideCount = 0
        DonkEnvironment.hideDebuggerHandler = { [weak self] in
            self?.hideCount += 1
            DonkEnvironment.setDebuggerVisible(false)
        }
    }

    override func tearDown() async throws {
        DonkEnvironment.hideDebuggerHandler = nil
        DonkEnvironment.setDebuggerVisible(false)
        try await super.tearDown()
    }

    func testHidesVisibleDebuggerAndWaitsForTheAnimation() async {
        DonkEnvironment.setDebuggerVisible(true)
        let started = Date()
        await PushHandoff.hideDebugger.run()
        XCTAssertEqual(hideCount, 1)
        XCTAssertFalse(DonkEnvironment.isDebuggerVisible)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
    }

    func testKeepOpenNeverHides() async {
        DonkEnvironment.setDebuggerVisible(true)
        await PushHandoff.inPlace.run()
        XCTAssertEqual(hideCount, 0)
        XCTAssertTrue(DonkEnvironment.isDebuggerVisible)
    }

    func testHiddenDebuggerSkipsTheDelay() async {
        let started = Date()
        await PushHandoff.hideDebugger.run()
        XCTAssertEqual(hideCount, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    func testUnsupportedSynthesisOutcome() {
        let outcome = PushSynthesizer.unsupportedOutcome(PushSynthesisError(message: "UNNotification(coder:) is not supported"), steps: [])
        XCTAssertEqual(outcome.status, .failure)
        XCTAssertEqual(outcome.title, "Unsupported on this iOS")
        XCTAssertEqual(outcome.lines.first?.value, "UNNotification(coder:) is not supported")
        XCTAssertTrue(outcome.lines.contains { $0.key == "System" && $0.value.hasPrefix("iOS ") })
    }

    func testToastTextUsesFirstLine() {
        let outcome = PushDeliveryOutcome(
            status: .success,
            title: "Delegate answered willPresent",
            lines: [PushOutcomeLine("Returned", "banner, sound")]
        )
        XCTAssertEqual(PushComposerModel.toastText(outcome), "Delegate answered willPresent · Returned: banner, sound")
    }

    func testSynthesisOnThisOSMatchesTheRequestOrReportsUnsupported() {
        let content = PushContentMapper.makeContent(payload: PushTestSupport.dictionary(#"{"aps":{"alert":"Hi"},"id":1}"#))
        let request = UNNotificationRequest(identifier: "donk.sim.verify", content: content, trigger: PushSynthesizer.makePushTrigger())
        switch PushSynthesizer.makeNotification(request: request) {
        case let .success(notification):
            XCTAssertEqual(notification.request.identifier, "donk.sim.verify")
            guard case let .success(response) = PushSynthesizer.makeResponse(notification: notification) else {
                return XCTFail("Response synthesis failed on \(PushSynthesizer.systemDescription)")
            }
            XCTAssertEqual(response.notification.request.identifier, "donk.sim.verify")
            print("donk-synthesis: supported on \(PushSynthesizer.systemDescription)")
        case let .failure(error):
            print("donk-synthesis: unsupported on \(PushSynthesizer.systemDescription): \(error.message)")
        }
    }
}
