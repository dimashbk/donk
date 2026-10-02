import DonkCore
import DonkUI
import Foundation
import UIKit
import UserNotifications

struct PushStep: Hashable, Identifiable {
    enum Kind: Hashable {
        case info
        case success
        case warning
        case failure
    }

    var id = UUID()
    var kind: Kind
    var text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

struct PushOutcomeLine: Hashable, Identifiable {
    var id: String { key }
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

struct PushDeliveryOutcome: Identifiable {
    enum Status {
        case success
        case warning
        case failure
    }

    var id = UUID()
    var date = Date()
    var status: Status
    var title: String
    var lines: [PushOutcomeLine] = []
    var steps: [PushStep] = []
}

struct PushPreparedContent {
    var content: UNNotificationContent
    var steps: [PushStep]
}

enum PushPipeline {
    static func makeIdentifier() -> String {
        PushHooks.simulatedPrefix + UUID().uuidString
    }

    static func prepare(
        payload: PushPayload,
        keyPaths: [String],
        processor: (@Sendable (UNMutableNotificationContent) async -> UNNotificationContent)?,
        attachmentTimeout: TimeInterval = 25,
        bundle: Bundle = .main
    ) async -> PushPreparedContent {
        let content = PushContentMapper.makeContent(payload: payload.dictionary, bundle: bundle)
        guard payload.isMutableContent else {
            return PushPreparedContent(content: content, steps: [])
        }
        if let processor {
            let started = Date()
            let processed = await processor(content)
            let elapsed = DonkFormat.duration(Date().timeIntervalSince(started))
            let attachments = processed.attachments.count
            return PushPreparedContent(content: processed, steps: [
                PushStep(.success, "DonkPush.contentProcessor finished in \(elapsed) with \(attachments) attachment\(attachments == 1 ? "" : "s")"),
            ])
        }
        guard let url = payload.attachmentURL(keyPaths: keyPaths) else {
            return PushPreparedContent(content: content, steps: [
                PushStep(.info, "mutable-content is 1, but no attachment URL was found at: \(keyPaths.joined(separator: ", "))"),
            ])
        }
        do {
            let result = try await PushAttachmentLoader.loadAttachment(from: url, timeout: attachmentTimeout)
            content.attachments = [result.attachment]
            let type = result.mimeType.map { " · \($0)" } ?? ""
            return PushPreparedContent(content: content, steps: [
                PushStep(.success, "Attached \(result.fileName) (\(DonkFormat.bytes(result.byteCount))\(type)) from \(url.absoluteString)"),
            ])
        } catch {
            return PushPreparedContent(content: content, steps: [
                PushStep(.warning, "Attachment failed for \(url.absoluteString): \(describe(error))"),
            ])
        }
    }

