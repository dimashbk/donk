import DonkUI
import SwiftUI

// MARK: - Threads

struct ThreadsCard: View {
    let threads: [PerformanceThread]
    @State private var showsAll = false

    private let collapsedCount = 8

    var body: some View {
        DonkCard(title: "Threads", icon: "list.bullet.indent", tone: .accent) {
            if threads.isEmpty {
                InlineEmptyState(icon: "list.bullet.indent", title: "No thread samples yet", message: "Threads appear after the first CPU sample.")
            } else {
                let visible = showsAll ? threads : Array(threads.prefix(collapsedCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, thread in
                        ThreadRow(thread: thread)
                        if index < visible.count - 1 {
                            Divider()
                        }
                    }
                }
                if threads.count > collapsedCount {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showsAll.toggle() }
                        DonkHaptics.selection()
                    } label: {
                        Text(showsAll ? "Show top \(collapsedCount)" : "Show all \(threads.count) threads")
                            .font(DonkFont.label)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } accessory: {
            if !threads.isEmpty {
                Text("\(threads.filter { $0.cpu > 0.05 }.count) active")
                    .foregroundColor(DonkColor.textSecondary)
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: PerformanceThread

    private var tone: DonkTone {
        if thread.cpu >= 80 { return .error }
        if thread.cpu >= 40 { return .warning }
        return thread.isMain ? .accent : .success
    }

    var body: some View {
        HStack(spacing: DonkSpacing.m) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(DonkTextBreaking.breakable(thread.displayName))
                        .font(DonkFont.footnote.weight(.medium))
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if thread.isMain {
                        TonePill("main", tone: .accent)
                    }
                }
                UsageBar(fraction: thread.cpu / 100, tone: tone)
            }
            Text(String(format: "%.1f%%", thread.cpu))
                .font(DonkFont.number.weight(.semibold))
                .foregroundColor(thread.cpu > 0.05 ? DonkColor.textPrimary : DonkColor.textTertiary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, DonkSpacing.s)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                DonkPasteboard.copy(thread.displayName, label: "Thread name")
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thread.displayName)
        .accessibilityValue(String(format: "%.1f percent CPU", thread.cpu))
    }
}

// MARK: - Events

struct EventsCard: View {
    let events: [PerformanceEvent]
    @State private var limit = 20

    var body: some View {
        DonkCard(title: "Events", icon: "list.bullet.rectangle.portrait", tone: .warning) {
            if events.isEmpty {
                InlineEmptyState(
                    icon: "checkmark.seal",
                    title: "Nothing unusual yet",
                    message: "Hangs, memory warnings, thermal changes and alerts are listed here."
                )
            } else {
                let visible = Array(events.prefix(limit))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, event in
                        if event.isHang {
                            NavigationLink {
                                PerformanceEventDetailView(event: event)
                            } label: {
                                EventRow(event: event, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            EventRow(event: event, showsChevron: false)
                        }
                        if index < visible.count - 1 {
                            Divider()
                        }
                    }
                }
                if events.count > limit {
                    Button {
                        limit += 20
                    } label: {
                        Text("Show \(min(20, events.count - limit)) more")
                            .font(DonkFont.label)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } accessory: {
            if !events.isEmpty {
                CountBadge(events.count, tone: events.contains { $0.severity == .critical } ? .error : .warning)
            }
        }
    }
}

struct EventRow: View {
    let event: PerformanceEvent
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: DonkSpacing.m) {
            DonkIconBadge(event.icon, tone: event.severity.tone, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(DonkFont.rowTitle)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.subtitle)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DonkSpacing.s)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
        }
        .padding(.vertical, DonkSpacing.s)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                DonkPasteboard.copy(event.copyText, label: "Event")
            } label: {
                Label("Copy Event", systemImage: "doc.on.doc")
            }
            if let backtrace = event.backtrace {
                Button {
                    DonkPasteboard.copy(backtrace.text, label: "Stack")
                } label: {
                    Label("Copy Stack", systemImage: "list.number")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(showsChevron ? "Shows details" : "")
    }
}
