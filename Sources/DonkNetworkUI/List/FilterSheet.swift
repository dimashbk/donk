import DonkCore
import DonkUI
import SwiftUI

struct FilterSheet: View {
    @ObservedObject var model: NetworkListModel
    @Environment(\.dismiss) private var dismiss
    @State private var hostQuery = ""

    var body: some View {
        DonkNavigationContainer {
            List {
                kindSection
                statusSection
                optionsSection
                hostsSection
            }
            .donkListStyle()
            .donkNavigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        DonkHaptics.light()
                        let query = model.filter.query
                        var filter = NetworkFilter()
                        filter.query = query
                        model.filter = filter
                    }
                    .disabled(isPristine)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .donkTheme()
        .modifier(SheetDetents())
    }

    private var isPristine: Bool {
        var filter = model.filter
        filter.query = ""
        return filter.isEmpty
    }

    // MARK: - Sections

    private var kindSection: some View {
        Section {
            ForEach(NetworkKind.allCases, id: \.self) { kind in
                SelectableRow(
                    icon: EntryStyle.kindIcon(kind),
                    tone: EntryStyle.kindTone(kind),
                    title: EntryStyle.kindTitle(kind),
                    subtitle: nil,
                    count: model.counts.count(for: kind),
                    isSelected: model.filter.kinds.contains(kind)
                ) {
                    toggle(&model.filter.kinds, kind)
                }
            }
        } header: {
            DonkSectionHeader("Type")
        } footer: {
            Text("Nothing selected shows every type.")
        }
    }

    private var statusSection: some View {
        Section {
            ForEach(StatusCategory.allCases, id: \.self) { category in
                SelectableRow(
                    icon: EntryStyle.categoryIcon(category),
                    tone: EntryStyle.tone(for: category),
                    title: EntryStyle.categoryTitle(category),
                    subtitle: EntryStyle.categoryHint(category),
                    count: model.counts.categories[category] ?? 0,
                    isSelected: model.filter.statusCategories.contains(category)
                ) {
                    toggle(&model.filter.statusCategories, category)
                }
            }
        } header: {
            DonkSectionHeader("Status")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $model.filter.onlyModified) {
                DonkLabelRow(icon: "wand.and.stars", tone: .accent, title: "Only modified", subtitle: "Mocked, rewritten or edited at a breakpoint")
            }
            Toggle(isOn: $model.filter.onlyPinned) {
                DonkLabelRow(icon: "pin.fill", tone: .warning, title: "Only pinned", subtitle: "Pinned requests survive Clear and the buffer limit")
            }
        } header: {
            DonkSectionHeader("Options")
        }
    }

    private var hostsSection: some View {
        Section {
            if model.hosts.count > 8 {
                DonkSearchField(text: $hostQuery, prompt: "Find host")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if visibleHosts.isEmpty {
                Text(model.hosts.isEmpty ? "No hosts captured yet" : "No hosts match")
                    .font(.footnote)
                    .foregroundColor(DonkColor.textTertiary)
            }
            ForEach(visibleHosts) { item in
                hostRow(item)
            }
        } header: {
            DonkSectionHeader("Hosts", count: model.hosts.count) {
                if !model.filter.hosts.isEmpty {
                    Button("Clear") {
                        DonkHaptics.selection()
                        model.filter.hosts = []
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(DonkColor.accent)
                }
            }
        } footer: {
            Text("Select one or more hosts to show only their traffic.")
        }
    }

    private var visibleHosts: [HostCount] {
        let query = hostQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.hosts }
        return model.hosts.filter { $0.host.contains(query) }
    }

    private func hostRow(_ item: HostCount) -> some View {
        let isHidden = HostPattern.matchesAny(item.host, patterns: model.hiddenHosts)
        let isSelected = model.filter.hosts.contains(item.host)
        return Button {
            DonkHaptics.selection()
            toggle(&model.filter.hosts, item.host)
        } label: {
            HStack(spacing: DonkSpacing.m) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundColor(isSelected ? DonkColor.accent : DonkColor.textTertiary)
                Text(DonkTextBreaking.breakable(item.host))
                    .font(DonkFont.code)
                    .foregroundColor(isHidden ? DonkColor.textTertiary : DonkColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption)
                        .foregroundColor(DonkColor.textTertiary)
                        .accessibilityLabel("Hidden")
                }
                Spacer(minLength: DonkSpacing.s)
                CountBadge(item.count, tone: .neutral, filled: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                DonkPasteboard.copy(item.host, label: "Host")
            } label: {
                Label("Copy Host", systemImage: "doc.on.doc")
            }
            if isHidden {
                Button {
                    EntryActions.unhideHost(item.host)
                } label: {
                    Label("Show Host", systemImage: "eye")
                }
            } else {
                Button {
                    EntryActions.hideHost(item.host)
                } label: {
                    Label("Hide Host", systemImage: "eye.slash")
                }
            }
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

// MARK: - Selectable row

struct SelectableRow: View {
    let icon: String
    let tone: DonkTone
    let title: String
    let subtitle: String?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            DonkHaptics.selection()
            action()
        } label: {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge(icon, tone: tone, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DonkColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(DonkColor.textSecondary)
                    }
                }
                Spacer(minLength: DonkSpacing.s)
                Text(DonkFormat.compact(count))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(DonkColor.textSecondary)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(DonkColor.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Detents

struct SheetDetents: ViewModifier {
    var large = false

    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            if large {
                content.presentationDetents([.large])
            } else {
                content.presentationDetents([.medium, .large])
            }
        } else {
            content
        }
    }
}
