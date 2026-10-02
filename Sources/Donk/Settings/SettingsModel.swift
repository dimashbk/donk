import Combine
import DonkCore
import DonkCrash
import DonkNetwork
import DonkUI
import Foundation
import UIKit

// MARK: - Options

struct SettingsOption<Value: Hashable>: Hashable {
    var value: Value
    var title: String
}

enum SettingsOptions {
    static let bodySizes: [SettingsOption<Int>] = [
        SettingsOption(value: 512 * 1024, title: "512 KB"),
        SettingsOption(value: 1024 * 1024, title: "1 MB"),
        SettingsOption(value: 2 * 1024 * 1024, title: "2 MB"),
        SettingsOption(value: 5 * 1024 * 1024, title: "5 MB"),
        SettingsOption(value: 10 * 1024 * 1024, title: "10 MB"),
    ]

    static let limits: [SettingsOption<Int>] = [500, 1000, 2000, 5000].map {
        SettingsOption(value: $0, title: DonkFormat.number($0))
    }

    static let timeouts: [SettingsOption<TimeInterval>] = [
        SettingsOption(value: 30, title: "30 seconds"),
        SettingsOption(value: 60, title: "1 minute"),
        SettingsOption(value: 120, title: "2 minutes"),
        SettingsOption(value: 300, title: "5 minutes"),
        SettingsOption(value: 600, title: "10 minutes"),
        SettingsOption(value: 0, title: "Never"),
    ]

    static func title<Value: Hashable>(for value: Value, in options: [SettingsOption<Value>], fallback: (Value) -> String) -> String {
        options.first { $0.value == value }?.title ?? fallback(value)
    }
}

// MARK: - Editable lists

enum HostListKind: String, Identifiable, CaseIterable {
    case bypass, hidden, redactedHeaders, redactedKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bypass: return "Bypass Hosts"
        case .hidden: return "Hidden Hosts"
        case .redactedHeaders: return "Redacted Headers"
        case .redactedKeys: return "Redacted Keys"
        }
    }

    var explanation: String {
        switch self {
        case .bypass:
            return "Requests to these hosts are never intercepted: no capture, rules or breakpoints. Use it for traffic that must stay untouched, like analytics or streaming."
        case .hidden:
            return "Requests to these hosts are still captured, but hidden from the network list and counters."
        case .redactedHeaders:
            return "Values of these headers and gRPC metadata keys are replaced with •••• in exports and masked in header lists while redaction is on."
        case .redactedKeys:
            return "Values of these JSON keys, query and form fields and protobuf text fields are replaced with •••• in exports while redaction is on."
        }
    }

    var hint: String {
        switch self {
        case .bypass, .hidden: return "Use * for any host or *.domain.com to include every subdomain."
        case .redactedHeaders: return "Header names match case-insensitively."
        case .redactedKeys: return "Keys match case-insensitively. A form field like user[password] matches password."
        }
    }

    var icon: String {
        switch self {
        case .bypass: return "arrow.triangle.branch"
        case .hidden: return "eye.slash"
        case .redactedHeaders: return "list.bullet.rectangle"
        case .redactedKeys: return "key"
        }
    }

    var tone: DonkTone {
        switch self {
        case .bypass: return .warning
        case .hidden: return .neutral
        case .redactedHeaders: return .accent
        case .redactedKeys: return .grpc
        }
    }

    var placeholder: String {
        switch self {
        case .bypass, .hidden: return "api.example.com or *.example.com"
        case .redactedHeaders: return "x-session-id"
        case .redactedKeys: return "sessionToken"
        }
    }

    var addHeader: String {
        switch self {
        case .bypass, .hidden: return "Add pattern"
        case .redactedHeaders: return "Add header"
        case .redactedKeys: return "Add key"
        }
    }

    var listHeader: String {
        switch self {
        case .bypass, .hidden: return "Patterns"
        case .redactedHeaders: return "Headers"
        case .redactedKeys: return "Keys"
        }
    }

    var itemLabel: String {
        switch self {
        case .bypass, .hidden: return "Pattern"
        case .redactedHeaders: return "Header"
        case .redactedKeys: return "Key"
        }
    }

    var emptyTitle: String {
        switch self {
        case .bypass, .hidden: return "No patterns yet"
        case .redactedHeaders: return "No headers"
        case .redactedKeys: return "No keys"
        }
    }

    var emptyMessage: String {
        switch self {
        case .bypass: return "Every request is captured."
        case .hidden: return "Every captured request is listed."
        case .redactedHeaders: return "Header values are exported as captured."
        case .redactedKeys: return "Body and query values are exported as captured."
        }
    }

    var invalidMessage: String {
        switch self {
        case .bypass, .hidden: return "Enter a host like api.example.com"
        case .redactedHeaders: return "Enter a header name like x-api-key"
        case .redactedKeys: return "Enter a key like password"
        }
    }

    var suggestionsHeader: String {
        switch self {
        case .bypass, .hidden: return "Captured hosts"
        case .redactedHeaders, .redactedKeys: return "Defaults"
        }
    }

    var suggestionsIcon: String {
        switch self {
        case .bypass, .hidden: return "network"
        case .redactedHeaders, .redactedKeys: return "arrow.counterclockwise"
        }
    }

    var isHostList: Bool {
        self == .bypass || self == .hidden
    }

    var keyboardType: UIKeyboardType {
        isHostList ? .URL : .asciiCapable
    }

    func normalize(_ raw: String) -> String? {
        switch self {
        case .bypass, .hidden: return HostPatternInput.normalize(raw)
        case .redactedHeaders: return RedactionInput.normalizeHeader(raw)
        case .redactedKeys: return RedactionInput.normalizeKey(raw)
        }
    }
}

