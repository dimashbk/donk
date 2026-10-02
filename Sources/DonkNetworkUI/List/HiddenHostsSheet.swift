import Combine
import DonkCore
import DonkUI
import SwiftUI

@MainActor
final class HiddenHostsModel: ObservableObject {
    @Published private(set) var patterns: [String]
    private var cancellable: AnyCancellable?

    init() {
        patterns = NetworkSettingsStore.shared.settings.hiddenHosts
        cancellable = NetworkSettingsStore.shared.changes
            .map(\.hiddenHosts)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.patterns = value
            }
    }

    func add(_ raw: String) -> Bool {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !pattern.isEmpty, !pattern.contains(" ") else { return false }
        var settings = NetworkSettingsStore.shared.settings
        guard !settings.hiddenHosts.contains(where: { $0.lowercased() == pattern }) else { return false }
        settings.hiddenHosts.append(pattern)
        NetworkSettingsStore.shared.settings = settings
        patterns = settings.hiddenHosts
        return true
    }

    func remove(at offsets: IndexSet) {
        var settings = NetworkSettingsStore.shared.settings
        let removing = offsets.compactMap { patterns.indices.contains($0) ? patterns[$0] : nil }
        settings.hiddenHosts.removeAll { removing.contains($0) }
        NetworkSettingsStore.shared.settings = settings
        patterns = settings.hiddenHosts
    }

    func removeAll() {
        var settings = NetworkSettingsStore.shared.settings
        settings.hiddenHosts = []
        NetworkSettingsStore.shared.settings = settings
        patterns = []
    }
}

struct HiddenHostsSheet: View {
    let hosts: [HostCount]
    @StateObject private var model = HiddenHostsModel()
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        DonkNavigationContainer {
            List {
                addSection
                hiddenSection
                if !visibleHosts.isEmpty {
                    seenSection
                }
            }
            .donkListStyle()
            .donkNavigationTitle("Hidden Hosts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !model.patterns.isEmpty {
                        Button("Show All") {
                            DonkHaptics.light()
                            withAnimation { model.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .donkTheme()
    }

    private var addSection: some View {
        Section {
            HStack(spacing: DonkSpacing.s) {
                TextField("analytics.example.com or *.example.com", text: $draft)
                    .font(DonkFont.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button("Hide", action: add)
                    .font(.subheadline.weight(.semibold))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            DonkSectionHeader("Add pattern")
        } footer: {
            Text("Hidden hosts only disappear from this list. Their requests are still captured, exported and matched by rules. Use *.example.com to include subdomains.")
        }
    }

    private var hiddenSection: some View {
        Section {
            if model.patterns.isEmpty {
                HStack(spacing: DonkSpacing.m) {
                    Image(systemName: "eye")
                        .foregroundColor(DonkColor.textTertiary)
                    Text("Nothing is hidden. Swipe a request or use its context menu to hide its host.")
                        .font(.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(model.patterns, id: \.self) { pattern in
                HStack(spacing: DonkSpacing.m) {
                    DonkIconBadge(pattern.contains("*") ? "asterisk.circle" : "eye.slash", tone: .neutral, size: 26)
                    Text(DonkTextBreaking.breakable(pattern))
                        .font(DonkFont.code)
                        .lineLimit(2)
                    Spacer(minLength: DonkSpacing.s)
                    let matched = matchCount(pattern)
                    if matched > 0 {
                        Text(matched == 1 ? "1 request" : "\(DonkFormat.compact(matched)) requests")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(DonkColor.textSecondary)
                    }
                }
                .contextMenu {
                    Button {
                        DonkPasteboard.copy(pattern, label: "Pattern")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            .onDelete { offsets in
                DonkHaptics.light()
                model.remove(at: offsets)
            }
        } header: {
            DonkSectionHeader("Hidden", count: model.patterns.isEmpty ? nil : model.patterns.count)
        }
    }

    private var seenSection: some View {
        Section {
            ForEach(visibleHosts) { item in
                HStack(spacing: DonkSpacing.m) {
                    Text(DonkTextBreaking.breakable(item.host))
                        .font(DonkFont.code)
                        .lineLimit(2)
                    Spacer(minLength: DonkSpacing.s)
                    CountBadge(item.count, tone: .neutral, filled: false)
                    Button {
                        DonkHaptics.light()
                        withAnimation { _ = model.add(item.host) }
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 32, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Hide \(item.host)")
                }
            }
        } header: {
            DonkSectionHeader("Captured hosts", count: visibleHosts.count)
        }
    }

    private var visibleHosts: [HostCount] {
        hosts.filter { !HostPattern.matchesAny($0.host, patterns: model.patterns) }
    }

    private func matchCount(_ pattern: String) -> Int {
        hosts.reduce(0) { HostPattern.matches($1.host, pattern: pattern) ? $0 + $1.count : $0 }
    }

    private func add() {
        if model.add(draft) {
            DonkHaptics.success()
            draft = ""
        } else {
            DonkHaptics.warning()
        }
    }
}
