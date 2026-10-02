import DonkCore
import DonkUI
import SwiftUI

enum DetailTab: String, CaseIterable, Hashable {
    case overview = "Overview"
    case request = "Request"
    case response = "Response"
    case messages = "Messages"
    case timing = "Timing"
}

struct EntryDetailView: View {
    @StateObject private var model: EntryDetailModel
    @State private var tab: DetailTab
    @State private var follows = true
    @State private var messageFilter: MessageFilter = .all
    @State private var sheet: DetailSheet?
    @State private var repeatPrompt: RepeatPrompt?

    private static let bottomID = "donk.detail.bottom"

    init(id: UUID, initialTab: DetailTab = .overview) {
        _model = StateObject(wrappedValue: EntryDetailModel(id: id))
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        Group {
            if let entry = model.entry {
                content(entry)
            } else {
                EmptyStateView(
                    icon: "questionmark.folder",
                    title: "Request not found",
                    message: "It was removed from the buffer or cleared.",
                    tone: .neutral
                )
                .donkScreenBackground()
            }
        }
        .donkNavigationTitle(navigationTitle)
        .toolbar { toolbar }
        .repeatRequestPrompt($repeatPrompt)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .rule(draft, isNew):
                RuleEditorSheet(draft: draft, isNew: isNew)
            case let .breakpoint(exchange):
                DonkNavigationContainer {
                    BreakpointView(exchange: exchange)
                }
                .donkTheme()
            }
        }
    }

    private var navigationTitle: String {
        guard let entry = model.entry else { return "Request" }
        if entry.kind == .grpc, let method = entry.grpc?.method, !method.isEmpty { return method }
        let last = entry.request.path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? (entry.host ?? "Request") : last
    }

    // MARK: - Content

    private func content(_ entry: NetworkEntry) -> some View {
        let tabs = availableTabs(entry)
        let selected = tabs.contains(tab) ? tab : .overview
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(alignment: .leading, spacing: DonkSpacing.m) {
                        if model.isRemoved {
                            NoticeBanner(icon: "trash", text: "Removed from the buffer. Showing the last captured state.", tone: .neutral)
                        }
                        if let exchange = model.pausedExchange {
                            PausedBanner(exchange: exchange) {
                                sheet = .breakpoint(exchange)
                            }
                        }
                        DetailHeaderCard(entry: entry)
                    }
                    .padding(.horizontal, DonkSpacing.screen)
                    .padding(.top, DonkSpacing.m)
                    .padding(.bottom, DonkSpacing.m)
                    Section {
                        tabContent(entry, tab: selected)
                        Color.clear
                            .frame(height: DonkSpacing.xxl)
                            .id(Self.bottomID)
                    } header: {
                        tabsBar(entry, tabs: tabs)
                    }
                }
            }
            .background(DonkColor.background.ignoresSafeArea())
            .onChange(of: StreamMessages.progressKey(for: entry)) { _ in
                guard selected == .messages, follows, entry.state.isInFlight else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onChange(of: follows) { value in
                guard value, selected == .messages else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private func availableTabs(_ entry: NetworkEntry) -> [DetailTab] {
        DetailTab.allCases.filter { $0 != .messages || EntryStyle.showsMessages(entry) }
    }

    private func tabsBar(_ entry: NetworkEntry, tabs: [DetailTab]) -> some View {
        SegmentedTabs(selection: $tab, tabs: tabs, title: \.rawValue)
        .padding(.horizontal, tabs.count > 4 ? DonkSpacing.m : DonkSpacing.screen)
        .padding(.vertical, DonkSpacing.s)
        .frame(maxWidth: .infinity)
        .background(DonkColor.background)
    }

    @ViewBuilder
    private func tabContent(_ entry: NetworkEntry, tab: DetailTab) -> some View {
        switch tab {
        case .overview:
            OverviewTab(entry: entry, headerMask: model.headerMask) { rule in
                sheet = .rule(RuleDraft(rule: rule), isNew: false)
            }
        case .request:
            RequestTab(entry: entry, headerMask: model.headerMask)
        case .response:
            ResponseTab(entry: entry, headerMask: model.headerMask)
        case .messages:
            MessagesTab(entry: entry, filter: $messageFilter, follows: $follows)
        case .timing:
            TimingTab(entry: entry)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if let entry = model.entry {
                Button {
                    model.togglePin()
                } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(entry.isPinned ? "Unpin" : "Pin")
                Menu {
                    shareMenu(entry)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                Menu {
                    moreMenu(entry)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder
    private func shareMenu(_ entry: NetworkEntry) -> some View {
        Section {
            Toggle(isOn: Binding(get: { model.redactsSecrets }, set: { model.setRedactsSecrets($0) })) {
                Label("Redact Secrets", systemImage: model.redactsSecrets ? "lock.fill" : "lock.open")
            }
        }
        Section {
            Button {
                EntryActions.shareCommand(entry)
            } label: {
                shareLabel(EntryActions.commandLabel(entry), icon: "terminal", redacts: model.redactsSecrets)
            }
            Button {
                EntryActions.shareText(entry)
            } label: {
                shareLabel("Full Text", icon: "doc.plaintext", redacts: model.redactsSecrets)
            }
            Button {
                EntryActions.shareHAR(entry)
            } label: {
                shareLabel("HAR", icon: "doc.zipper", redacts: model.redactsSecrets)
            }
        }
        Section {
            Button {
                EntryActions.shareBody(entry, response: false)
            } label: {
                shareLabel("Request Body", icon: "arrow.up.doc", redacts: false)
            }
            .disabled(entry.request.body?.data.isEmpty ?? true)
            Button {
                EntryActions.shareBody(entry, response: true)
            } label: {
                shareLabel("Response Body", icon: "arrow.down.doc", redacts: false)
            }
            .disabled(entry.response?.body?.data.isEmpty ?? true)
        }
    }

    @ViewBuilder
    private func shareLabel(_ title: String, icon: String, redacts: Bool) -> some View {
        if redacts {
            Text(title)
            Text("Secrets redacted")
            Image(systemName: icon)
        } else {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func moreMenu(_ entry: NetworkEntry) -> some View {
        Section {
            Button {
                EntryActions.copyURL(entry)
            } label: {
                Label("Copy URL", systemImage: "link")
            }
            Button {
                EntryActions.copyCommand(entry)
            } label: {
                Label("Copy \(EntryActions.commandLabel(entry))", systemImage: "terminal")
            }
            Button {
                EntryActions.copyText(entry)
            } label: {
                Label("Copy as Text", systemImage: "doc.on.doc")
            }
            Button {
                EntryActions.copyBody(entry.response?.body, label: "Response body")
            } label: {
                Label("Copy Response Body", systemImage: "arrow.down.doc")
            }
            .disabled(entry.response?.body?.data.isEmpty ?? true)
        }
        Section {
            if entry.kind != .webView {
                Button {
                    sheet = .rule(RuleDraft(entry: entry), isNew: true)
                } label: {
                    Label("Create Rule…", systemImage: "wand.and.stars")
                }
            }
            if EntryStyle.canRepeat(entry) {
                Button {
                    repeatPrompt = EntryActions.beginRepeat(entry)
                } label: {
                    Label("Repeat Request", systemImage: "arrow.clockwise")
                }
            }
            Button {
                model.togglePin()
            } label: {
                Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
        }
    }
}

// MARK: - Sheets

enum DetailSheet: Identifiable {
    case rule(RuleDraft, isNew: Bool)
    case breakpoint(PausedExchange)

    var id: String {
        switch self {
        case let .rule(draft, _): return "rule-\(draft.id)"
        case let .breakpoint(exchange): return "bp-\(exchange.id)"
        }
    }
}

// MARK: - Banners

struct NoticeBanner: View {
    let icon: String
    let text: String
    let tone: DonkTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.footnote.weight(.semibold))
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, DonkSpacing.m)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                .fill(tone.softBackground)
        )
    }
}

private struct PausedBanner: View {
    let exchange: PausedExchange
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge("pause.circle.fill", tone: .warning, size: 30, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exchange.phase == .request ? "Request paused" : "Response paused")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(DonkColor.textPrimary)
                    Text("Rule “\(exchange.ruleName)” · tap to edit and continue")
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DonkSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
            .padding(DonkSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .fill(DonkTone.warning.softBackground)
            )
        }
        .buttonStyle(.donkPressable)
    }
}

// MARK: - Header card

struct DetailHeaderCard: View {
    let entry: NetworkEntry

    var body: some View {
        DonkCard(padding: DonkSpacing.m + 2) {
            HStack(spacing: 6) {
                MethodBadge(entry.methodLabel)
                if entry.state != .paused {
                    StatusPill(statusText, tone: EntryStyle.statusTone(entry), isLive: entry.state == .pending || entry.state == .streaming)
                }
                if let origin = EntryStyle.originBadge(entry.origin) {
                    OriginTag(badge: origin)
                }
                Spacer(minLength: DonkSpacing.s)
                StateTag(state: entry.state)
            }
            HStack(alignment: .top, spacing: DonkSpacing.s) {
                CodeView(text: entry.request.url, language: .plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: entry.request.url, label: "URL")
                    .padding(.top, -6)
            }
            HStack(spacing: DonkSpacing.m) {
                HeaderMetric(icon: "clock", text: EntryFormat.clock(entry.timing.startedAt))
                if let duration = entry.duration {
                    HeaderMetric(icon: "timer", text: DonkFormat.duration(duration))
                } else if entry.state.isInFlight {
                    ElapsedMetric(since: entry.timing.startedAt)
                }
                if entry.requestSize > 0 {
                    HeaderMetric(icon: "arrow.up", text: DonkFormat.bytes(entry.requestSize))
                }
                if entry.responseSize > 0 {
                    HeaderMetric(icon: "arrow.down", text: DonkFormat.bytes(entry.responseSize))
                }
                Spacer(minLength: 0)
                if entry.kind != .http {
                    TonePill(text: EntryStyle.kindTitle(entry.kind), tone: EntryStyle.kindTone(entry.kind), icon: EntryStyle.kindIcon(entry.kind))
                }
            }
        }
    }

    private var statusText: String {
        if entry.kind == .grpc { return EntryStyle.statusLabel(entry) }
        if let code = entry.response?.statusCode, code >= 200 {
            let phrase = ResponseSnapshot.reasonPhrase(for: code)
            return phrase.isEmpty ? "\(code)" : "\(code) \(phrase)"
        }
        return entry.statusLabel
    }
}

struct StateTag: View {
    let state: NetworkState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: EntryStyle.stateIcon(state))
                .font(.caption2.weight(.bold))
                .imageScale(.small)
            Text(EntryStyle.stateTitle(state))
                .font(.caption2.weight(.semibold))
        }
        .foregroundColor(EntryStyle.stateTone(state).color)
        .fixedSize()
    }
}

private struct HeaderMetric: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(DonkColor.textSecondary)
        .fixedSize()
    }
}

struct ElapsedMetric: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.1)) { context in
            HeaderMetric(icon: "timer", text: DonkFormat.duration(max(0, context.date.timeIntervalSince(since))))
        }
    }
}
