import Combine
import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

struct CookieRecord: Identifiable, Hashable {
    let cookie: HTTPCookie

    var id: String { cookie.domain + "|" + cookie.path + "|" + cookie.name }
    var name: String { cookie.name }
    var value: String { cookie.value }
    var domain: String { cookie.domain }

    var sameSite: String? {
        guard let policy = cookie.sameSitePolicy else { return nil }
        switch policy {
        case .sameSiteLax: return "Lax"
        case .sameSiteStrict: return "Strict"
        default: return policy.rawValue
        }
    }

    var expiryText: String {
        guard let date = cookie.expiresDate else { return "Session" }
        return date < Date() ? "Expired " + StorageFormat.dateTime(date) : StorageFormat.dateTime(date)
    }

    var headerValue: String {
        cookie.name + "=" + cookie.value
    }

    var setCookieValue: String {
        var parts = [headerValue, "Domain=\(cookie.domain)", "Path=\(cookie.path)"]
        if let date = cookie.expiresDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            parts.append("Expires=" + formatter.string(from: date))
        }
        if cookie.isSecure { parts.append("Secure") }
        if cookie.isHTTPOnly { parts.append("HttpOnly") }
        if let sameSite { parts.append("SameSite=\(sameSite)") }
        return parts.joined(separator: "; ")
    }
}

@MainActor
final class CookiesModel: ObservableObject {
    @Published private(set) var records: [CookieRecord] = []
    @Published private(set) var hasLoaded = false
    @Published var query = ""
    private var cancellable: AnyCancellable?

    init() {
        cancellable = NotificationCenter.default.publisher(for: .NSHTTPCookieManagerCookiesChanged)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.reload() }
    }

    var sections: [(String, [CookieRecord])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = trimmed.isEmpty ? records : records.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.domain.localizedCaseInsensitiveContains(trimmed)
                || $0.value.localizedCaseInsensitiveContains(trimmed)
        }
        let grouped = Dictionary(grouping: visible) { record -> String in
            record.domain.hasPrefix(".") ? String(record.domain.dropFirst()) : record.domain
        }
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, grouped[$0] ?? []) }
    }

    func reload() {
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        records = cookies.map(CookieRecord.init).sorted { lhs, rhs in
            if lhs.domain != rhs.domain { return lhs.domain < rhs.domain }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        hasLoaded = true
    }

    func record(_ id: String) -> CookieRecord? {
        records.first { $0.id == id }
    }

    func delete(_ record: CookieRecord) {
        HTTPCookieStorage.shared.deleteCookie(record.cookie)
        reload()
        DonkHaptics.success()
        DonkToast.show("Cookie deleted", icon: "trash.fill", tone: .success)
    }

    func clearAll() {
        let storage = HTTPCookieStorage.shared
        storage.cookies?.forEach(storage.deleteCookie)
        reload()
        DonkHaptics.success()
        DonkToast.show("All cookies removed", tone: .success)
    }
}

// MARK: - List

struct CookiesListView: View {
    @StateObject private var model = CookiesModel()
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            let sections = model.sections
            if sections.isEmpty {
                Section {
                    EmptyStateView(
                        icon: model.query.isEmpty ? "globe" : "magnifyingglass",
                        title: model.query.isEmpty ? "No cookies" : "No matches",
                        message: model.query.isEmpty
                            ? "Cookies stored in HTTPCookieStorage.shared appear here."
                            : "Nothing matches “\(model.query)”.",
                        tone: .web
                    )
                    .frame(minHeight: 320)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(sections, id: \.0) { domain, records in
                    Section {
                        ForEach(records) { record in
                            NavigationLink {
                                CookieDetailView(model: model, recordID: record.id)
                            } label: {
                                CookieRow(record: record)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { model.delete(record) } label: { Label("Delete", systemImage: "trash") }
                                    .tint(DonkColor.error)
                            }
                            .contextMenu {
                                Button { DonkPasteboard.copy(record.value, label: "Value") } label: {
                                    Label("Copy Value", systemImage: "doc.on.doc")
                                }
                                Button { DonkPasteboard.copy(record.headerValue, label: "Cookie") } label: {
                                    Label("Copy name=value", systemImage: "link")
                                }
                                Divider()
                                Button(role: .destructive) { model.delete(record) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        DonkSectionHeader(domain, icon: "globe", count: records.count)
                    }
                }
            }
        }
        .donkListStyle()
        .donkNavigationTitle("HTTP Cookies")
        .searchable(text: $model.query, prompt: "Search name, domain, value")
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .refreshable { model.reload() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Text("Clear All")
                        .foregroundColor(model.records.isEmpty ? DonkColor.textTertiary : DonkColor.error)
                }
                .disabled(model.records.isEmpty)
            }
        }
        .confirmationDialog("Remove all cookies?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Remove \(model.records.count) Cookies", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every cookie in HTTPCookieStorage.shared is deleted.")
        }
        .onAppear { model.reload() }
    }
}

