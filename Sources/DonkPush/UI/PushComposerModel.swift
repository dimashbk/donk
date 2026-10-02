import DonkCore
import DonkUI
import SwiftUI
import UserNotifications

enum PushDeliveryMode: String, CaseIterable, Hashable {
    case banner = "Banner"
    case inject = "Inject"
    case silent = "Silent"
    case export = "Export"

    var headline: String {
        switch self {
        case .banner: return "System banner"
        case .inject: return "Inject into delegate"
        case .silent: return "Background delivery"
        case .export: return "Push from your Mac"
        }
    }

    var explanation: String {
        switch self {
        case .banner:
            return "Schedules a local notification with the same content and the unchanged payload as userInfo. It takes the real system path: willPresent in the foreground, a banner in the background, didReceive on tap and a cold start if the app was killed. The Notification Service Extension does not run, so mutable-content is emulated in-process."
        case .inject:
            return "Calls your UNUserNotificationCenterDelegate directly with a synthesized UNNotification (UNPushNotificationTrigger when available) and shows the presentation options it returns. Simulate a tap to call didReceive with any action."
        case .silent:
            return "Calls application(_:didReceiveRemoteNotification:fetchCompletionHandler:) on your app delegate with the payload, like a content-available push, and measures the completion."
        case .export:
            return "Shares a .apns file for xcrun simctl push or drag-and-drop onto the Simulator. This uses the Simulator's real remote-notification path, so the trigger is UNPushNotificationTrigger."
        }
    }
}

enum PushDelayOption: String, CaseIterable, Hashable {
    case one = "1 s"
    case five = "5 s"
    case ten = "10 s"
    case custom = "Custom"

    var seconds: TimeInterval? {
        switch self {
        case .one: return 1
        case .five: return 5
        case .ten: return 10
        case .custom: return nil
        }
    }
}

enum PushTapKind: String, CaseIterable, Hashable {
    case open = "Open"
    case action = "Action"
    case reply = "Text reply"
}

@MainActor
final class PushComposerModel: ObservableObject {
    @Published var text: String {
        didSet {
            if text != oldValue {
                reparse()
            }
        }
    }
    @Published private(set) var payload: PushPayload?
    @Published private(set) var parseError: String?
    @Published private(set) var mapped = PushMappedContent()
    @Published private(set) var imageURL: URL?
    @Published private(set) var templateName: String?
    @Published var mode: PushDeliveryMode = .banner {
        didSet {
            if mode != oldValue {
                outcome = nil
            }
        }
    }
    @Published var delay: PushDelayOption = .one
    @Published var customDelay: Double = 30
    @Published var tapKind: PushTapKind = .open
    @Published var actionIdentifier = ""
    @Published var replyText = "On my way"
    @Published var includesTargetBundle = true
    @Published var keepsDebuggerOpen = false
    @Published private(set) var isBusy = false
    @Published private(set) var outcome: PushDeliveryOutcome?

    init() {
        let template = PushBuiltInTemplates.all[0]
        text = template.payload
        templateName = template.name
        reparse()
    }

    var delaySeconds: TimeInterval {
        delay.seconds ?? max(1, customDelay.rounded())
    }

    var keyPaths: [String] {
        PushState.shared.configuration.attachmentURLKeyPaths
    }

    var showsAttachmentPreview: Bool {
        imageURL != nil && mapped.isMutableContent
    }

    func load(text newText: String, name: String?) {
        text = JSONFormatting.pretty(newText) ?? newText
        templateName = name
        outcome = nil
    }

    func prettify() {
        guard let pretty = payload?.value.prettyPrinted(), pretty != text else { return }
        text = pretty
    }