enum RedactionInput {
    static func normalizeHeader(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(":") {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    static func normalizeKey(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        return text
    }
}

enum HostPatternInput {
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if let colon = text.lastIndex(of: ":"), !text.contains("]"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.*?:[]_")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !text.hasPrefix("."), !text.contains("..") else { return nil }
        return text
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var preferences: DonkPreferences
    @Published private(set) var network: NetworkSettings
    @Published private(set) var capturedHosts: [String] = []

    private var cancellables: [AnyCancellable] = []

    init() {
        preferences = DonkPreferencesStore.shared.value
        network = NetworkSettingsStore.shared.settings
        cancellables = [
            DonkPreferencesStore.shared.changes
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    MainActor.assumeIsolated { self?.preferences = value }
                },
            NetworkSettingsStore.shared.changes
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    MainActor.assumeIsolated { self?.network = value }
                },
        ]
    }

    // MARK: - Launcher

    var showsBubble: Bool {
        preferences.showsBubble ?? DonkRuntime.shared.defaultShowsBubble
    }

    var opensOnShake: Bool {
        preferences.opensOnShake ?? DonkRuntime.shared.defaultOpensOnShake
    }

    func setShowsBubble(_ value: Bool) {
        DonkHaptics.light()
        DonkPreferencesStore.shared.update { $0.showsBubble = value }
        if value {
            DonkRuntime.shared.launcher.restore()
        }
    }

    func setOpensOnShake(_ value: Bool) {
        DonkHaptics.light()
        DonkPreferencesStore.shared.update { $0.opensOnShake = value }
    }

    // MARK: - Network

    var captureEnabled: Bool {
        preferences.captureEnabled
    }

    func setCaptureEnabled(_ value: Bool) {
        DonkHaptics.light()
        DonkPreferencesStore.shared.update { $0.captureEnabled = value }
        DonkLiveSettings.apply(DonkPreferencesStore.shared.value)
    }

    func setMaxBodySize(_ value: Int) {
        DonkHaptics.selection()
        updateNetwork { $0.maxBodySize = value }
    }

    func setLimit(_ value: Int) {
        DonkHaptics.selection()
        updateNetwork { $0.limit = value }
    }

    func items(_ kind: HostListKind) -> [String] {
        switch kind {
        case .bypass: return network.bypassHosts
        case .hidden: return network.hiddenHosts
        case .redactedHeaders: return network.redaction.headers
        case .redactedKeys: return network.redaction.keys
        }
    }

    func suggestions(_ kind: HostListKind) -> [String] {
        let existing = Set(items(kind).map { $0.lowercased() })
        let source: [String]
        switch kind {
        case .bypass, .hidden: source = capturedHosts
        case .redactedHeaders: source = RedactionPolicy.defaultHeaders
        case .redactedKeys: source = RedactionPolicy.defaultKeys
        }
        return Array(source.filter { !existing.contains($0.lowercased()) }.prefix(12))
    }

    @discardableResult
    func addItem(_ raw: String, to kind: HostListKind) -> Bool {
        guard let value = kind.normalize(raw) else { return false }
        guard !items(kind).contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            DonkToast.show("\(value) is already in the list", tone: .warning, duration: 1.6)
            return false
        }
        DonkHaptics.light()
        updateItems(kind) { $0.append(value) }
        return true
    }

