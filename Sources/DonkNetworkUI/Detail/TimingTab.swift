import DonkCore
import DonkUI
import SwiftUI

// MARK: - Math

enum TimingPhaseKind: String, CaseIterable, Hashable {
    case dns = "DNS"
    case connect = "Connect"
    case tls = "TLS"
    case request = "Request"
    case waiting = "Waiting"
    case download = "Download"

    var tone: DonkTone {
        switch self {
        case .dns: return .web
        case .connect: return .warning
        case .tls: return .grpc
        case .request: return .info
        case .waiting: return .accent
        case .download: return .success
        }
    }

    var detail: String {
        switch self {
        case .dns: return "Domain lookup"
        case .connect: return "TCP connection"
        case .tls: return "TLS handshake"
        case .request: return "Sending request"
        case .waiting: return "Time to first byte"
        case .download: return "Receiving response"
        }
    }
}

struct TimingPhase: Identifiable, Hashable {
    let kind: TimingPhaseKind
    let start: Date
    let end: Date

    var id: TimingPhaseKind { kind }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum TimingMath {
    static func phases(_ metrics: TransactionMetrics) -> [TimingPhase] {
        var result: [TimingPhase] = []
        func add(_ kind: TimingPhaseKind, _ start: Date?, _ end: Date?) {
            guard let start, let end, end >= start else { return }
            result.append(TimingPhase(kind: kind, start: start, end: end))
        }
        add(.dns, metrics.domainLookupStart, metrics.domainLookupEnd)
        add(.connect, metrics.connectStart, metrics.secureConnectionStart ?? metrics.connectEnd)
        add(.tls, metrics.secureConnectionStart, metrics.secureConnectionEnd)
        add(.request, metrics.requestStart, metrics.requestEnd)
        add(.waiting, metrics.requestEnd, metrics.responseStart)
        add(.download, metrics.responseStart, metrics.responseEnd)
        return result
    }

    static func range(for entry: NetworkEntry, now: Date = Date()) -> (start: Date, end: Date) {
        var start = entry.timing.startedAt
        var end = entry.timing.endedAt ?? now
        for transaction in entry.timing.transactions {
            if let fetch = transaction.fetchStart, fetch < start { start = fetch }
            if let last = transaction.responseEnd ?? transaction.responseStart, last > end { end = last }
        }
        if end <= start { end = start.addingTimeInterval(0.001) }
        return (start, end)
    }
}

// MARK: - Tab

struct TimingTab: View {
    let entry: NetworkEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.l) {
            if entry.timing.transactions.isEmpty {
                SimpleTimingCard(entry: entry)
            } else {
                let range = TimingMath.range(for: entry)
                let transactions = entry.timing.transactions
                WaterfallOverviewCard(entry: entry, range: range)
                ForEach(Array(transactions.enumerated()), id: \.offset) { index, transaction in
                    TransactionCard(
                        index: index,
                        count: transactions.count,
                        metrics: transaction,
                        range: range
                    )
                }
            }
        }
        .padding(.horizontal, DonkSpacing.screen)
        .padding(.top, DonkSpacing.s)
    }
}

// MARK: - Overview

private struct WaterfallOverviewCard: View {
    let entry: NetworkEntry
    let range: (start: Date, end: Date)

    var body: some View {
        let total = range.end.timeIntervalSince(range.start)
        let phases = entry.timing.transactions.map(TimingMath.phases)
        DonkCard(title: "Waterfall", icon: "chart.bar.xaxis", tone: .accent) {
            HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.l) {
                metric(title: "Total", value: DonkFormat.duration(entry.duration ?? total), tone: .accent)
                if let waiting = phases.last?.first(where: { $0.kind == .waiting }) {
                    metric(title: "TTFB", value: DonkFormat.duration(waiting.duration), tone: .accent)
                }
                if let download = phases.last?.first(where: { $0.kind == .download }) {
                    metric(title: "Download", value: DonkFormat.duration(download.duration), tone: .success)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, transactionPhases in
                    HStack(spacing: DonkSpacing.s) {
                        Text("#\(index + 1)")
                            .font(DonkFont.codeCaption2)
                            .foregroundColor(DonkColor.textTertiary)
                            .frame(width: 22, alignment: .leading)
                        StackedBar(phases: transactionPhases, range: range, height: 14)
                    }
                }
                HStack {
                    Text("0 ms")
                    Spacer()
                    Text(DonkFormat.duration(total))
                }
                .font(DonkFont.codeCaption2)
                .foregroundColor(DonkColor.textTertiary)
                .padding(.leading, 30)
            }
            TimingLegend()
        }
    }

    private func metric(title: String, value: String, tone: DonkTone) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(DonkColor.textSecondary)
            Text(value)
                .font(DonkFont.metricSmall)
                .foregroundColor(DonkColor.textPrimary)
        }
    }
}

