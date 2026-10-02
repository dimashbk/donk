import DonkCore
import SwiftUI
import UserNotifications

public struct PushTemplate: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var payload: String

    public init(id: UUID = UUID(), name: String, payload: String) {
        self.id = id
        self.name = name
        self.payload = payload
    }
}

public struct PushConfiguration: Sendable {
    public var templates: [PushTemplate] = []
    public var attachmentURLKeyPaths: [String] = ["fcm_options.image", "imageUrl", "image", "attachment-url", "media-url"]
    public var recordsIncomingPushes = true

    public init() {}
}

public enum DonkPush {
    public static func start(_ configuration: PushConfiguration) {
        PushState.shared.configuration = configuration
        if configuration.recordsIncomingPushes {
            PushHooks.shared.install()
        } else {
            PushHooks.shared.isRecording = false
        }
    }

    public static func stop() {
        PushHooks.shared.isRecording = false
    }

    public static func didRegister(deviceToken: Data) {
        PushState.shared.deviceToken = deviceToken
    }

    public static func setFCMToken(_ token: String?) {
        PushState.shared.fcmToken = token
    }

    public static var contentProcessor: (@Sendable (UNMutableNotificationContent) async -> UNNotificationContent)? {
        get { PushState.shared.contentProcessor }
        set { PushState.shared.contentProcessor = newValue }
    }

    public static func attachMedia(to content: UNMutableNotificationContent, keyPaths: [String]? = nil) async -> UNMutableNotificationContent {
        let payload = content.userInfo.reduce(into: [String: Any]()) { result, element in
            if let key = element.key as? String { result[key] = element.value }
        }
        let keyPaths = keyPaths ?? PushState.shared.configuration.attachmentURLKeyPaths
        guard let url = PushJSON.attachmentURL(in: payload, keyPaths: keyPaths),
              let result = try? await PushAttachmentLoader.loadAttachment(from: url)
        else { return content }
        content.attachments.append(result.attachment)
        return content
    }

    public static var deviceTokenHex: String? {
        PushState.shared.deviceToken.map(PushState.hex)
    }

    public static var fcmToken: String? {
        PushState.shared.fcmToken
    }

    public static var isRecording: Bool {
        PushHooks.shared.isRecording
    }

    public static func records() -> [PushRecord] {
        PushHistoryStore.shared.records
    }

    public static func recordCount() -> Int {
        PushHistoryStore.shared.count
    }

    public static func clearHistory() {
        PushHistoryStore.shared.clear()
    }

    @MainActor public static func makeRootView() -> AnyView {
        AnyView(PushRootView())
    }

    @MainActor public static func simulate(_ payload: String, via method: PushSimulationMethod) async -> PushSimulationResult {
        let parsed: PushPayload
        switch PushPayload.parse(payload) {
        case let .success(value):
            parsed = value
        case let .failure(error):
            return PushSimulationResult(status: .failure, title: error.message, lines: [])
        }
        let outcome: PushDeliveryOutcome
        switch method {
        case let .banner(delay):
            outcome = await PushDelivery.scheduleBanner(payload: parsed, delay: delay)
        case .inject:
            outcome = await PushDelivery.inject(payload: parsed, beforeInvoking: .hideDebugger)
        case let .tap(actionIdentifier, userText):
            outcome = await PushDelivery.simulateTap(
                payload: parsed,
                actionIdentifier: actionIdentifier,
                userText: userText,
                beforeInvoking: .hideDebugger
            )
        case .silent:
            outcome = await PushDelivery.silent(payload: parsed, beforeInvoking: .hideDebugger)
        }
        return PushSimulationResult(outcome)
    }
}

public enum PushSimulationMethod: Sendable, Equatable {
    case banner(delay: TimeInterval)
    case inject
    case tap(actionIdentifier: String, userText: String?)
    case silent

    public static var tap: PushSimulationMethod {
        .tap(actionIdentifier: UNNotificationDefaultActionIdentifier, userText: nil)
    }
}

public struct PushSimulationResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case success
        case warning
        case failure
    }

    public var status: Status
    public var title: String
    public var lines: [String]

    public init(status: Status, title: String, lines: [String]) {
        self.status = status
        self.title = title
        self.lines = lines
    }

    init(_ outcome: PushDeliveryOutcome) {
        switch outcome.status {
        case .success: status = .success
        case .warning: status = .warning
        case .failure: status = .failure
        }
        title = outcome.title
        lines = outcome.lines.map { "\($0.key): \($0.value)" } + outcome.steps.map(\.text)
    }
}