    func warnings(categories: [String: [UNNotificationAction]], categoriesLoaded: Bool) -> [PushStep] {
        guard let payload else { return [] }
        var result: [PushStep] = []
        if !payload.hasAPS && mode != .silent {
            result.append(PushStep(.warning, "No \"aps\" dictionary. iOS will not show anything for this payload; only Silent or Inject make sense."))
        }
        if payload.byteCount > PushPayload.apnsSizeLimit {
            result.append(PushStep(.warning, "Payload is \(DonkFormat.bytes(payload.byteCount)). APNs rejects payloads over 4 KB."))
        }
        if payload.isSilent && mode == .banner {
            result.append(PushStep(.info, "Silent payload: the system shows no banner. Use Silent to call the background handler."))
        }
        if mode == .silent && !payload.isContentAvailable {
            result.append(PushStep(.info, "aps.content-available is not 1. A real push like this would not wake the app in the background."))
        }
        if mapped.isMutableContent && PushState.shared.contentProcessor == nil && imageURL == nil {
            result.append(PushStep(.info, "mutable-content is 1, but no attachment URL was found at \(keyPaths.joined(separator: ", "))."))
        }
        if imageURL != nil && !mapped.isMutableContent {
            result.append(PushStep(.warning, "An image URL is present, but mutable-content is not 1, so a Notification Service Extension would not run and no image would be attached."))
        }
        if categoriesLoaded, !mapped.categoryIdentifier.isEmpty, categories[mapped.categoryIdentifier] == nil {
            result.append(PushStep(.warning, "Category \"\(mapped.categoryIdentifier)\" is not registered by the app, so no actions will appear."))
        }
        if mapped.interruptionLevel == .timeSensitive || mapped.interruptionLevel == .critical {
            result.append(PushStep(.info, "\(mapped.interruptionLevel?.title ?? "") notifications need the matching entitlement on a device."))
        }
        return result
    }

    func send() {
        guard let payload, !isBusy, mode != .export else { return }
        isBusy = true
        outcome = nil
        let mode = mode
        let delay = delaySeconds
        let handoff = currentHandoff
        let announces = mode != .banner && handoff.isEnabled && DonkEnvironment.isDebuggerVisible
        Task {
            let result: PushDeliveryOutcome
            switch mode {
            case .banner:
                result = await PushDelivery.scheduleBanner(payload: payload, delay: delay)
            case .inject:
                result = await PushDelivery.inject(payload: payload, beforeInvoking: handoff)
            case .silent:
                result = await PushDelivery.silent(payload: payload, beforeInvoking: handoff)
            case .export:
                return
            }
            finish(result, announces: announces)
        }
    }

    func simulateTap() {
        guard let payload, !isBusy else { return }
        isBusy = true
        outcome = nil
        let identifier: String
        var userText: String?
        switch tapKind {
        case .open:
            identifier = UNNotificationDefaultActionIdentifier
        case .action:
            identifier = actionIdentifier.trimmingCharacters(in: .whitespaces).nonEmpty ?? UNNotificationDefaultActionIdentifier
        case .reply:
            identifier = actionIdentifier.trimmingCharacters(in: .whitespaces).nonEmpty ?? "REPLY"
            userText = replyText
        }
        let handoff = currentHandoff
        let announces = handoff.isEnabled && DonkEnvironment.isDebuggerVisible
        Task {
            let result = await PushDelivery.simulateTap(
                payload: payload,
                actionIdentifier: identifier,
                userText: userText,
                beforeInvoking: handoff
            )
            finish(result, announces: announces)
        }
    }

    var apnsFileContents: String {
        guard let payload else { return "" }
        return PushAPNsExport.fileContents(
            payload: payload.value,
            bundleID: includesTargetBundle ? PushEnvironment.bundleIdentifier : nil
        )
    }

    var simctlCommand: String {
        PushAPNsExport.command(bundleID: PushEnvironment.bundleIdentifier)
    }

    func shareAPNsFile() {
        guard payload != nil else { return }
        DonkShare.share(fileNamed: PushAPNsExport.fileName, data: Data(apnsFileContents.utf8))
    }

    private var currentHandoff: PushHandoff {
        keepsDebuggerOpen ? .inPlace : .hideDebugger
    }

    private func finish(_ result: PushDeliveryOutcome, announces: Bool = false) {
        outcome = result
        isBusy = false
        switch result.status {
        case .success:
            DonkHaptics.success()
        case .warning:
            DonkHaptics.warning()
        case .failure:
            DonkHaptics.error()
        }
        if announces && !DonkEnvironment.isDebuggerVisible {
            DonkToast.show(Self.toastText(result), tone: Self.tone(result.status), duration: 3.5)
        }
    }

    static func toastText(_ result: PushDeliveryOutcome) -> String {
        guard let line = result.lines.first else { return result.title }
        return "\(result.title) · \(line.key): \(line.value)"
    }

    static func tone(_ status: PushDeliveryOutcome.Status) -> DonkTone {
        switch status {
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }

    private func reparse() {
        switch PushPayload.parse(text) {
        case let .success(value):
            payload = value
            parseError = nil
            mapped = PushContentMapper.map(value.dictionary)
            imageURL = value.attachmentURL(keyPaths: keyPaths)
        case let .failure(error):
            payload = nil
            parseError = error.message
        }
    }
}
