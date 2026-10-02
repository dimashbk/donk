import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

enum MessageFilter: String, CaseIterable, Hashable {
    case all = "All"
    case sent = "Sent"
    case received = "Received"
}

struct StreamMessage: Identifiable, Equatable {
    let id: String
    let index: Int
    let direction: GRPCMessage.Direction
    let timestamp: Date?
    let offset: TimeInterval?
    let typeName: String
    let size: Int
    let json: String?
    let textFormat: String?
    let raw: Data?
    let eventID: String?

    var shortTypeName: String {
        typeName.split(separator: ".").last.map(String.init) ?? typeName
    }

    var preview: String {
        let source = json ?? textFormat ?? raw.map { EntryFormat.hexDump($0, limit: 24).components(separatedBy: "\n").first ?? "" } ?? ""
        let head = source.prefix(240)
        return head.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }
}

enum StreamMessages {
    static func messages(for entry: NetworkEntry) -> [StreamMessage] {
        if let grpc = entry.grpc {
            let start = entry.timing.startedAt
            let firstIndex = grpc.droppedMessageCount
            return grpc.messages.enumerated().map { offset, message in
                StreamMessage(
                    id: message.id.uuidString,
                    index: firstIndex + offset + 1,
                    direction: message.direction,
                    timestamp: message.timestamp,
                    offset: message.timestamp.timeIntervalSince(start),
                    typeName: message.typeName,
                    size: message.size,
                    json: message.json,
                    textFormat: message.textFormat,
                    raw: message.raw,
                    eventID: nil
                )
            }
        }
        guard EntryStyle.isStreamedHTTP(entry), let text = entry.response?.body?.text else { return [] }
        return parseEventStream(text).enumerated().map { offset, event in
            StreamMessage(
                id: "sse-\(offset)",
                index: offset + 1,
                direction: .received,
                timestamp: nil,
                offset: nil,
                typeName: event.name,
                size: event.data.utf8.count,
                json: JSONFormatting.isValid(event.data) ? event.data : nil,
                textFormat: JSONFormatting.isValid(event.data) ? nil : event.data,
                raw: nil,
                eventID: event.id
            )
        }
    }

    static func count(for entry: NetworkEntry) -> Int? {
        if let grpc = entry.grpc {
            return grpc.sentMessageCount + grpc.receivedMessageCount
        }
        guard EntryStyle.isStreamedHTTP(entry), let text = entry.response?.body?.text else { return nil }
        return parseEventStream(text).count
    }

    static func progressKey(for entry: NetworkEntry) -> Int {
        if let grpc = entry.grpc {
            return grpc.sentMessageCount + grpc.receivedMessageCount
        }
        return entry.response?.body?.data.count ?? 0
    }

    struct Event {
        var name: String
        var data: String
        var id: String?
    }

    static func parseEventStream(_ text: String) -> [Event] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var events: [Event] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var name = "message"
            var dataLines: [String] = []
            var id: String?
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(":") { continue }
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let field = String(parts[0])
                var value = parts.count > 1 ? String(parts[1]) : ""
                if value.hasPrefix(" ") { value.removeFirst() }
                switch field {
                case "event": name = value
                case "data": dataLines.append(value)
                case "id": id = value
                default: break
                }
            }
            guard !dataLines.isEmpty else { continue }
            events.append(Event(name: name, data: dataLines.joined(separator: "\n"), id: id))
        }
        return events
    }
}

// MARK: - Tab

struct MessagesTab: View {
    let entry: NetworkEntry
    @Binding var filter: MessageFilter
    @Binding var follows: Bool

