import Combine
import DonkCore
import DonkUI
import SwiftUI
import UIKit
import UserNotifications

enum PushTab: String, CaseIterable, Hashable {
    case compose = "Compose"
    case history = "History"
    case templates = "Templates"

    var icon: String {
        switch self {
        case .compose: return "square.and.pencil"
        case .history: return "clock.arrow.circlepath"
        case .templates: return "doc.on.doc"
        }
    }
}

// MARK: - Root

@MainActor
final class PushRootModel: ObservableObject {
    @Published var tab: PushTab = .compose {
        didSet {
            if tab == .history {
                unseenCount = 0
            }
        }
    }
    @Published private(set) var unseenCount = 0

    let composer = PushComposerModel()
    let history = PushHistoryModel()
    let templates = PushTemplatesModel()
    let device = PushDeviceModel()

    private var cancellables = Set<AnyCancellable>()

    init() {
        history.$latestInsertCount
            .dropFirst()
            .sink { [weak self] added in
                guard let self, added > 0, self.tab != .history else { return }
                self.unseenCount += added
            }
            .store(in: &cancellables)
    }

    func open(payload: String, name: String?) {
        composer.load(text: payload, name: name)
        tab = .compose
    }
}

// MARK: - History

struct PushHistoryItem: Identifiable, Equatable {
    var record: PushRecord
    var title: String
    var detail: String

    var id: UUID { record.id }

    init(record: PushRecord) {
        self.record = record
        let summary = PushSummary(payloadText: record.payload)
        title = summary.title
        detail = summary.detail
    }
}

struct PushSummary {
    var title: String
    var detail: String

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(payloadText: String) {
        guard case let .success(payload) = PushPayload.parse(payloadText) else {
            self.init(title: "Unreadable payload", detail: "")
            return
        }
        self.init(payload: payload)
    }

    init(payload: PushPayload) {
        let mapped = PushContentMapper.map(payload.dictionary)
        let custom = payload.dictionary
            .filter { $0.key != "aps" }
            .sorted { $0.key < $1.key }
            .prefix(3)
            .map { "\($0.key): \(PushJSON.value(from: $0.value).compact())" }
            .joined(separator: " · ")
        if mapped.hasAlert {
            let lines = [mapped.title, mapped.subtitle, mapped.body].filter { !$0.isEmpty }
            let rest = lines.dropFirst().joined(separator: " · ")
            self.init(title: lines.first ?? "", detail: rest.nonEmpty ?? custom)
        } else if mapped.isContentAvailable {
            self.init(title: "Silent push", detail: custom)
        } else if let badge = mapped.badge {
            self.init(title: "Badge \(badge)", detail: custom)
        } else if mapped.sound != nil {
            self.init(title: "Sound only", detail: custom)
        } else {
            self.init(title: mapped.hasAPS ? "No visible content" : "No aps dictionary", detail: custom)
        }
    }
}

enum PushHistoryFilter: String, CaseIterable, Hashable {
    case all = "All"
    case foreground = "Foreground"
    case tap = "Tap"
    case silent = "Silent"
    case simulated = "Simulated"

    func matches(_ record: PushRecord) -> Bool {
        switch self {
        case .all: return true
        case .foreground: return record.path == .foreground
        case .tap: return record.path == .tap
        case .silent: return record.path == .silent
        case .simulated: return record.isSimulated
        }
    }
}

@MainActor
final class PushHistoryModel: ObservableObject {
    @Published private(set) var items: [PushHistoryItem] = []
    @Published private(set) var latestInsertCount = 0
    @Published var filter: PushHistoryFilter = .all

    private let store: PushHistoryStore
    private var cancellable: AnyCancellable?

    init(store: PushHistoryStore = .shared) {
        self.store = store
        items = store.records.map(PushHistoryItem.init)
        cancellable = store.changes
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] records in
                self?.apply(records)
            }
    }

    var isRecording: Bool {
        PushHooks.shared.isRecording
    }

    var filteredItems: [PushHistoryItem] {
        items.filter { filter.matches($0.record) }
    }

    func count(for filter: PushHistoryFilter) -> Int {
        items.filter { filter.matches($0.record) }.count
    }

    func delete(_ ids: Set<UUID>) {
        store.remove(ids)
    }

    func clear() {
        store.clear()
    }

    private func apply(_ records: [PushRecord]) {
        let known = Set(items.map(\.id))
        let added = records.filter { !known.contains($0.id) }.count
        var cache = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = records.map { record in
            if var cached = cache.removeValue(forKey: record.id) {
                if cached.record != record {
                    cached = PushHistoryItem(record: record)
                }
                return cached
            }
            return PushHistoryItem(record: record)
        }
        latestInsertCount = added
    }
}

// MARK: - Templates

struct PushTemplateItem: Identifiable, Equatable {
    enum Source: Equatable {
        case builtIn
        case host
        case saved
    }