    func removeItems(at offsets: IndexSet, from kind: HostListKind) {
        updateItems(kind) { $0.remove(atOffsets: offsets) }
    }

    func removeItem(_ value: String, from kind: HostListKind) {
        updateItems(kind) { $0.removeAll { $0 == value } }
    }

    func moveItems(from source: IndexSet, to destination: Int, in kind: HostListKind) {
        updateItems(kind) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    private func updateItems(_ kind: HostListKind, _ change: (inout [String]) -> Void) {
        updateNetwork { settings in
            switch kind {
            case .bypass: change(&settings.bypassHosts)
            case .hidden: change(&settings.hiddenHosts)
            case .redactedHeaders: change(&settings.redaction.headers)
            case .redactedKeys: change(&settings.redaction.keys)
            }
        }
    }

    // MARK: - Redaction

    var redactsExports: Bool {
        network.redactsExports
    }

    var usesDefaultRedaction: Bool {
        network.redaction == .default
    }

    func setRedactsExports(_ value: Bool) {
        DonkHaptics.light()
        updateNetwork { $0.redactsExports = value }
    }

    func restoreDefaultRedaction() {
        DonkHaptics.success()
        updateNetwork { $0.redaction = .default }
        DonkToast.show("Redaction defaults restored", tone: .success, duration: 1.6)
    }

    func loadCapturedHosts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hosts = NetworkStore.shared.hosts
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.capturedHosts = hosts }
            }
        }
    }

    private func updateNetwork(_ change: (inout NetworkSettings) -> Void) {
        var copy = NetworkSettingsStore.shared.settings
        change(&copy)
        NetworkSettingsStore.shared.settings = copy
        network = copy
    }

    // MARK: - Breakpoints

    var breakpointTimeout: TimeInterval {
        preferences.breakpointTimeout
    }

    func setBreakpointTimeout(_ value: TimeInterval) {
        DonkHaptics.selection()
        DonkPreferencesStore.shared.update { $0.breakpointTimeout = value }
        DonkLiveSettings.apply(DonkPreferencesStore.shared.value)
    }

    // MARK: - Reset

    func resetAll() {
        NetworkStore.shared.clear(keepPinned: false)
        RuleStore.shared.removeAll()
        RuleStore.shared.isEnabled = true
        NetworkSettingsStore.shared.settings = .default
        DonkPreferencesStore.shared.reset()
        DonkLiveSettings.apply(DonkPreferencesStore.shared.value)
        DonkRuntime.shared.launcher.model.placement = DonkPreferencesStore.shared.value.bubble
        DonkRuntime.shared.launcher.restore()
        network = NetworkSettingsStore.shared.settings
        preferences = DonkPreferencesStore.shared.value
        DonkHaptics.success()
        DonkToast.show("donk data reset", tone: .success)
    }

    // MARK: - About

    var isCaptureRunning: Bool {
        DonkNetworkCapture.isRunning
    }

    var isCrashReporterInstalled: Bool {
        DonkCrash.isInstalled
    }

    var dataDirectory: String {
        DonkPersistence.directory.path
    }
}
