import DonkCore
import DonkUI
import SwiftUI

struct PushTemplatesView: View {
    @ObservedObject var model: PushTemplatesModel
    let onOpen: (PushTemplate) -> Void
    @State private var renaming: PushTemplate?
    @State private var deleting: PushTemplate?

    var body: some View {
        List {
            Section {
                ForEach(model.builtIn) { item in
                    row(item)
                }
            } header: {
                DonkSectionHeader("Built-in", icon: "square.grid.2x2", count: model.builtIn.count)
            }
            if !model.host.isEmpty {
                Section {
                    ForEach(model.host) { item in
                        row(item)
                    }
                } header: {
                    DonkSectionHeader("App", icon: "app", count: model.host.count)
                } footer: {
                    Text("Provided by the host app through PushConfiguration.templates.")
                }
            }
            Section {
                if model.saved.isEmpty {
                    HStack(spacing: DonkSpacing.m) {
                        DonkIconBadge("bookmark", tone: .neutral)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No saved templates")
                                .font(DonkFont.rowTitle)
                            Text("Use Save as Template in the composer's payload menu.")
                                .font(DonkFont.caption)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    .padding(.vertical, DonkSpacing.xs)
                }
                ForEach(model.saved) { item in
                    row(item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.delete(item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renaming = item.template
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(DonkColor.info)
                        }
                }
            } header: {
                DonkSectionHeader("Saved", icon: "bookmark", count: model.saved.isEmpty ? nil : model.saved.count)
            }
        }
        .donkListStyle()
        .sheet(item: $renaming) { template in
            PushNameSheet(title: "Rename Template", initialName: template.name) { name in
                model.rename(template.id, to: name)
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Template", role: .destructive) {
                if let deleting {
                    model.delete(deleting.id)
                }
                deleting = nil
            }
        }
    }

    private func row(_ item: PushTemplateItem) -> some View {
        Button {
            onOpen(item.template)
        } label: {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge(item.icon, tone: item.tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.template.name)
                        .font(DonkFont.rowTitle)
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(1)
                    Text(DonkTextBreaking.breakable(item.summary))
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DonkSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
            .padding(.vertical, DonkSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onOpen(item.template)
            } label: {
                Label("Open in Composer", systemImage: "square.and.pencil")
            }
            Button {
                DonkPasteboard.copy(item.template.payload, label: "Payload")
            } label: {
                Label("Copy Payload", systemImage: "doc.on.doc")
            }
            if item.source == .saved {
                Button {
                    renaming = item.template
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleting = item.template
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
