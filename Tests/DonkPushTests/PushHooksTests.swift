import ObjectiveC.runtime
import UIKit
import UserNotifications
import XCTest
@testable import DonkPush

// MARK: - Fixtures

class HookBaseDelegate: NSObject, UNUserNotificationCenterDelegate {
    var willPresentCalls = 0
    var didReceiveCalls = 0
    var lastAction: String?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        willPresentCalls += 1
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        didReceiveCalls += 1
        lastAction = response.actionIdentifier
        completionHandler()
    }
}

final class HookOverridingSubclass: HookBaseDelegate {
    var subclassCalls = 0

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        subclassCalls += 1
        super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
}

class HookPlainBase: NSObject, UNUserNotificationCenterDelegate {
    var calls = 0

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        calls += 1
        completionHandler([.list])
    }
}

final class HookInheritingSubclass: HookPlainBase {}

final class HookTwiceDelegate: NSObject, UNUserNotificationCenterDelegate {
    var calls = 0

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        calls += 1
        completionHandler([.badge])
    }
}

final class HookSameClassDelegate: NSObject, UNUserNotificationCenterDelegate {
    var calls = 0

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        calls += 1
        completionHandler([])
    }
}

final class HookRemoteDelegate: NSObject {
    var calls = 0
    var received: NSDictionary?

    @objc(application:didReceiveRemoteNotification:fetchCompletionHandler:)
    func application(
        _ application: AnyObject,
        didReceiveRemoteNotification userInfo: NSDictionary,
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        calls += 1
        received = userInfo
        completionHandler(.newData)
    }
}

final class HookForwardedDelegate: NSObject, UNUserNotificationCenterDelegate {
    var calls = 0

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        calls += 1
        completionHandler([.banner])
    }
}

final class HookForwardingProxy: NSObject {
    let target: HookForwardedDelegate

    init(target: HookForwardedDelegate) {
        self.target = target
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        target.responds(to: aSelector) ? target : nil
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || target.responds(to: aSelector)
    }
}

final class HookNoMethodsDelegate: NSObject {}

// MARK: - Tests

final class PushHooksTests: XCTestCase {
    private typealias WillPresentIMP = @convention(c) (
        AnyObject, Selector, AnyObject, UNNotification, @convention(block) (UNNotificationPresentationOptions) -> Void
    ) -> Void
    private typealias DidReceiveIMP = @convention(c) (
        AnyObject, Selector, AnyObject, UNNotificationResponse, @convention(block) () -> Void
    ) -> Void
    private typealias RemoteIMP = @convention(c) (
        AnyObject, Selector, AnyObject, NSDictionary, @convention(block) (UIBackgroundFetchResult) -> Void
    ) -> Void

    private var store: PushHistoryStore!
    private var hooks: PushHooks!

    override func setUp() {
        super.setUp()
        store = PushHistoryStore(directory: PushTestSupport.temporaryDirectory())
        hooks = PushHooks(store: store)
        hooks.isRecording = true
    }

    private func notification(identifier: String = "donk.sim.test", userInfo: [AnyHashable: Any] = ["aps": ["alert": "Hi"], "k": "v"]) throws -> UNNotification {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        content.categoryIdentifier = "CAT"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        switch PushSynthesizer.makeNotification(request: request) {
        case let .success(notification):
            return notification
        case let .failure(error):
            throw XCTSkip("UNNotification synthesis unavailable: \(error)")
        }
    }

    @discardableResult
    private func callWillPresent(_ object: AnyObject, _ notification: UNNotification) -> UNNotificationPresentationOptions? {
        let selector = PushHooks.Selectors.willPresent
        guard let cls = object_getClass(object), let imp = class_getMethodImplementation(cls, selector) else { return nil }
        var result: UNNotificationPresentationOptions?
        unsafeBitCast(imp, to: WillPresentIMP.self)(object, selector, NSObject(), notification) { result = $0 }
        return result
    }

