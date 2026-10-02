import DonkUI
import SwiftUI

struct CrashDetailView: View {
    let report: CrashReport
    var onDelete: (() -> Void)?

    @Environment(\.presentationMode) private var presentationMode
    @State private var showsSignalFrames = false
    @State private var showsRegisters = false
    @State private var showsImages = false
    @State private var showsSystemFrames = true
    @State private var showsEnvironment = false

    var body: some View {
        DonkScrollContainer {
            headerCard
            summaryCard
            messageCard
            exceptionInfoCard
            detailsCard
            if !report.frames.isEmpty {
                framesCard
            }
            if !report.signalFrames.isEmpty {
                signalFramesCard
            }
            symbolicateCard
            if !report.registers.isEmpty {
                registersCard
            }
            if !report.binaryImages.isEmpty {
                imagesCard
            }
            if !report.environmentNotes.isEmpty {
                environmentCard
            }
        }
        .donkNavigationTitle(report.kind.label)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    CrashReportMenuItems(report: report, onDelete: onDelete.map { delete in
                        {
                            delete()
                            presentationMode.wrappedValue.dismiss()
                        }
                    })
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel("Share")
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        DonkCard {
            HStack(alignment: .top, spacing: DonkSpacing.m) {
                DonkIconBadge(report.icon, tone: report.kind.tone, size: 44, filled: true)
                VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                    Text(DonkTextBreaking.breakable(report.title))
                        .font(DonkFont.title3)
                        .foregroundColor(DonkColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = report.subtitle {
                        Text(subtitle)
                            .font(DonkFont.callout)
                            .foregroundColor(DonkColor.textSecondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: DonkSpacing.xs) {
                        TonePill(report.kind.label, tone: report.kind.tone, icon: report.icon)
                        TonePill(DonkFormat.relative(report.date), tone: .neutral, icon: "clock")
                    }
                    .padding(.top, DonkSpacing.xxs)
                }
            }
        }
    }

    private var summaryCard: some View {
        DonkCard(title: "Summary", icon: "info.circle.fill", tone: .info) {
            VStack(spacing: 0) {
                ForEach(Array(summaryRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    KeyValueRow(key: row.key, value: row.value, monospacedValue: row.monospaced)
                }
            }
        } accessory: {
            CopyButton(label: "Summary") {
                summaryRows.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
        }
    }

    private var summaryRows: [(key: String, value: String, monospaced: Bool)] {
        var rows: [(String, String, Bool)] = [
            ("Kind", report.kind.label, false),
            ("Date", DonkFormat.dateTime(report.date), false),
            ("App", "\(report.appName) \(report.versionLabel)", false),
        ]
        if !report.bundleID.isEmpty {
            rows.append(("Bundle ID", report.bundleID, true))
        }
        rows.append(("Device", report.deviceModel, false))
        rows.append(("OS", report.osVersion.lowercased().contains("os") ? report.osVersion : "iOS \(report.osVersion)", false))
        if let thread = report.threadLabel {
            rows.append(("Thread", thread, false))
        }
        if let signal = report.signal {
            rows.append(("Exception", signal.machException, true))
            rows.append(("Signal", "\(signal.name) (\(signal.number))", true))
            if let codeName = signal.codeName {
                rows.append(("Code", "\(codeName) (\(signal.code))", true))
            } else if signal.code != 0 {
                rows.append(("Code", String(signal.code), true))
            }
            if let address = signal.faultAddress {
                rows.append(("Fault address", CrashHex.padded(address), true))
            }
        }
        if let pid = report.processID {
            rows.append(("Process ID", String(pid), true))
        }
        if let launch = report.launchDate {
            rows.append(("Launched", DonkFormat.dateTime(launch), false))
        }
        return rows.map { (key: $0.0, value: $0.1, monospaced: $0.2) }
    }

    // MARK: - Message

    @ViewBuilder
    private var messageCard: some View {
        if let reason = report.exception?.reason, !reason.isEmpty {
            DonkCard(title: "Reason", icon: "text.quote", tone: report.kind.tone) {
                messageText(reason)
                if let message = report.messageText, message != reason {
                    Divider()
                    crashInfoList
                }
            } accessory: {
                CopyButton(text: reason, label: "Reason")
            }
        } else if report.messageText != nil {
            DonkCard(title: "Message", icon: "text.quote", tone: report.kind.tone) {
                crashInfoList
            } accessory: {
                CopyButton(text: report.messageText ?? "", label: "Message")
            }
        }
    }

    private var crashInfoList: some View {
        crashInfoList(report.messageEntries)
    }

    private func crashInfoList(_ entries: [CrashInfoMessage]) -> some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    if let image = entry.imageName {
                        Text(image)
                            .font(DonkFont.caption2)
                            .foregroundColor(DonkColor.textTertiary)
                    }
                    messageText(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func messageText(_ text: String) -> some View {
        Text(DonkTextBreaking.breakable(text))
            .font(DonkFont.code)
            .foregroundColor(DonkColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var exceptionInfoCard: some View {
        if let exception = report.exception, !exception.userInfo.isEmpty {
            HeaderListView(exception.userInfo.map { DonkKeyValue($0.key, $0.value) }, title: "User Info")
        }
    }

    @ViewBuilder
    private var detailsCard: some View {
        let details = report.details.filter { $0.key != "Queue" }
        if !details.isEmpty {
            DonkCard(title: report.kind == .metricKit ? "Diagnostic" : "Details", icon: "list.bullet.rectangle", tone: report.kind.tone) {
                VStack(spacing: 0) {
                    ForEach(Array(details.enumerated()), id: \.offset) { index, detail in
                        if index > 0 {
                            Divider()
                        }
                        KeyValueRow(key: detail.key, value: detail.value, layout: detail.value.count > 60 ? .vertical : .horizontal)
                    }
                }
            }
        }
    }

    // MARK: - Frames

    private var visibleFrames: [CrashFrame] {
        showsSystemFrames ? report.frames : report.frames.filter { $0.isAppFrame || $0.index == 0 }
    }

    private var framesCard: some View {
        DonkCard(title: report.crashedThreadTitle, icon: "list.number", tone: report.kind.tone) {
            if let thread = report.threadLabel, report.kind != .exception {
                Text(thread)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
            }
            if report.frames.contains(where: { !$0.isAppFrame }) && report.frames.contains(where: \.isAppFrame) {
                Toggle(isOn: $showsSystemFrames.animation(.easeInOut(duration: 0.2))) {
                    Text("Show system frames")
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                }
                .toggleStyle(.switch)
            }
            CrashFrameList(frames: visibleFrames, report: report)
        } accessory: {
            CopyButton(label: "Backtrace") {
                report.frames.map(CrashTextFormatter.frameLine).joined(separator: "\n")
            }
        }
    }

    private var signalFramesCard: some View {
        CollapsibleCard(
            title: "Signal Thread" + (report.signal.map { " (\($0.name))" } ?? ""),
            icon: "bolt.fill",
            tone: .error,
            summary: "\(report.signalFrames.count) frames recorded by the signal handler",
            isExpanded: $showsSignalFrames
        ) {
            CrashFrameList(frames: report.signalFrames, report: report)
        }
    }

    // MARK: - Symbolicate

    @ViewBuilder
    private var symbolicateCard: some View {
        if let command = CrashTextFormatter.atosCommand(for: report) {
            DonkCard(title: "Symbolicate", icon: "terminal.fill", tone: .accent) {
                Text("Resolve the top app frame against the dSYM of this exact build:")
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                CodeView(text: command)
                    .padding(DonkSpacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous)
                            .fill(DonkColor.codeBackground)
                    )
            } accessory: {
                CopyButton(text: command, label: "atos command")
            }
        }
    }

    // MARK: - Registers & images

    private var registersCard: some View {
        CollapsibleCard(
            title: "Registers",
            icon: "cpu",
            tone: .neutral,
            summary: report.registers.prefix(2).map { "\($0.key) \($0.value)" }.joined(separator: "  "),
            isExpanded: $showsRegisters
        ) {
            VStack(spacing: 0) {
                ForEach(Array(report.registers.enumerated()), id: \.offset) { index, register in
                    if index > 0 {
                        Divider()
                    }
                    KeyValueRow(key: register.key, value: register.value, monospacedValue: true, keyWidth: 56)
                }
            }
        }
    }

    private var imagesCard: some View {
        CollapsibleCard(
            title: "Binary Images",
            icon: "shippingbox.fill",
            tone: .neutral,
            summary: imagesSummary,
            isExpanded: $showsImages
        ) {
            VStack(spacing: 0) {
                ForEach(Array(report.binaryImages.enumerated()), id: \.element.id) { index, image in
                    if index > 0 {
                        Divider()
                    }
                    BinaryImageRow(image: image)
                }
            }
        }
    }

    private var environmentCard: some View {
        CollapsibleCard(
            title: "Environment Notes",
            icon: "gearshape.2.fill",
            tone: .neutral,
            summary: "\(report.environmentNotes.count) note\(report.environmentNotes.count == 1 ? "" : "s") from the runtime (simulator, dyld)",
            isExpanded: $showsEnvironment
        ) {
            crashInfoList(report.environmentNotes)
        }
    }

    private var imagesSummary: String {
        let listed = report.binaryImages.count
        if let total = report.loadedImageCount, total > listed {
            return "\(listed) referenced of \(total) loaded"
        }
        return "\(listed) image\(listed == 1 ? "" : "s")"
    }
}

// MARK: - Frame list

struct CrashFrameList: View {
    let frames: [CrashFrame]
    let report: CrashReport

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(frames) { frame in
                CrashFrameRow(frame: frame, report: report)
            }
        }
    }
}

struct CrashFrameRow: View {
    let frame: CrashFrame
    let report: CrashReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
            Text(verbatim: "\(frame.index)")
                .font(DonkFont.codeCaption)
                .foregroundColor(frame.isAppFrame ? DonkColor.accent : DonkColor.textTertiary)
                .frame(minWidth: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                symbolText
                    .font(frame.isAppFrame ? DonkFont.code(.footnote, weight: .semibold) : DonkFont.code)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if frame.isUnsymbolicated {
                    Text("unsymbolicated (use atos)")
                        .font(DonkFont.caption)
                        .foregroundColor(frame.isAppFrame ? DonkColor.warning : DonkColor.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: DonkSpacing.s) {
                    Text(frame.imageName ?? "???")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DonkSpacing.xs)
                    Text(CrashHex.short(frame.address))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(DonkFont.codeCaption2)
                .foregroundColor(frame.isAppFrame ? DonkColor.accent : DonkColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, DonkSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous)
                .fill(frame.isAppFrame ? DonkColor.accent.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            DonkPasteboard.copy(CrashHex.padded(frame.address), label: "Address")
        }
        .contextMenu {
            Button {
                DonkPasteboard.copy(CrashHex.padded(frame.address), label: "Address")
            } label: {
                Label("Copy Address", systemImage: "number")
            }
            if let symbol = frame.symbol {
                Button {
                    DonkPasteboard.copy(symbol, label: "Symbol")
                } label: {
                    Label("Copy Symbol", systemImage: "textformat")
                }
            }
            Button {
                DonkPasteboard.copy(CrashTextFormatter.frameLine(frame), label: "Frame")
            } label: {
                Label("Copy Frame Line", systemImage: "doc.on.doc")
            }
            if let command = CrashTextFormatter.atosCommand(for: report, frame: frame) {
                Button {
                    DonkPasteboard.copy(command, label: "atos command")
                } label: {
                    Label("Copy atos Command", systemImage: "terminal")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to copy the address")
    }

    private var symbolText: Text {
        let color = frame.isAppFrame ? DonkColor.textPrimary : DonkColor.textSecondary
        guard let symbol = frame.symbol else {
            let fallback = frame.imageOffset.map { "\(frame.imageName ?? "???") + \(CrashHex.short($0))" } ?? CrashHex.padded(frame.address)
            return Text(fallback).foregroundColor(color)
        }
        var text = Text(DonkTextBreaking.breakable(CrashSymbolFormatter.short(symbol))).foregroundColor(color)
        if let offset = frame.symbolOffset {
            text = text + Text(verbatim: " + \(offset)").foregroundColor(DonkColor.textTertiary)
        }
        return text
    }
}

struct BinaryImageRow: View {
    let image: CrashBinaryImage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DonkSpacing.xs) {
                Text(image.name)
                    .font(DonkFont.rowTitle)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if image.isApp {
                    TonePill("App", tone: .accent)
                }
                Spacer(minLength: 0)
                Text(image.architecture)
                    .font(DonkFont.codeCaption2)
                    .foregroundColor(DonkColor.textTertiary)
            }
            Text(CrashHex.short(image.loadAddress) + (image.size > 0 ? " – " + CrashHex.short(image.loadAddress &+ image.size &- 1) : ""))
                .font(DonkFont.codeCaption)
                .foregroundColor(DonkColor.textSecondary)
            if let uuid = image.uuid {
                Text(uuid)
                    .font(DonkFont.codeCaption2)
                    .foregroundColor(DonkColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, DonkSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                DonkPasteboard.copy(CrashTextFormatter.imageLine(image), label: "Image")
            } label: {
                Label("Copy Image Line", systemImage: "doc.on.doc")
            }
            if let uuid = image.uuid {
                Button {
                    DonkPasteboard.copy(uuid, label: "UUID")
                } label: {
                    Label("Copy UUID", systemImage: "number")
                }
            }
            if !image.path.isEmpty {
                Button {
                    DonkPasteboard.copy(image.path, label: "Path")
                } label: {
                    Label("Copy Path", systemImage: "folder")
                }
            }
        }
    }
}

// MARK: - Collapsible card

struct CollapsibleCard<Content: View>: View {
    let title: String
    let icon: String
    let tone: DonkTone
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        DonkCard(title: title, icon: icon, tone: tone) {
            if isExpanded {
                content()
            } else {
                Text(summary)
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(2)
            }
        } accessory: {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
                DonkHaptics.light()
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Hide" : "Show")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .accessibilityLabel(isExpanded ? "Hide \(title)" : "Show \(title)")
        }
    }
}