    var template: PushTemplate
    var source: Source
    var summary: String
    var icon: String
    var tone: DonkTone

    var id: UUID { template.id }

    init(template: PushTemplate, source: Source) {
        self.template = template
        self.source = source
        switch PushPayload.parse(template.payload) {
        case let .success(payload):
            let summary = PushSummary(payload: payload)
            self.summary = summary.detail.isEmpty ? summary.title : "\(summary.title) — \(summary.detail)"
            let mapped = PushContentMapper.map(payload.dictionary)
            if payload.isSilent {
                icon = "moon.zzz"
                tone = .grpc
            } else if payload.isMutableContent,
                      payload.attachmentURL(keyPaths: PushState.shared.configuration.attachmentURLKeyPaths) != nil {
                icon = "photo"
                tone = .web
            } else if !mapped.categoryIdentifier.isEmpty {
                icon = "hand.tap"
                tone = .success
            } else if mapped.interruptionLevel == .timeSensitive || mapped.interruptionLevel == .critical {
                icon = "exclamationmark.circle"
                tone = .warning
            } else if !mapped.hasAlert && mapped.badge != nil {
                icon = "app.badge"
                tone = .error
            } else {
                icon = "bell.badge"
                tone = .info
            }
        case let .failure(error):
            summary = error.message
            icon = "exclamationmark.triangle"
            tone = .error
        }
    }
}

@MainActor
final class PushTemplatesModel: ObservableObject {
    @Published private(set) var builtIn: [PushTemplateItem]
    @Published private(set) var host: [PushTemplateItem] = []
    @Published private(set) var saved: [PushTemplateItem] = []

    private let store: PushTemplateStore
    private var cancellables = Set<AnyCancellable>()

    init(store: PushTemplateStore = .shared) {
        self.store = store
        builtIn = PushBuiltInTemplates.all.map { PushTemplateItem(template: $0, source: .builtIn) }
        reloadHost()
        saved = store.templates.map { PushTemplateItem(template: $0, source: .saved) }
        store.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] templates in
                self?.saved = templates.map { PushTemplateItem(template: $0, source: .saved) }
            }
            .store(in: &cancellables)
        PushState.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reloadHost() }
            .store(in: &cancellables)
    }

    var all: [PushTemplateItem] {
        builtIn + host + saved
    }

    func save(name: String, payload: String) {
        store.add(name: name, payload: payload)
    }

    func rename(_ id: UUID, to name: String) {
        store.rename(id, to: name)
    }

    func delete(_ id: UUID) {
        store.remove(id)
    }

    private func reloadHost() {
        let templates = PushState.shared.configuration.templates
        let items = templates.map { PushTemplateItem(template: $0, source: .host) }
        if items != host {
            host = items
        }
    }
}

// MARK: - Device

@MainActor
final class PushDeviceModel: ObservableObject {
    @Published private(set) var deviceToken: String?
    @Published private(set) var fcmToken: String?
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var alertsEnabled = true
    @Published private(set) var isLoaded = false
    @Published private(set) var categories: [String: [UNNotificationAction]] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        readTokens()
        PushState.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.readTokens() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
            .store(in: &cancellables)
    }

    var canDeliver: Bool {
        PushPermission.canDeliver(status)
    }

    var statusTitle: String {
        isLoaded ? PushPermission.title(status) : "Checking…"
    }

    var statusTone: DonkTone {
        guard isLoaded else { return .neutral }
        switch status {
        case .authorized: return alertsEnabled ? .success : .warning
        case .provisional, .ephemeral: return .info
        case .denied: return .error
        case .notDetermined: return .warning
        @unknown default: return .neutral
        }
    }

    func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        alertsEnabled = settings.alertSetting != .disabled
        isLoaded = true
        let registered = await center.notificationCategories()
        categories = Dictionary(registered.map { ($0.identifier, $0.actions) }, uniquingKeysWith: { first, _ in first })
    }

    func requestAuthorization() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        DonkHaptics.selection()
        if granted {
            DonkToast.show("Notifications allowed", tone: .success)
        }
        await refresh()
    }

    func openSettings() {
        let urlString: String
        if #available(iOS 16.0, *) {
            urlString = UIApplication.openNotificationSettingsURLString
        } else {
            urlString = UIApplication.openSettingsURLString
        }
        guard let url = URL(string: urlString), let application = PushHooks.sharedApplication() else { return }
        application.open(url)
    }

    func registerForRemoteNotifications() {
        PushHooks.sharedApplication()?.registerForRemoteNotifications()
        DonkToast.show("Registering for remote notifications", icon: "antenna.radiowaves.left.and.right", tone: .info)
    }

    private func readTokens() {
        let token = DonkPush.deviceTokenHex
        let fcm = DonkPush.fcmToken
        if token != deviceToken { deviceToken = token }
        if fcm != fcmToken { fcmToken = fcm }
    }
}