    var body: some View {
        let all = StreamMessages.messages(for: entry)
        let visible = visibleMessages(all)
        controls(all)
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.top, DonkSpacing.s)
            .padding(.bottom, DonkSpacing.s)
        if let grpc = entry.grpc, grpc.droppedMessageCount > 0 {
            NoticeBanner(
                icon: "tray.full",
                text: "Showing the latest \(grpc.messages.count) of \(grpc.sentMessageCount + grpc.receivedMessageCount) messages.",
                tone: .warning
            )
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.bottom, DonkSpacing.s)
        }
        if visible.isEmpty {
            emptyView(isFiltered: !all.isEmpty)
                .padding(.horizontal, DonkSpacing.screen)
        }
        ForEach(visible) { message in
            NavigationLink {
                MessageDetailView(message: message, isStreamEvent: entry.grpc == nil)
            } label: {
                MessageRow(message: message, isStreamEvent: entry.grpc == nil)
            }
            .buttonStyle(.donkPressable)
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.vertical, 3)
        }
        footer
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.top, DonkSpacing.s)
    }

    private func visibleMessages(_ all: [StreamMessage]) -> [StreamMessage] {
        switch filter {
        case .all: return all
        case .sent: return all.filter { $0.direction == .sent }
        case .received: return all.filter { $0.direction == .received }
        }
    }

    private func controls(_ all: [StreamMessage]) -> some View {
        let sent = all.reduce(0) { $1.direction == .sent ? $0 + 1 : $0 }
        let received = all.count - sent
        return HStack(spacing: DonkSpacing.s) {
            if entry.grpc != nil {
                SegmentedTabs(
                    selection: $filter,
                    tabs: MessageFilter.allCases,
                    title: \.rawValue,
                    icon: { filter in
                        switch filter {
                        case .all: return nil
                        case .sent: return "arrow.up"
                        case .received: return "arrow.down"
                        }
                    },
                    badge: { filter in
                        switch filter {
                        case .all: return all.count
                        case .sent: return sent
                        case .received: return received
                        }
                    }
                )
            } else {
                TonePill(text: "\(all.count) events", tone: .info, icon: "dot.radiowaves.left.and.right")
                Spacer(minLength: 0)
            }
            if entry.state.isInFlight {
                Button {
                    DonkHaptics.selection()
                    follows.toggle()
                } label: {
                    Image(systemName: follows ? "arrow.down.to.line" : "pause.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundColor(follows ? .white : DonkColor.accent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(follows ? DonkColor.accent : DonkTone.accent.softBackground))
                }
                .buttonStyle(.donkPressable)
                .accessibilityLabel(follows ? "Auto-scroll on" : "Auto-scroll paused")
            }
        }
    }

    private func emptyView(isFiltered: Bool) -> some View {
        HStack(spacing: DonkSpacing.m) {
            if entry.state.isInFlight && !isFiltered {
                LiveDot(tone: .grpc)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundColor(DonkColor.textTertiary)
            }
            Text(isFiltered ? "No \(filter.rawValue.lowercased()) messages" : (entry.state.isInFlight ? "Waiting for the first message…" : "No messages were exchanged"))
                .font(.subheadline)
                .foregroundColor(DonkColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(DonkSpacing.l)
        .donkCardBackground()
    }

    @ViewBuilder
    private var footer: some View {
        if entry.state.isInFlight {
            HStack(spacing: DonkSpacing.s) {
                LiveDot(tone: entry.kind == .grpc ? .grpc : .info, size: 7)
                Text(entry.state == .streaming ? "Stream open · new messages appear live" : "Call in flight")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                Spacer(minLength: 0)
            }
        } else if let grpc = entry.grpc, let code = grpc.statusCode {
            HStack(spacing: DonkSpacing.s) {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundColor(DonkTone.grpcStatus(code).color)
                Text("Closed with \(GRPCDetails.statusName(for: code))" + (grpc.statusMessage.map { " · \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let duration = entry.duration {
                    Text(DonkFormat.duration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(DonkColor.textTertiary)
                }
            }
        } else if entry.state == .cancelled || entry.state == .failed {
            HStack(spacing: DonkSpacing.s) {
                Image(systemName: "slash.circle")
                    .foregroundColor(DonkColor.textTertiary)
                Text(entry.state == .cancelled ? "Cancelled" : "Failed: \(entry.error?.message ?? "unknown error")")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Row

private struct MessageRow: View {
    let message: StreamMessage
    let isStreamEvent: Bool

    private var tone: DonkTone { message.direction == .sent ? .accent : .success }

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge(message.direction == .sent ? "arrow.up" : "arrow.down", tone: tone, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.shortTypeName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(DonkFormat.bytes(message.size))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(DonkColor.textTertiary)
                }
                HStack(spacing: 6) {
                    Text(message.offset.map(EntryFormat.offset) ?? "#\(message.index)")
                        .font(DonkFont.codeCaption)
                        .foregroundColor(tone.color)
                    Text(isStreamEvent ? (message.eventID.map { "id \($0)" } ?? "event") : "#\(message.index) · \(message.direction == .sent ? "sent" : "received")")
                        .font(.caption)
                        .foregroundColor(DonkColor.textTertiary)
                        .lineLimit(1)
                }
                let preview = message.preview
                if !preview.isEmpty {
                    Text(preview)
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(DonkSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                .fill(DonkColor.card)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

struct MessageDetailView: View {
    enum Format: String, CaseIterable, Hashable {
        case json = "JSON"
        case text = "Text Format"
        case raw = "Raw"
    }

    let message: StreamMessage
    let isStreamEvent: Bool
    @State private var format: Format?

    private var formats: [Format] {
        var result: [Format] = []
        if message.json != nil { result.append(.json) }
        if message.textFormat != nil { result.append(.text) }
        if let raw = message.raw, !raw.isEmpty { result.append(.raw) }
        return result
    }

    var body: some View {
        let available = formats
        let current = format.flatMap { available.contains($0) ? $0 : nil } ?? available.first
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DonkSpacing.screen)
                .padding(.top, DonkSpacing.m)
            if available.count > 1 {
                SegmentedTabs(
                    selection: Binding(get: { current ?? .json }, set: { format = $0 }),
                    tabs: available,
                    title: { $0 == .text && isStreamEvent ? "Text" : $0.rawValue }
                )
                .padding(.horizontal, DonkSpacing.screen)
                .padding(.top, DonkSpacing.m)
            }
            Group {
                switch current {
                case .json:
                    JSONBodyView(text: message.json ?? "", layout: .scrolling, fileName: "\(message.shortTypeName)-\(message.index).json")
                case .text:
                    CodeView(text: message.textFormat ?? "", language: .plain, layout: .scrolling)
                case .raw:
                    CodeView(text: EntryFormat.hexDump(message.raw ?? Data()), language: .plain, layout: .scrolling)
                case .none:
                    EmptyStateView(
                        icon: "doc.questionmark",
                        title: "Payload not recorded",
                        message: "Only the type and size of this message were captured.",
                        tone: .neutral
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(DonkColor.background.ignoresSafeArea())
        .donkNavigationTitle(isStreamEvent ? "Event #\(message.index)" : "Message #\(message.index)")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                CopyButton(label: "Message") {
                    message.json.flatMap(JSONFormatting.pretty) ?? message.json ?? message.textFormat ?? message.raw?.base64EncodedString() ?? ""
                }
            }
        }
    }

    private var header: some View {
        let tone: DonkTone = message.direction == .sent ? .accent : .success
        return DonkCard(padding: DonkSpacing.m) {
            HStack(spacing: 6) {
                TonePill(text: message.direction == .sent ? "Sent" : "Received", tone: tone, icon: message.direction == .sent ? "arrow.up" : "arrow.down")
                if let offset = message.offset {
                    TonePill(text: EntryFormat.offset(offset), tone: .neutral, icon: "clock")
                }
                TonePill(text: DonkFormat.bytes(message.size), tone: .neutral)
                Spacer(minLength: 0)
            }
            Text(message.typeName)
                .font(DonkFont.code)
                .foregroundColor(DonkColor.textPrimary)
                .textSelection(.enabled)
            if let timestamp = message.timestamp {
                Text(EntryFormat.timestamp(timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DonkColor.textSecondary)
            }
        }
    }
}