    func testSettingTheSameDelegateTwiceHooksOnce() throws {
        let delegate = HookTwiceDelegate()
        hooks.hookNotificationDelegate(delegate)
        hooks.hookNotificationDelegate(delegate)
        XCTAssertEqual(hooks.hookedKeyCount, 1)

        let options = callWillPresent(delegate, try notification())
        XCTAssertEqual(options, [.badge])
        XCTAssertEqual(delegate.calls, 1)
        XCTAssertEqual(store.count, 1)
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.path, .foreground)
        XCTAssertTrue(record.isSimulated)
        XCTAssertEqual(record.requestIdentifier, "donk.sim.test")
        XCTAssertEqual(record.categoryIdentifier, "CAT")
        XCTAssertEqual(record.appResponse, "badge")
        XCTAssertTrue(NSDictionary(dictionary: PushTestSupport.dictionary(record.payload)).isEqual(to: ["aps": ["alert": "Hi"], "k": "v"]))
    }

    func testTwoDelegatesOfTheSameClass() throws {
        let first = HookSameClassDelegate()
        let second = HookSameClassDelegate()
        hooks.hookNotificationDelegate(first)
        hooks.hookNotificationDelegate(second)
        XCTAssertEqual(hooks.hookedKeyCount, 1)

        callWillPresent(first, try notification(identifier: "real-1"))
        callWillPresent(second, try notification(identifier: "real-2"))
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
        XCTAssertEqual(store.records.map(\.requestIdentifier), ["real-2", "real-1"])
        XCTAssertEqual(store.records.map(\.isSimulated), [false, false])
        XCTAssertEqual(store.records.first?.appResponse, "none")
    }

    func testOverridingSubclassCallingSuperRecordsOnce() throws {
        let base = HookBaseDelegate()
        let subclass = HookOverridingSubclass()
        hooks.hookNotificationDelegate(base)
        hooks.hookNotificationDelegate(subclass)

        let options = callWillPresent(subclass, try notification())
        XCTAssertEqual(options, [.banner, .sound])
        XCTAssertEqual(subclass.subclassCalls, 1)
        XCTAssertEqual(subclass.willPresentCalls, 1)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.records.first?.appResponse, "banner, sound")

        callWillPresent(base, try notification())
        XCTAssertEqual(base.willPresentCalls, 1)
        XCTAssertEqual(store.count, 2)
    }

    func testInheritingSubclassHooksTheImplementingClass() throws {
        let subclass = HookInheritingSubclass()
        hooks.hookNotificationDelegate(subclass)
        XCTAssertTrue(PushHooks.owner(of: PushHooks.Selectors.willPresent, in: HookInheritingSubclass.self) === HookPlainBase.self)
        XCTAssertFalse(PushHooks.ownsMethod(HookInheritingSubclass.self, PushHooks.Selectors.willPresent))
        XCTAssertFalse(PushHooks.ownsMethod(HookInheritingSubclass.self, PushHooks.Selectors.didReceive))

        let base = HookPlainBase()
        hooks.hookNotificationDelegate(base)
        XCTAssertEqual(hooks.hookedKeyCount, 1)

        callWillPresent(subclass, try notification())
        callWillPresent(base, try notification())
        XCTAssertEqual(subclass.calls, 1)
        XCTAssertEqual(base.calls, 1)
        XCTAssertEqual(store.count, 2)
    }

    func testDidReceiveRecordsActionAndText() throws {
        let delegate = HookBaseDelegate()
        hooks.hookNotificationDelegate(delegate)
        let response = try PushSynthesizer.makeResponse(notification: try notification(), actionIdentifier: "REPLY", userText: "On my way").get()

        let selector = PushHooks.Selectors.didReceive
        let imp = try XCTUnwrap(class_getMethodImplementation(HookBaseDelegate.self, selector))
        var completed = false
        unsafeBitCast(imp, to: DidReceiveIMP.self)(delegate, selector, NSObject(), response) { completed = true }

        XCTAssertTrue(completed)
        XCTAssertEqual(delegate.didReceiveCalls, 1)
        XCTAssertEqual(delegate.lastAction, "REPLY")
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.path, .tap)
        XCTAssertEqual(record.actionIdentifier, "REPLY")
        XCTAssertEqual(record.userText, "On my way")
        XCTAssertEqual(record.appResponse, "completionHandler()")
    }

    func testRemoteNotificationHookAndSimulationFlag() throws {
        let delegate = HookRemoteDelegate()
        hooks.hookRemoteNotificationReceiver(delegate)
        hooks.hookRemoteNotificationReceiver(delegate)
        XCTAssertEqual(hooks.hookedKeyCount, 1)

        let selector = PushHooks.Selectors.remote
        let imp = try XCTUnwrap(class_getMethodImplementation(HookRemoteDelegate.self, selector))
        let userInfo: NSDictionary = ["aps": ["content-available": 1], "type": "sync"]
        var result: UIBackgroundFetchResult?
        unsafeBitCast(imp, to: RemoteIMP.self)(delegate, selector, NSObject(), userInfo) { result = $0 }
        PushHooks.simulating {
            unsafeBitCast(imp, to: RemoteIMP.self)(delegate, selector, NSObject(), userInfo) { _ in }
        }

        XCTAssertEqual(result, .newData)
        XCTAssertEqual(delegate.calls, 2)
        XCTAssertTrue(delegate.received === userInfo)
        XCTAssertEqual(store.records.map(\.path), [.silent, .silent])
        XCTAssertEqual(store.records.map(\.isSimulated), [true, false])
        XCTAssertEqual(store.records.last?.appResponse, "newData")
        XCTAssertFalse(PushHooks.isSimulating)
    }

    func testForwardingTargetIsHooked() throws {
        let target = HookForwardedDelegate()
        let proxy = HookForwardingProxy(target: target)
        hooks.hookNotificationDelegate(proxy)
        XCTAssertEqual(hooks.hookedKeyCount, 1)
        callWillPresent(target, try notification())
        XCTAssertEqual(target.calls, 1)
        XCTAssertEqual(store.count, 1)
    }

    func testObjectsWithoutMethodsAreLeftUntouched() {
        let object = HookNoMethodsDelegate()
        hooks.hookNotificationDelegate(object)
        hooks.hookRemoteNotificationReceiver(object)
        XCTAssertEqual(hooks.hookedKeyCount, 0)
        XCTAssertFalse(object.responds(to: PushHooks.Selectors.willPresent))
        XCTAssertFalse(object.responds(to: PushHooks.Selectors.remote))
    }

    func testRecordingOffStillCallsOriginal() throws {
        let delegate = HookBaseDelegate()
        hooks.hookNotificationDelegate(delegate)
        hooks.isRecording = false
        let options = callWillPresent(delegate, try notification())
        XCTAssertEqual(options, [.banner, .sound])
        XCTAssertEqual(delegate.willPresentCalls, 1)
        XCTAssertEqual(store.count, 0)
    }
}