    static func describe(_ error: Error) -> String {
        if let attachmentError = error as? PushAttachmentError {
            return attachmentError.message
        }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    static func makeRequest(identifier: String, content: UNNotificationContent, delay: TimeInterval) -> UNNotificationRequest {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    static func makeRequest(payload: PushPayload, delay: TimeInterval, bundle: Bundle = .main) -> UNNotificationRequest {
        makeRequest(
            identifier: makeIdentifier(),
            content: PushContentMapper.makeContent(payload: payload.dictionary, bundle: bundle),
            delay: delay
        )
    }
}

// MARK: - Delivery

@MainActor
enum PushDelivery {
    nonisolated static func delayLabel(_ delay: TimeInterval) -> String {
        let seconds = max(delay, 1)
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : DonkFormat.duration(seconds)
    }

    static func scheduleBanner(payload: PushPayload, delay: TimeInterval) async -> PushDeliveryOutcome {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var steps: [PushStep] = []
        if settings.authorizationStatus == .notDetermined {
            return PushDeliveryOutcome(
                status: .failure,
                title: "Notification permission has not been requested",
                lines: [PushOutcomeLine("Fix", "Use Request Permission in the composer. donk never asks on its own because the system prompt can be shown only once.")]
            )
        }
        guard PushPermission.canDeliver(settings.authorizationStatus) else {
            return PushDeliveryOutcome(
                status: .failure,
                title: "Notifications are \(PushPermission.title(settings.authorizationStatus).lowercased())",
                lines: [PushOutcomeLine("Fix", "Allow notifications in Settings, then send again")]
            )
        }
        let configuration = PushState.shared.configuration
        let prepared = await PushPipeline.prepare(
            payload: payload,
            keyPaths: configuration.attachmentURLKeyPaths,
            processor: PushState.shared.contentProcessor
        )
        steps += prepared.steps
        let identifier = PushPipeline.makeIdentifier()
        let request = PushPipeline.makeRequest(identifier: identifier, content: prepared.content, delay: delay)
        do {
            try await center.add(request)
        } catch {
            return PushDeliveryOutcome(
                status: .failure,
                title: "The system rejected the request",
                lines: [PushOutcomeLine("Error", error.localizedDescription)],
                steps: steps
            )
        }
        var lines = [
            PushOutcomeLine("Fires in", PushDelivery.delayLabel(delay)),
            PushOutcomeLine("Identifier", identifier),
            PushOutcomeLine("Permission", PushPermission.title(settings.authorizationStatus)),
        ]
        if !prepared.content.attachments.isEmpty {
            lines.append(PushOutcomeLine("Attachments", "\(prepared.content.attachments.count)"))
        }
        if settings.alertSetting == .disabled {
            steps.append(PushStep(.warning, "Alerts are disabled for this app, so no banner will appear"))
        }
        steps.append(PushStep(.info, "In the foreground iOS asks your delegate's willPresent whether to show it. Background or kill the app to see the system banner or test cold start."))
        return PushDeliveryOutcome(status: .success, title: "Scheduled local notification", lines: lines, steps: steps)
    }

    static func inject(payload: PushPayload, beforeInvoking handoff: PushHandoff = .inPlace) async -> PushDeliveryOutcome {
        let center = UNUserNotificationCenter.current()
        guard let delegate = center.delegate else {
            return PushDeliveryOutcome(
                status: .failure,
                title: "No notification delegate",
                lines: [PushOutcomeLine("Fix", "Set UNUserNotificationCenter.current().delegate in your app")]
            )
        }
        let delegateName = NSStringFromClass(type(of: delegate))
        guard delegate.responds(to: PushHooks.Selectors.willPresent) else {
            return PushDeliveryOutcome(
                status: .warning,
                title: "willPresent is not implemented",
                lines: [
                    PushOutcomeLine("Delegate", delegateName),
                    PushOutcomeLine("System behaviour", "Foreground notifications are not presented"),
                ]
            )
        }
        let configuration = PushState.shared.configuration
        let prepared = await PushPipeline.prepare(
            payload: payload,
            keyPaths: configuration.attachmentURLKeyPaths,
            processor: PushState.shared.contentProcessor,
            attachmentTimeout: 10
        )
        let trigger = PushSynthesizer.makePushTrigger()
        let request = UNNotificationRequest(identifier: PushPipeline.makeIdentifier(), content: prepared.content, trigger: trigger)
        let notification: UNNotification
        switch PushSynthesizer.makeNotification(request: request) {
        case let .success(value):
            notification = value
        case let .failure(error):
            return PushSynthesizer.unsupportedOutcome(error, steps: prepared.steps)
        }
        await handoff.run()
        let started = Date()
        let options: UNNotificationPresentationOptions? = await PushCallback.wait(timeout: 10) { done in
            delegate.userNotificationCenter?(center, willPresent: notification) { options in
                done(options)
            }
        }
        var lines = [
            PushOutcomeLine("Delegate", delegateName),
            PushOutcomeLine("Trigger", trigger == nil ? "nil" : "UNPushNotificationTrigger"),
            PushOutcomeLine("Identifier", request.identifier),
        ]
        guard let options else {
            lines.append(PushOutcomeLine("Completion", "Not called within 10 s"))
            return PushDeliveryOutcome(status: .warning, title: "willPresent did not call its completion handler", lines: lines, steps: prepared.steps)
        }
        lines.insert(PushOutcomeLine("Returned", PushFormatting.presentationOptions(options)), at: 0)
        lines.insert(PushOutcomeLine("Answered in", DonkFormat.duration(Date().timeIntervalSince(started))), at: 1)
        return PushDeliveryOutcome(status: .success, title: "Delegate answered willPresent", lines: lines, steps: prepared.steps)
    }

    static func simulateTap(
        payload: PushPayload,
        actionIdentifier: String,
        userText: String?,
        beforeInvoking handoff: PushHandoff = .inPlace
    ) async -> PushDeliveryOutcome {
        let center = UNUserNotificationCenter.current()
        guard let delegate = center.delegate else {
            return PushDeliveryOutcome(
                status: .failure,
                title: "No notification delegate",
                lines: [PushOutcomeLine("Fix", "Set UNUserNotificationCenter.current().delegate in your app")]
            )
        }
        let delegateName = NSStringFromClass(type(of: delegate))
        guard delegate.responds(to: PushHooks.Selectors.didReceive) else {
            return PushDeliveryOutcome(
                status: .warning,
                title: "didReceive is not implemented",
                lines: [PushOutcomeLine("Delegate", delegateName)]
            )
        }
        let configuration = PushState.shared.configuration
        let prepared = await PushPipeline.prepare(
            payload: payload,
            keyPaths: configuration.attachmentURLKeyPaths,
            processor: PushState.shared.contentProcessor,
            attachmentTimeout: 10
        )
        let trigger = PushSynthesizer.makePushTrigger()
        let request = UNNotificationRequest(identifier: PushPipeline.makeIdentifier(), content: prepared.content, trigger: trigger)
        let response: UNNotificationResponse
        switch PushSynthesizer.makeNotification(request: request).flatMap({
            PushSynthesizer.makeResponse(notification: $0, actionIdentifier: actionIdentifier, userText: userText)
        }) {
        case let .success(value):
            response = value
        case let .failure(error):
            return PushSynthesizer.unsupportedOutcome(error, steps: prepared.steps)
        }
        await handoff.run()
        let started = Date()
        let completed: Bool? = await PushCallback.wait(timeout: 30) { done in
            delegate.userNotificationCenter?(center, didReceive: response) {
                done(true)
            }
        }
        var lines = [
            PushOutcomeLine("Delegate", delegateName),
            PushOutcomeLine("Action", actionIdentifier),
        ]
        if let userText {
            lines.append(PushOutcomeLine("Text", userText))
        }
        guard completed != nil else {
            lines.append(PushOutcomeLine("Completion", "Not called within 30 s"))
            return PushDeliveryOutcome(status: .warning, title: "didReceive did not call its completion handler", lines: lines, steps: prepared.steps)
        }
        lines.insert(PushOutcomeLine("Completed in", DonkFormat.duration(Date().timeIntervalSince(started))), at: 0)
        return PushDeliveryOutcome(status: .success, title: "Delegate handled the tap", lines: lines, steps: prepared.steps)
    }

    static func silent(payload: PushPayload, beforeInvoking handoff: PushHandoff = .inPlace) async -> PushDeliveryOutcome {
        guard let application = PushHooks.sharedApplication(), let delegate = application.delegate else {
            return PushDeliveryOutcome(status: .failure, title: "No application delegate")
        }
        let delegateName = NSStringFromClass(type(of: delegate))
        guard delegate.responds(to: PushHooks.Selectors.remote) else {
            return PushDeliveryOutcome(
                status: .failure,
                title: "Background handler is not implemented",
                lines: [
                    PushOutcomeLine("Delegate", delegateName),
                    PushOutcomeLine("Missing", "application(_:didReceiveRemoteNotification:fetchCompletionHandler:)"),
                ]
            )
        }
        var steps: [PushStep] = []
        if !PushEnvironment.hasRemoteNotificationBackgroundMode {
            steps.append(PushStep(.warning, "UIBackgroundModes has no remote-notification, so real silent pushes will not wake the app"))
        }
        if !payload.isContentAvailable {
            steps.append(PushStep(.info, "aps.content-available is not 1; a real push like this would not be delivered in the background"))
        }
        let userInfo: [AnyHashable: Any] = payload.dictionary
        await handoff.run()
        let started = Date()
        let result: UIBackgroundFetchResult? = await PushCallback.wait(timeout: 30) { done in
            PushHooks.simulating {
                delegate.application?(application, didReceiveRemoteNotification: userInfo) { result in
                    done(result)
                }
            }
        }
        var lines = [PushOutcomeLine("Delegate", delegateName)]
        guard let result else {
            lines.append(PushOutcomeLine("Completion", "Not called within 30 s (iOS would terminate the background task)"))
            return PushDeliveryOutcome(status: .warning, title: "Completion handler was not called", lines: lines, steps: steps)
        }
        lines.insert(PushOutcomeLine("Result", PushFormatting.fetchResult(result)), at: 0)
        lines.insert(PushOutcomeLine("Elapsed", DonkFormat.duration(Date().timeIntervalSince(started))), at: 1)
        return PushDeliveryOutcome(status: result == .failed ? .warning : .success, title: "App handled the background push", lines: lines, steps: steps)
    }
}

// MARK: - Support

struct PushHandoff {
    static let inPlace = PushHandoff(isEnabled: false)
    static let hideDebugger = PushHandoff(isEnabled: true)
    static let animationDelay: UInt64 = 350_000_000

    let isEnabled: Bool

    @MainActor
    func run() async {
        guard isEnabled, DonkEnvironment.isDebuggerVisible else { return }
        DonkEnvironment.requestHideDebugger()
        try? await Task.sleep(nanoseconds: Self.animationDelay)
    }
}

enum PushCallback {
    @MainActor
    static func wait<T>(timeout: TimeInterval, _ start: (@escaping (T) -> Void) -> Void) async -> T? {
        let once = PushOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            start { value in
                if once.claim() {
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

final class PushOnce: @unchecked Sendable {
    private let lock = DonkLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

enum PushEnvironment {
    static var hasRemoteNotificationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("remote-notification")
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.example.app"
    }
}

enum PushPermission {
    static func canDeliver(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    static func title(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not determined"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
}
