import Combine
import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

@MainActor
final class RulesModel: ObservableObject {
    @Published private(set) var rules: [NetworkRule] = []
    @Published private(set) var isEnabled: Bool
    private var cancellable: AnyCancellable?

    init(store: RuleStore = .shared) {
        isEnabled = store.isEnabled
        rules = store.rules
        cancellable = store.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rules in
                guard let self else { return }
                if self.rules != rules { self.rules = rules }
                let enabled = store.isEnabled
                if self.isEnabled != enabled { self.isEnabled = enabled }
            }
    }

    var activeCount: Int { rules.filter(\.isEnabled).count }

    func setEnabled(_ enabled: Bool) {
        DonkHaptics.light()
        RuleStore.shared.isEnabled = enabled
        isEnabled = enabled
    }

    func setRule(_ rule: NetworkRule, enabled: Bool) {
        var updated = rule
        updated.isEnabled = enabled
        DonkHaptics.light()
        RuleStore.shared.update(updated)
    }

    func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        RuleStore.shared.move(fromOffsets: source, toOffset: destination)
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil }
        for id in ids {
            RuleStore.shared.remove(id)
        }
        DonkHaptics.light()
    }

    func duplicate(_ rule: NetworkRule) {
        let copy = NetworkRule(name: rule.name + " copy", isEnabled: false, match: rule.match, action: rule.action)
        RuleStore.shared.add(copy)
        DonkToast.show("Rule duplicated", tone: .success)
    }
}

// MARK: - Sheet

struct RulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DonkNavigationContainer {
            RulesListView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Done") { dismiss() }
                            .font(.body.weight(.semibold))
                    }
                }
        }
        .donkTheme()
    }
}

// MARK: - List

struct RulesListView: View {
    @StateObject private var model = RulesModel()
    @State private var newDraft: RuleDraft?

    var body: some View {
        List {
            globalSection
            rulesSection
        }
        .donkListStyle()
        .donkNavigationTitle("Rules")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !model.rules.isEmpty {
                    EditButton()
                }
                Button {
                    newDraft = RuleDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New rule")
            }
        }
        .sheet(item: $newDraft) { draft in
            RuleEditorSheet(draft: draft, isNew: true)
        }
    }

    private var globalSection: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                DonkLabelRow(
                    icon: model.isEnabled ? "wand.and.stars" : "wand.and.stars.inverse",
                    tone: model.isEnabled ? .accent : .neutral,
                    title: "Apply rules",
                    subtitle: globalSubtitle
                )
            }
        } footer: {
            Text("When off, every request passes through untouched — Map Local, Rewrite and Breakpoint rules are all skipped. Rules are evaluated top to bottom: the first matching Map Local or Rewrite rule and the first matching Breakpoint rule apply.")
        }
    }

    private var globalSubtitle: String {
        if model.rules.isEmpty { return "No rules yet" }
        if !model.isEnabled { return "Off · \(model.rules.count) rules ignored" }
        return "\(model.activeCount) of \(model.rules.count) rules active"
    }

    private var rulesSection: some View {
        Section {
            if model.rules.isEmpty {
                EmptyStateView(
                    icon: "wand.and.stars",
                    title: "No rules",
                    message: "Mock responses, rewrite traffic or pause requests at a breakpoint. Long-press a request and choose Create Rule to start from real traffic.",
                    actionTitle: "New Rule"
                ) {
                    newDraft = RuleDraft()
                }
                .frame(minHeight: 300)
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.rules) { rule in
                    ZStack {
                        NavigationLink {
                            RuleEditorView(draft: RuleDraft(rule: rule), isNew: false, showsCancel: false)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)
                        RuleRow(
                            rule: rule,
                            isGloballyEnabled: model.isEnabled,
                            isOn: Binding(get: { rule.isEnabled }, set: { model.setRule(rule, enabled: $0) })
                        )
                    }
                    .contextMenu {
                        Button {
                            model.setRule(rule, enabled: !rule.isEnabled)
                        } label: {
                            Label(rule.isEnabled ? "Disable" : "Enable", systemImage: rule.isEnabled ? "pause.circle" : "play.circle")
                        }
                        Button {
                            model.duplicate(rule)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button {
                            DonkPasteboard.copy(rule.match.url.pattern, label: "Pattern")
                        } label: {
                            Label("Copy Pattern", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            RuleStore.shared.remove(rule.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: model.move)
                .onDelete(perform: model.delete)
            }
        } header: {
            if !model.rules.isEmpty {
                DonkSectionHeader("Rules", count: model.rules.count)
            }
        } footer: {
            if model.rules.count > 1 {
                Text("Tap Edit to reorder. Order decides which rule wins when several match.")
            }
        }
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: NetworkRule
    let isGloballyEnabled: Bool
    @Binding var isOn: Bool

    var body: some View {
        let kind = RuleSummary.actionKind(rule)
        let active = rule.isEnabled && isGloballyEnabled
        HStack(alignment: .center, spacing: DonkSpacing.m) {
            DonkIconBadge(kind.icon, tone: active ? kind.tone : .neutral, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(active ? DonkColor.textPrimary : DonkColor.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let method = rule.match.method, !method.isEmpty {
                        MethodBadge(method)
                    }
                    Text(DonkTextBreaking.breakable(rule.match.url.pattern))
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    TonePill(text: kind.rawValue, tone: active ? kind.tone : .neutral)
                    Text(RuleSummary.detail(rule))
                        .font(.caption)
                        .foregroundColor(DonkColor.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    kindGlyphs
                }
            }
            Toggle("Enabled", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.vertical, 4)
        .opacity(isGloballyEnabled ? 1 : 0.65)
    }

    private var kindGlyphs: some View {
        HStack(spacing: 4) {
            if rule.match.kinds.isEmpty || rule.match.kinds.contains(.http) {
                Image(systemName: EntryStyle.kindIcon(.http))
                    .foregroundColor(DonkColor.info)
            }
            if rule.match.kinds.isEmpty || rule.match.kinds.contains(.grpc) {
                Image(systemName: EntryStyle.kindIcon(.grpc))
                    .foregroundColor(DonkColor.grpc)
            }
        }
        .font(.caption2.weight(.semibold))
        .accessibilityHidden(true)
    }
}