private struct StackedBar: View {
    let phases: [TimingPhase]
    let range: (start: Date, end: Date)
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let total = max(0.000_001, range.end.timeIntervalSince(range.start))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DonkColor.fill)
                ForEach(phases) { phase in
                    let x = CGFloat(phase.start.timeIntervalSince(range.start) / total) * proxy.size.width
                    let width = max(2, CGFloat(phase.duration / total) * proxy.size.width)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(phase.kind.tone.color)
                        .frame(width: min(width, max(2, proxy.size.width - x)), height: height)
                        .offset(x: min(max(0, x), max(0, proxy.size.width - 2)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct TimingLegend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: DonkSpacing.s, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(TimingPhaseKind.allCases, id: \.self) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(kind.tone.color)
                        .frame(width: 10, height: 10)
                    Text(kind.rawValue)
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Transaction

private struct TransactionCard: View {
    let index: Int
    let count: Int
    let metrics: TransactionMetrics
    let range: (start: Date, end: Date)
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 70
    @ScaledMetric(relativeTo: .footnote) private var valueWidth: CGFloat = 62

    var body: some View {
        let phases = TimingMath.phases(metrics)
        DonkCard(title: count > 1 ? "Transaction \(index + 1) of \(count)" : "Transaction", icon: "arrow.left.arrow.right", tone: .info) {
            if phases.isEmpty {
                Text("No phase timings were reported for this transaction.")
                    .font(.footnote)
                    .foregroundColor(DonkColor.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(phases) { phase in
                        phaseRow(phase)
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(details.enumerated()), id: \.offset) { offset, item in
                    Divider()
                    KeyValueRow(key: item.key, value: item.value, monospacedValue: true)
                        .id(offset)
                }
            }
        } accessory: {
            HStack(spacing: 6) {
                if count > 1 && index < count - 1 {
                    TonePill(text: "Redirect", tone: .info, icon: "arrow.uturn.right")
                }
                if let name = EntryStyle.protocolName(metrics.networkProtocol) {
                    TonePill(text: name, tone: .neutral)
                }
            }
        }
    }

    private func phaseRow(_ phase: TimingPhase) -> some View {
        HStack(spacing: DonkSpacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(phase.kind.rawValue)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: labelWidth, alignment: .leading)
            StackedBar(phases: [phase], range: range, height: 10)
            Text(DonkFormat.duration(phase.duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(1)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase.kind.detail), \(DonkFormat.duration(phase.duration))")
    }

    private var details: [DonkKeyValue] {
        var items: [DonkKeyValue] = []
        if let name = EntryStyle.protocolName(metrics.networkProtocol) { items.append(DonkKeyValue("Protocol", name)) }
        if let address = metrics.remoteAddress { items.append(DonkKeyValue("Remote address", address)) }
        if let tls = metrics.tlsProtocol { items.append(DonkKeyValue("TLS", tls)) }
        if let cipher = metrics.tlsCipherSuite { items.append(DonkKeyValue("Cipher suite", cipher)) }
        items.append(DonkKeyValue("Connection", metrics.isReusedConnection ? "Reused" : "New"))
        if metrics.isProxyConnection { items.append(DonkKeyValue("Proxy", "Yes")) }
        let sent = metrics.requestHeaderBytes + metrics.requestBodyBytes
        let received = metrics.responseHeaderBytes + metrics.responseBodyBytes
        if sent > 0 {
            items.append(DonkKeyValue("Sent", "\(DonkFormat.bytes(sent)) (headers \(DonkFormat.bytes(metrics.requestHeaderBytes)))"))
        }
        if received > 0 {
            items.append(DonkKeyValue("Received", "\(DonkFormat.bytes(received)) (headers \(DonkFormat.bytes(metrics.responseHeaderBytes)))"))
        }
        return items
    }
}

// MARK: - Without metrics

private struct SimpleTimingCard: View {
    let entry: NetworkEntry

    var body: some View {
        if entry.state.isInFlight {
            TimelineView(.periodic(from: Date(), by: 0.25)) { context in
                card(now: context.date)
            }
        } else {
            card(now: entry.timing.endedAt ?? Date())
        }
    }

    private func card(now: Date) -> some View {
        let start = entry.timing.startedAt
        let end = entry.timing.endedAt ?? now
        let range = (start: start, end: max(end, start.addingTimeInterval(0.001)))
        let total = range.end.timeIntervalSince(range.start)
        return DonkCard(title: "Timeline", icon: "clock", tone: .accent) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.state.isInFlight ? "ELAPSED" : "TOTAL")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(DonkColor.textSecondary)
                    Text(DonkFormat.duration(total))
                        .font(DonkFont.metric)
                }
                Spacer()
                if entry.state.isInFlight {
                    StatusPill(EntryStyle.stateTitle(entry.state).uppercased(), tone: EntryStyle.stateTone(entry.state), isLive: true)
                }
            }
            ZStack(alignment: .leading) {
                StackedBar(phases: phases(range: range), range: range, height: 16)
                if let grpc = entry.grpc {
                    MessageTicks(messages: grpc.messages, range: range)
                        .frame(height: 16)
                }
            }
            HStack {
                Text("0 ms")
                Spacer()
                Text(DonkFormat.duration(total))
            }
            .font(DonkFont.codeCaption2)
            .foregroundColor(DonkColor.textTertiary)
            HStack(spacing: DonkSpacing.m) {
                legend("Waiting", tone: .accent)
                legend(entry.kind == .grpc ? "Streaming" : "Download", tone: .success)
                if entry.grpc != nil {
                    legend("Sent", tone: .accent, tick: true)
                    legend("Received", tone: .neutral, tick: true)
                }
            }
            VStack(spacing: 0) {
                KeyValueRow(key: "Started", value: DonkFormat.time(start), monospacedValue: true)
                if let responseStart = entry.timing.responseStartedAt {
                    Divider()
                    KeyValueRow(key: "First byte", value: "\(DonkFormat.time(responseStart))  \(EntryFormat.offset(responseStart.timeIntervalSince(start)))", monospacedValue: true)
                }
                if let ended = entry.timing.endedAt {
                    Divider()
                    KeyValueRow(key: "Finished", value: "\(DonkFormat.time(ended))  \(EntryFormat.offset(ended.timeIntervalSince(start)))", monospacedValue: true)
                }
            }
            Text(note)
                .font(.caption)
                .foregroundColor(DonkColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func phases(range: (start: Date, end: Date)) -> [TimingPhase] {
        if let responseStart = entry.timing.responseStartedAt, responseStart >= range.start {
            let split = min(responseStart, range.end)
            return [
                TimingPhase(kind: .waiting, start: range.start, end: split),
                TimingPhase(kind: .download, start: split, end: range.end),
            ]
        }
        return [TimingPhase(kind: .waiting, start: range.start, end: range.end)]
    }

    private var note: String {
        switch entry.kind {
        case .grpc: return "gRPC calls are recorded at the call level, so there are no per-connection phases. Ticks mark individual messages."
        case .webView: return "WebView traffic does not expose connection metrics."
        case .http: return "No URLSession transaction metrics were reported for this request."
        }
    }

    private func legend(_ title: String, tone: DonkTone, tick: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: tick ? 1 : 2, style: .continuous)
                .fill(tone.color)
                .frame(width: tick ? 3 : 10, height: 10)
            Text(title)
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
        }
    }
}

private struct MessageTicks: View {
    let messages: [GRPCMessage]
    let range: (start: Date, end: Date)

    var body: some View {
        Canvas { context, size in
            let total = max(0.000_001, range.end.timeIntervalSince(range.start))
            let visible = messages.suffix(400)
            for message in visible {
                let fraction = message.timestamp.timeIntervalSince(range.start) / total
                let x = min(max(1, CGFloat(fraction) * size.width), size.width - 1)
                let rect = CGRect(x: x - 1, y: message.direction == .sent ? 0 : size.height / 2, width: 2, height: size.height / 2)
                let color = message.direction == .sent ? DonkColor.accent : DonkColor.textPrimary.opacity(0.55)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
