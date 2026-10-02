import Donk
import DonkUI
import Foundation
import UserNotifications

enum PushDemoPayloads {
    static let actionableCategory = "DONK_ACTIONABLE"

    static let extra: [PushTemplate] = [
        PushTemplate(
            id: UUID(uuidString: "6A1D6B0E-1E0B-4E64-9C3A-0D1E5F7A0001") ?? UUID(),
            name: "Chat message (actions)",
            payload: #"{"aps":{"alert":{"title":"Aruzhan","body":"Are we still on for lunch?"},"sound":"default","category":"DONK_ACTIONABLE","thread-id":"chat-42"},"type":"message","chatId":"42"}"#
        ),
        PushTemplate(
            id: UUID(uuidString: "6A1D6B0E-1E0B-4E64-9C3A-0D1E5F7A0002") ?? UUID(),
            name: "Sign-in alert (time-sensitive)",
            payload: #"{"aps":{"alert":{"title":"Sign-in attempt","body":"Was this you? Confirm within 5 minutes."},"sound":"default","interruption-level":"time-sensitive","relevance-score":1},"type":"security","sessionId":"s-981"}"#
        ),
        PushTemplate(
            id: UUID(uuidString: "6A1D6B0E-1E0B-4E64-9C3A-0D1E5F7A0003") ?? UUID(),
            name: "Badge only",
            payload: #"{"aps":{"badge":3}}"#
        ),
    ]

    static var all: [PushTemplate] {
        DemoPushTemplates.all + extra
    }

    static func isSilent(_ template: PushTemplate) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(template.payload.utf8)) as? [String: Any],
            let aps = object["aps"] as? [String: Any]
        else { return false }
        return (aps["content-available"] as? Int) == 1 && aps["alert"] == nil && aps["badge"] == nil && aps["sound"] == nil
    }

    static func matchingTemplate(for inboxPayload: String) -> PushTemplate? {
        guard let received = dictionary(inboxPayload) else { return nil }
        return all.first { template in
            guard let sent = dictionary(template.payload) else { return false }
            return received.isEqual(sent)
        }
    }

    private static func dictionary(_ text: String) -> NSDictionary? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return object as NSDictionary
    }
}

enum PushDemoBootstrap {
    private static var didStart = false

    static func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        var configuration = PushConfiguration()
        configuration.templates = DemoPushTemplates.all
        DonkPush.start(configuration)
        let read = UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: [])
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let category = UNNotificationCategory(
            identifier: PushDemoPayloads.actionableCategory,
            actions: [reply, read],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        scheduleAutorunIfNeeded()
    }

    private static func scheduleAutorunIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DonkPushAutorun"), arguments.indices.contains(index + 1) else { return }
        let method: PushSimulationMethod
        switch arguments[index + 1] {
        case "tap": method = .tap
        case "silent": method = .silent
        default: method = .inject
        }
        let template = method == .silent ? PushDemoPayloads.all.first(where: PushDemoPayloads.isSilent) : PushDemoPayloads.extra.first
        guard let template else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Donk.show(.push)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Task { @MainActor in
                    let before = DonkEnvironment.isDebuggerVisible
                    let result = await DonkPush.simulate(template.payload, via: method)
                    let after = DonkEnvironment.isDebuggerVisible
                    print("DonkPushAutorun \(arguments[index + 1]): debuggerVisible before=\(before) after=\(after) result=\(result.status.rawValue) \(result.title)")
                    DonkToast.show(result.title, tone: result.status == .success ? .success : .warning, duration: 4)
                }
            }
        }
    }
}
