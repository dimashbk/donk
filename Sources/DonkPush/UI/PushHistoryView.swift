import DonkCore
import DonkUI
import SwiftUI

extension PushRecord.Path {
    var tone: DonkTone {
        switch self {
        case .foreground: return .info
        case .tap: return .success
        case .silent: return .grpc
        }
    }

    var icon: String {
        switch self {
        case .foreground: return "bell.badge.fill"
        case .tap: return "hand.tap.fill"
        case .silent: return "moon.zzz.fill"
        }
    }
}

struct PushHistoryView: View {
    @ObservedObject var model: PushHistoryModel
    let onReplay: (PushRecord) -> Void
    @State private var isConfirmingClear = false

    var body: some View {
        Group {
            if model.items.isEmpty {
                EmptyStateView(
                    icon: "bell.slash",
                    title: "No pushes yet",
                    message: model.isRecording
                        ? "Pushes your app receives in the foreground, taps and silent pushes appear here, real or simulated."
                        : "Recording is off. Enable PushConfiguration.recordsIncomingPushes to capture pushes."
                )
            } else {
                list
            }
        }
        .confirmationDialog("Clear push history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                model.clear()
                DonkHaptics.success()
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ChipRow {
                ForEach(PushHistoryFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isSelected: model.filter == filter,
                        tone: tone(for: filter),
                        count: filter == .all ? nil : model.count(for: filter)
                    ) {
                        model.filter = filter
                    }
                }
            }
            .padding(.vertical, DonkSpacing.s)
            records
        }
    }

    private var records: some View {
        List {
            Section {
                let items = model.filteredItems
                if items.isEmpty {
                    Text("No \(model.filter.rawValue.lowercased()) pushes")
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, DonkSpacing.l)
                }
                ForEach(items) { item in
                    NavigationLink {
                        PushRecordDetailView(initialRecord: item.record, model: model, onReplay: onReplay)
                    } label: {
                        PushHistoryRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.delete([item.id])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            onReplay(item.record)
                        } label: {
                            Label("Replay", systemImage: "arrow.uturn.backward")
                        }
                        .tint(DonkColor.accent)
                    }
                    .contextMenu {
                        Button {
                            onReplay(item.record)
                        } label: {
                            Label("Replay in Composer", systemImage: "arrow.uturn.backward")
                        }
                        Button {
                            DonkPasteboard.copy(item.record.payload, label: "Payload")
                        } label: {
                            Label("Copy Payload", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            model.delete([item.id])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                DonkSectionHeader("Received", icon: "tray.full", count: model.filteredItems.count) {
                    Button("Clear") { isConfirmingClear = true }
                        .font(DonkFont.label)
                }
            }
        }
        .donkListStyle()
    }

    private func tone(for filter: PushHistoryFilter) -> DonkTone {
        switch filter {
        case .all: return .accent
        case .foreground: return PushRecord.Path.foreground.tone
        case .tap: return PushRecord.Path.tap.tone
        case .silent: return PushRecord.Path.silent.tone
        case .simulated: return .accent
        }
    }
}

struct PushHistoryRow: View {
    let item: PushHistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge(item.record.path.icon, tone: item.record.path.tone, size: 34)
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                HStack(spacing: DonkSpacing.xs) {
                    TonePill(text: item.record.path.title, tone: item.record.path.tone)
                    if item.record.isSimulated {
                        TonePill(text: "Simulated", tone: .accent, icon: "wand.and.stars")
                    }
                    Spacer(minLength: DonkSpacing.xs)
                    Text(PushTimeFormat.short(item.record.date))
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textTertiary)
                        .monospacedDigit()
                }
                Text(DonkTextBreaking.breakable(item.title))
                    .font(DonkFont.rowTitle)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(DonkTextBreaking.breakable(item.detail))
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                }
                if let action = item.record.actionIdentifier, item.record.path == .tap {
                    Text(PushTimeFormat.actionLabel(action))
                        .font(DonkFont.codeCaption2)
                        .foregroundColor(DonkColor.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DonkSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

enum PushTimeFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    static func short(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dateFormatter.string(from: date)
    }

    static func actionLabel(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.UNNotificationDefaultActionIdentifier": return "default action"
        case "com.apple.UNNotificationDismissActionIdentifier": return "dismissed"
        default: return identifier
        }
    }
}

// MARK: - Detail

struct PushRecordDetailView: View {
    let initialRecord: PushRecord
    @ObservedObject var model: PushHistoryModel
    let onReplay: (PushRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    private var record: PushRecord {
        model.items.first { $0.id == initialRecord.id }?.record ?? initialRecord
    }

    var body: some View {
        DonkScrollContainer {
            DonkCard(title: record.path.title, icon: record.path.icon, tone: record.path.tone) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        KeyValueRow(key: row.key, value: row.value, monospacedValue: row.monospaced, valueTone: row.tone)
                    }
                }
            } accessory: {
                if record.isSimulated {
                    TonePill(text: "Simulated", tone: .accent, icon: "wand.and.stars")
                }
            }
            DonkCard(title: "Payload", icon: "curlybraces") {
                payloadView
            } accessory: {
                CopyButton(text: record.payload, label: "Payload")
            }
            HStack(spacing: DonkSpacing.s) {
                Button {
                    onReplay(record)
                    dismiss()
                } label: {
                    Label("Replay", systemImage: "arrow.uturn.backward")
                        .font(DonkFont.rounded(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.white)
                        .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkColor.accent))
                }
                .buttonStyle(.donkPressable)
                Button {
                    DonkPasteboard.copy(record.payload, label: "Payload")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(DonkFont.rounded(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(DonkColor.accent)
                        .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkTone.accent.softBackground))
                }
                .buttonStyle(.donkPressable)
            }
        }
        .donkNavigationTitle(PushSummary(payloadText: record.payload).title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    DonkShare.share(fileNamed: "push-\(record.path.rawValue).json", data: Data(record.payload.utf8))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share payload")
            }
        }
    }

    @ViewBuilder
    private var payloadView: some View {
        if let value = try? JSONValue.parse(record.payload) {
            JSONTreeView(value: value, layout: .embedded, showsToolbar: false)
        } else {
            CodeView(text: record.payload)
        }
    }

    private var rows: [(key: String, value: String, monospaced: Bool, tone: DonkTone?)] {
        var result: [(String, String, Bool, DonkTone?)] = [
            ("Received", DonkFormat.dateTime(record.date), false, nil),
            ("Callback", record.path.callbackName, true, nil),
            ("Source", record.isSimulated ? "Simulated by donk" : "System delivery", false, record.isSimulated ? .accent : nil),
        ]
        if let action = record.actionIdentifier {
            result.append(("Action", action, true, nil))
        }
        if let text = record.userText {
            result.append(("Reply text", text, false, nil))
        }
        if let category = record.categoryIdentifier {
            result.append(("Category", category, true, nil))
        }
        if let identifier = record.requestIdentifier {
            result.append(("Request ID", identifier, true, nil))
        }
        if let response = record.appResponse {
            result.append(("App answered", response, true, .success))
        } else {
            result.append(("App answered", "Completion handler not called", false, .warning))
        }
        if let time = record.responseTime {
            result.append(("Answer time", DonkFormat.duration(time), true, nil))
        }
        return result
    }
}
