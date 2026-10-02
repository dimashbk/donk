import DonkCore
import DonkUI
import SwiftUI

struct HostListEditor: View {
    let kind: HostListKind
    @ObservedObject var model: SettingsModel

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    private var items: [String] {
        model.items(kind)
    }

    private var suggestions: [String] {
        model.suggestions(kind)
    }

    private var normalizedDraft: String? {
        kind.normalize(draft)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: DonkSpacing.s) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(normalizedDraft == nil ? DonkColor.textTertiary : DonkColor.accent)
                    TextField(kind.placeholder, text: $draft)
                        .font(DonkFont.code)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(kind.keyboardType)
                        .submitLabel(.done)
                        .focused($isFieldFocused)
                        .onSubmit(add)
                    if !draft.isEmpty {
                        Button("Add", action: add)
                            .font(DonkFont.label)
                            .disabled(normalizedDraft == nil)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                DonkSectionHeader(kind.addHeader)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.explanation)
                    Text(kind.hint)
                }
            }

            Section {
                if items.isEmpty {
                    HStack(spacing: DonkSpacing.m) {
                        DonkIconBadge(kind.icon, tone: kind.tone, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.emptyTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(DonkColor.textPrimary)
                            Text(kind.emptyMessage)
                                .font(.caption)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(items, id: \.self) { item in
                        Text(DonkTextBreaking.breakableKey(item))
                            .font(DonkFont.code)
                            .foregroundColor(DonkColor.textPrimary)
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button {
                                    DonkPasteboard.copy(item, label: kind.itemLabel)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    model.removeItem(item, from: kind)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { model.removeItems(at: $0, from: kind) }
                    .onMove { model.moveItems(from: $0, to: $1, in: kind) }
                }
            } header: {
                DonkSectionHeader(kind.listHeader, count: items.count)
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { item in
                        Button {
                            model.addItem(item, to: kind)
                        } label: {
                            HStack {
                                Text(DonkTextBreaking.breakableKey(item))
                                    .font(DonkFont.code)
                                    .foregroundColor(DonkColor.textPrimary)
                                Spacer(minLength: DonkSpacing.s)
                                Image(systemName: "plus.circle")
                                    .foregroundColor(DonkColor.accent)
                            }
                        }
                        .accessibilityLabel("Add \(item)")
                    }
                } header: {
                    DonkSectionHeader(kind.suggestionsHeader, icon: kind.suggestionsIcon)
                }
            }
        }
        .donkListStyle()
        .donkNavigationTitle(kind.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !items.isEmpty {
                    EditButton()
                }
            }
        }
        .onAppear {
            if kind.isHostList {
                model.loadCapturedHosts()
            }
        }
    }

    private func add() {
        guard normalizedDraft != nil else {
            if !draft.isEmpty {
                DonkHaptics.warning()
                DonkToast.show(kind.invalidMessage, tone: .warning, duration: 1.8)
            }
            return
        }
        if model.addItem(draft, to: kind) {
            draft = ""
        }
    }
}