struct CookieRow: View {
    let record: CookieRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.name)
                    .font(DonkFont.code(.subheadline, weight: .semibold))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DonkSpacing.xs)
                if record.cookie.isSecure {
                    TonePill(text: "Secure", tone: .success)
                }
                if record.cookie.isHTTPOnly {
                    TonePill(text: "HttpOnly", tone: .info)
                }
            }
            Text(record.value.isEmpty ? "Empty value" : record.value)
                .font(DonkFont.codeCaption)
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(record.cookie.path + " · " + record.expiryText)
                .font(.caption2)
                .foregroundColor(DonkColor.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct CookieDetailView: View {
    @ObservedObject var model: CookiesModel
    let recordID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let record = model.record(recordID) {
                content(record)
            } else {
                EmptyStateView(icon: "globe", title: "Cookie not found", message: "It may have been deleted or expired.", tone: .neutral)
                    .donkScreenBackground()
            }
        }
        .donkNavigationTitle(model.record(recordID)?.name ?? "Cookie")
    }

    private func content(_ record: CookieRecord) -> some View {
        DonkScrollContainer {
            DonkCard(title: "Value", icon: "doc.text.fill", tone: .web) {
                if record.value.isEmpty {
                    Text("Empty value")
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                } else {
                    CodeView(text: record.value)
                }
            } accessory: {
                CopyButton(text: record.value, label: "Value")
            }
            DonkCard(title: "Attributes", icon: "list.bullet.rectangle", tone: .info) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Name", value: record.name, monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Domain", value: record.domain, monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Path", value: record.cookie.path, monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Expires", value: record.expiryText)
                    Divider()
                    KeyValueRow(key: "Secure", value: record.cookie.isSecure ? "Yes" : "No", valueTone: record.cookie.isSecure ? .success : nil)
                    Divider()
                    KeyValueRow(key: "HttpOnly", value: record.cookie.isHTTPOnly ? "Yes" : "No", valueTone: record.cookie.isHTTPOnly ? .info : nil)
                    Divider()
                    KeyValueRow(key: "SameSite", value: record.sameSite ?? "Not set")
                    if let ports = record.cookie.portList, !ports.isEmpty {
                        Divider()
                        KeyValueRow(key: "Ports", value: ports.map { $0.stringValue }.joined(separator: ", "))
                    }
                    if let comment = record.cookie.comment {
                        Divider()
                        KeyValueRow(key: "Comment", value: comment)
                    }
                    Divider()
                    KeyValueRow(key: "Version", value: "\(record.cookie.version)")
                }
            }
            DonkCard(title: "Header", icon: "chevron.left.forwardslash.chevron.right", tone: .accent) {
                CodeView(text: record.setCookieValue)
            } accessory: {
                CopyButton(text: record.setCookieValue, label: "Set-Cookie")
            }
            Button(role: .destructive) {
                model.delete(record)
                dismiss()
            } label: {
                Label("Delete Cookie", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(DonkColor.error)
        }
    }
}
