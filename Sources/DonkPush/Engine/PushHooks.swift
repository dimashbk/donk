import DonkCore
import Foundation
import ObjectiveC.runtime
import UIKit
import UserNotifications

final class PushHooks: @unchecked Sendable {
    static let shared = PushHooks()
    static let simulatedPrefix = "donk.sim."

    enum Selectors {
        static let willPresent = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
        static let didReceive = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        static let remote = NSSelectorFromString("application:didReceiveRemoteNotification:fetchCompletionHandler:")
        static let setDelegate = NSSelectorFromString("setDelegate:")
    }

    private enum ThreadKey {
        static let depth = "dev.donk.push.hook-depth"
        static let simulation = "dev.donk.push.simulation"
    }

    let store: PushHistoryStore
    private let lock = DonkLock()
    private var hookedKeys = Set<String>()
    private var didSwizzleCenter = false
    private var recording = false

    init(store: PushHistoryStore = .shared) {
        self.store = store
    }

    var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }

    var hookedKeyCount: Int {
        lock.withLock { hookedKeys.count }
    }

    func install() {
        isRecording = true
        swizzleCenterDelegateSetter()
        if let delegate = UNUserNotificationCenter.current().delegate {
            hookNotificationDelegate(delegate)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { hookApplicationDelegate() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.hookApplicationDelegate() }
            }
        }
    }

    func hookNotificationDelegate(_ delegate: AnyObject) {
        hook(object: delegate, selector: Selectors.willPresent) { self.installWillPresent(on: $0) }
        hook(object: delegate, selector: Selectors.didReceive) { self.installDidReceive(on: $0) }
    }

    func hookRemoteNotificationReceiver(_ delegate: AnyObject) {
        hook(object: delegate, selector: Selectors.remote) { self.installRemote(on: $0) }
    }

    @MainActor
    private func hookApplicationDelegate() {
        guard let delegate = Self.sharedApplication()?.delegate else { return }
        hookRemoteNotificationReceiver(delegate)
    }

    // MARK: - Simulation scope

    static func simulating<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[ThreadKey.simulation] as? Int ?? 0
        dictionary[ThreadKey.simulation] = previous + 1
        defer { dictionary[ThreadKey.simulation] = previous }
        return try body()
    }

    static var isSimulating: Bool {
        (Thread.current.threadDictionary[ThreadKey.simulation] as? Int ?? 0) > 0
    }

    private static var depth: Int {
        Thread.current.threadDictionary[ThreadKey.depth] as? Int ?? 0
    }

    private static func nested(_ body: () -> Void) {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[ThreadKey.depth] as? Int ?? 0
        dictionary[ThreadKey.depth] = previous + 1
        defer { dictionary[ThreadKey.depth] = previous }
        body()
    }

    static func sharedApplication() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }

    // MARK: - Recording

    private var shouldRecord: Bool {
        isRecording && Self.depth == 0
    }

    private func isSimulated(_ identifier: String?) -> Bool {
        Self.isSimulating || (identifier?.hasPrefix(Self.simulatedPrefix) ?? false)
    }

    private func recordPresentation(_ notification: UNNotification) -> UUID? {
        guard shouldRecord else { return nil }
        let request = notification.value(forKey: "request") as? UNNotificationRequest
        let content = request?.content
        let record = PushRecord(
            path: .foreground,
            payload: PushJSON.text(fromUserInfo: content?.userInfo ?? [:]),
            isSimulated: isSimulated(request?.identifier),
            requestIdentifier: request?.identifier,
            categoryIdentifier: content?.categoryIdentifier.nonEmpty
        )
        store.append(record)
        return record.id
    }

    private func recordResponse(_ response: UNNotificationResponse) -> UUID? {
        guard shouldRecord else { return nil }
        let notification = response.value(forKey: "notification") as? UNNotification
        let request = notification?.value(forKey: "request") as? UNNotificationRequest
        let content = request?.content
        let record = PushRecord(
            path: .tap,
            payload: PushJSON.text(fromUserInfo: content?.userInfo ?? [:]),
            isSimulated: isSimulated(request?.identifier),
            actionIdentifier: response.value(forKey: "actionIdentifier") as? String,
            requestIdentifier: request?.identifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            categoryIdentifier: content?.categoryIdentifier.nonEmpty
        )
        store.append(record)
        return record.id
    }

    private func recordRemote(_ userInfo: NSDictionary?) -> UUID? {
        guard shouldRecord else { return nil }
        let info = (userInfo as? [AnyHashable: Any]) ?? [:]
        let aps = info["aps"] as? [String: Any]
        let record = PushRecord(
            path: .silent,
            payload: PushJSON.text(fromUserInfo: info),
            isSimulated: Self.isSimulating,
            categoryIdentifier: (aps?["category"] as? String)?.nonEmpty
        )
        store.append(record)
        return record.id
    }

    // MARK: - Installation

    private func hook(object: AnyObject, selector: Selector, install: (AnyClass) -> Void) {
        var candidates: [AnyObject] = [object]
        if let base = object_getClass(object), Self.owner(of: selector, in: base) == nil,
           let target = (object as? NSObject)?.forwardingTarget(for: selector).map({ $0 as AnyObject }),
           target !== object {
            candidates.append(target)
        }
        for candidate in candidates {
            guard let cls = object_getClass(candidate), let owner = Self.owner(of: selector, in: cls) else { continue }
            let key = "\(NSStringFromClass(owner))|\(NSStringFromSelector(selector))"
            let isNew = lock.withLock { hookedKeys.insert(key).inserted }
            if isNew {
                install(owner)
            }
        }
    }

    static func owner(of selector: Selector, in cls: AnyClass) -> AnyClass? {
        var current: AnyClass? = cls
        while let candidate = current {
            if ownsMethod(candidate, selector) {
                return candidate
            }
            current = class_getSuperclass(candidate)
        }
        return nil
    }

    static func ownsMethod(_ cls: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return false }
        defer { free(list) }
        for index in 0..<Int(count) where method_getName(list[index]) == selector {
            return true
        }
        return false
    }

    @discardableResult
    private static func replace(_ cls: AnyClass, _ selector: Selector, box: IMPBox, block: Any) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        box.imp = method_getImplementation(method)
        let implementation = imp_implementationWithBlock(block)
        if ownsMethod(cls, selector) {
            box.imp = method_setImplementation(method, implementation)
        } else if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)),
                  let added = class_getInstanceMethod(cls, selector) {
            box.imp = method_setImplementation(added, implementation)
        }
        return true
    }

    private func swizzleCenterDelegateSetter() {
        let shouldSwizzle = lock.withLock { () -> Bool in
            guard !didSwizzleCenter else { return false }
            didSwizzleCenter = true
            return true
        }
        guard shouldSwizzle else { return }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let selector = Selectors.setDelegate
        let box = IMPBox()
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { [self] center, delegate in
            if let delegate {
                hookNotificationDelegate(delegate)
            }
            guard let imp = box.imp else { return }
            unsafeBitCast(imp, to: Original.self)(center, selector, delegate)
        }
        Self.replace(UNUserNotificationCenter.self, selector, box: box, block: block)
    }

    private func installWillPresent(on cls: AnyClass) {
        typealias Completion = @convention(block) (UNNotificationPresentationOptions) -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, UNNotification, Completion) -> Void
        let selector = Selectors.willPresent
        let box = IMPBox()
        let block: @convention(block) (AnyObject, AnyObject, UNNotification, @escaping Completion) -> Void = { [self] receiver, center, notification, completion in
            guard let imp = box.imp else {
                completion([])
                return
            }
            let original = unsafeBitCast(imp, to: Original.self)
            guard let recordID = recordPresentation(notification) else {
                Self.nested { original(receiver, selector, center, notification, completion) }
                return
            }
            let started = Date()
            let store = store
            let wrapped: Completion = { options in
                store.update(recordID) { record in
                    record.appResponse = PushFormatting.presentationOptions(options)
                    record.responseTime = Date().timeIntervalSince(started)
                }
                completion(options)
            }
            Self.nested { original(receiver, selector, center, notification, wrapped) }
        }
        Self.replace(cls, selector, box: box, block: block)
    }

    private func installDidReceive(on cls: AnyClass) {
        typealias Completion = @convention(block) () -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, UNNotificationResponse, Completion) -> Void
        let selector = Selectors.didReceive
        let box = IMPBox()
        let block: @convention(block) (AnyObject, AnyObject, UNNotificationResponse, @escaping Completion) -> Void = { [self] receiver, center, response, completion in
            guard let imp = box.imp else {
                completion()
                return
            }
            let original = unsafeBitCast(imp, to: Original.self)
            guard let recordID = recordResponse(response) else {
                Self.nested { original(receiver, selector, center, response, completion) }
                return
            }
            let started = Date()
            let store = store
            let wrapped: Completion = {
                store.update(recordID) { record in
                    record.appResponse = "completionHandler()"
                    record.responseTime = Date().timeIntervalSince(started)
                }
                completion()
            }
            Self.nested { original(receiver, selector, center, response, wrapped) }
        }
        Self.replace(cls, selector, box: box, block: block)
    }

    private func installRemote(on cls: AnyClass) {
        typealias Completion = @convention(block) (UIBackgroundFetchResult) -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSDictionary?, Completion) -> Void
        let selector = Selectors.remote
        let box = IMPBox()
        let block: @convention(block) (AnyObject, AnyObject, NSDictionary?, @escaping Completion) -> Void = { [self] receiver, application, userInfo, completion in
            guard let imp = box.imp else {
                completion(.noData)
                return
            }
            let original = unsafeBitCast(imp, to: Original.self)
            guard let recordID = recordRemote(userInfo) else {
                Self.nested { original(receiver, selector, application, userInfo, completion) }
                return
            }
            let started = Date()
            let store = store
            let wrapped: Completion = { result in
                store.update(recordID) { record in
                    record.appResponse = PushFormatting.fetchResult(result)
                    record.responseTime = Date().timeIntervalSince(started)
                }
                completion(result)
            }
            Self.nested { original(receiver, selector, application, userInfo, wrapped) }
        }
        Self.replace(cls, selector, box: box, block: block)
    }
}

final class IMPBox: @unchecked Sendable {
    var imp: IMP?
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Formatting

enum PushFormatting {
    static func presentationOptions(_ options: UNNotificationPresentationOptions) -> String {
        var parts: [String] = []
        if options.contains(.banner) { parts.append("banner") }
        if options.contains(.list) { parts.append("list") }
        if options.contains(.sound) { parts.append("sound") }
        if options.contains(.badge) { parts.append("badge") }
        if options.rawValue & (1 << 2) != 0 && !options.contains(.banner) {
            parts.append("alert")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    static func fetchResult(_ result: UIBackgroundFetchResult) -> String {
        switch result {
        case .newData: return "newData"
        case .noData: return "noData"
        case .failed: return "failed"
        @unknown default: return "rawValue \(result.rawValue)"
        }
    }
}
