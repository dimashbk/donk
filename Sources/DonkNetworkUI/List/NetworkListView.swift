import DonkCore
import DonkUI
import SwiftUI

struct NetworkListView: View {
    @StateObject private var model = NetworkListModel()
    @State private var sheet: ListSheet?
    @State private var confirmsClear = false
    @State private var repeatPrompt: RepeatPrompt?

    private static let topID = "donk.network.top"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                list(proxy)
            }
        }
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "URL, headers, bodies, status…")
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .donkNavigationTitle("Network")
        .toolbar { toolbar }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog("Clear captured traffic?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.counts.pinned > 0 ? "Pinned requests are kept." : "This removes every captured request.")
        }
        .onAppear { model.syncCaptureState() }
    }

    // MARK: - List

    private func list(_ proxy: ScrollViewProxy) -> some View {
        List {
            Color.clear
                .frame(height: 1)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .id(Self.topID)
                .onAppear { model.setAtTop(true) }
                .onDisappear { model.setAtTop(false) }
            ForEach(model.rows) { item in
                row(item)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .repeatRequestPrompt($repeatPrompt)
        .overlay { emptyState }
        .overlay(alignment: .top) {
            newEntriesPill(proxy)
        }
    }

    // MARK: - Rows

    private func row(_ item: NetworkRowItem) -> some View {
        ZStack {
            NavigationLink {
                EntryDetailView(id: item.id)
            } label: {
                EmptyView()
            }
            .opacity(0)
            NetworkRow(item: item)
                .equatable()
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                EntryActions.togglePin(item.id)
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(DonkColor.warning)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                EntryActions.delete([item.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if item.host != nil {
                Button {
                    EntryActions.hideHost(item.host)
                } label: {
                    Label("Hide Host", systemImage: "eye.slash")
                }
                .tint(DonkColor.neutral)
            }
        }
        .contextMenu {
            rowMenu(item)
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: NetworkRowItem) -> some View {
        let label = item.kind == .grpc ? "grpcurl" : "cURL"
        Section {
            Button {
                withEntry(item.id, EntryActions.copyURL)
            } label: {
                Label("Copy URL", systemImage: "link")
            }
            Button {
                withEntry(item.id, EntryActions.copyCommand)
            } label: {
                Label("Copy \(label)", systemImage: "terminal")
            }
            Menu {
                Button {
                    withEntry(item.id, EntryActions.shareCommand)
                } label: {
                    Label(label, systemImage: "terminal")
                }
                Button {
                    withEntry(item.id, EntryActions.shareText)
                } label: {
                    Label("Text", systemImage: "doc.plaintext")
                }
                Button {
                    withEntry(item.id, EntryActions.shareHAR)
                } label: {
                    Label("HAR", systemImage: "doc.zipper")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Section {
            if item.kind != .webView {
                Button {
                    withEntry(item.id) { sheet = .newRule(RuleDraft(entry: $0)) }
                } label: {
                    Label("Create Rule…", systemImage: "wand.and.stars")
                }
            }
            if item.canRepeat {
                Button {
                    withEntry(item.id) { repeatPrompt = EntryActions.beginRepeat($0) }
                } label: {
                    Label("Repeat Request", systemImage: "arrow.clockwise")
                }
            }
            Button {
                EntryActions.togglePin(item.id)
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
        }
        Section {
            if let host = item.host {
                Button {
                    EntryActions.hideHost(host)
                } label: {
                    Label("Hide \(host)", systemImage: "eye.slash")
                }
            }
            Button(role: .destructive) {
                EntryActions.delete([item.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func withEntry(_ id: UUID, _ action: (NetworkEntry) -> Void) {
        guard let entry = model.store.entry(id) else {
            DonkToast.show("Request no longer exists", tone: .neutral)
            return
        }
        action(entry)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ChipRow {
                FilterChip(
                    title: "Filters",
                    icon: "line.3.horizontal.decrease",
                    isSelected: model.sheetFilterCount > 0,
                    count: model.sheetFilterCount > 0 ? model.sheetFilterCount : nil
                ) {
                    sheet = .filters
                }
                FilterChip(title: "All", isSelected: model.filter.kinds.isEmpty, count: model.counts.total) {
                    model.filter.kinds = []
                }
                ForEach(NetworkKind.allCases, id: \.self) { kind in
                    FilterChip(
                        title: EntryStyle.kindTitle(kind),
                        icon: EntryStyle.kindIcon(kind),
                        isSelected: model.filter.kinds.contains(kind),
                        tone: EntryStyle.kindTone(kind),
                        count: model.counts.count(for: kind)
                    ) {
                        model.toggleKind(kind)
                    }
                }
                FilterChip(
                    title: "Errors",
                    icon: "exclamationmark.triangle",
                    isSelected: model.showsErrorsOnly,
                    tone: .error,
                    count: model.counts.errors
                ) {
                    model.toggleErrors()
                }
                FilterChip(
                    title: "Modified",
                    icon: "wand.and.stars",
                    isSelected: model.filter.onlyModified,
                    tone: .accent,
                    count: model.counts.modified
                ) {
                    model.filter.onlyModified.toggle()
                }
                FilterChip(
                    title: "Pinned",
                    icon: "pin",
                    isSelected: model.filter.onlyPinned,
                    tone: .warning,
                    count: model.counts.pinned
                ) {
                    model.filter.onlyPinned.toggle()
                }
            }
            .padding(.vertical, DonkSpacing.s)
            if showsStatusStrip {
                statusStrip
                    .padding(.bottom, DonkSpacing.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
        }
        .background(.bar)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showsStatusStrip)
    }

    private var showsStatusStrip: Bool {
        !model.isCaptureEnabled || (model.rulesEnabled && model.activeRuleCount > 0) || model.counts.hidden > 0
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DonkSpacing.s) {
                if !model.isCaptureEnabled {
                    StripButton(icon: "pause.circle.fill", title: "Capture paused", action: "Resume", tone: .warning) {
                        model.setCaptureEnabled(true)
                    }
                }
                if model.rulesEnabled && model.activeRuleCount > 0 {
                    StripButton(
                        icon: "wand.and.stars",
                        title: model.activeRuleCount == 1 ? "1 rule active" : "\(model.activeRuleCount) rules active",
                        action: "Manage",
                        tone: .accent
                    ) {
                        sheet = .rules
                    }
                }
                if model.counts.hidden > 0 {
                    StripButton(
                        icon: "eye.slash",
                        title: "\(DonkFormat.compact(model.counts.hidden)) hidden",
                        action: "Hosts",
                        tone: .neutral
                    ) {
                        sheet = .hiddenHosts
                    }
                }
            }
            .padding(.horizontal, DonkSpacing.l)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded && model.rows.isEmpty && model.newCount == 0 {
            if model.counts.total == 0 && model.counts.hidden == 0 && !model.isFiltering {
                if model.isCaptureEnabled {
                    EmptyStateView(
                        icon: "network",
                        title: "No requests yet",
                        message: "HTTP, gRPC and WebView traffic appears here as your app talks to the network."
                    )
                } else {
                    EmptyStateView(
                        icon: "pause.circle",
                        title: "Capture is paused",
                        message: "New requests are not recorded until you resume.",
                        tone: .warning,
                        actionTitle: "Resume Capture"
                    ) {
                        model.setCaptureEnabled(true)
                    }
                }
            } else if model.counts.total == 0 && !model.isFiltering {
                EmptyStateView(
                    icon: "eye.slash",
                    title: "Everything is hidden",
                    message: "All captured requests belong to hidden hosts.",
                    tone: .neutral,
                    actionTitle: "Manage Hidden Hosts"
                ) {
                    sheet = .hiddenHosts
                }
            } else {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matches",
                    message: "Nothing matches the current search and filters.",
                    tone: .neutral,
                    actionTitle: "Clear Filters"
                ) {
                    model.resetFilters()
                }
            }
        }
    }

    @ViewBuilder
    private func newEntriesPill(_ proxy: ScrollViewProxy) -> some View {
        if model.newCount > 0 {
            Button {
                DonkHaptics.light()
                model.revealNew()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.bold))
                    Text(model.newCount == 1 ? "1 new request" : "\(DonkFormat.compact(model.newCount)) new requests")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(DonkColor.accent))
                .donkFloatingShadow()
            }
            .buttonStyle(.donkPressable)
            .padding(.top, DonkSpacing.s)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.newCount)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                sheet = .rules
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                    if model.rulesEnabled && model.activeRuleCount > 0 {
                        Text("\(model.activeRuleCount)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityLabel("Rules")
            Menu {
                moreMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Section {
            Button {
                model.setCaptureEnabled(!model.isCaptureEnabled)
            } label: {
                Label(model.isCaptureEnabled ? "Pause Capture" : "Resume Capture", systemImage: model.isCaptureEnabled ? "pause.circle" : "play.circle")
            }
            Button {
                sheet = .rules
            } label: {
                Label(model.activeRuleCount > 0 ? "Rules (\(model.activeRuleCount) active)" : "Rules", systemImage: "slider.horizontal.3")
            }
            Button {
                sheet = .hiddenHosts
            } label: {
                Label(model.hiddenHosts.isEmpty ? "Hidden Hosts" : "Hidden Hosts (\(model.hiddenHosts.count))", systemImage: "eye.slash")
            }
        }
        Section {
            Menu {
                Button {
                    EntryActions.shareHAR(model.filteredEntries(), fileName: EntryActions.exportFileName("har"))
                } label: {
                    Label("HAR", systemImage: "doc.zipper")
                }
                Button {
                    EntryActions.shareAllText(model.filteredEntries(), fileName: EntryActions.exportFileName("txt"))
                } label: {
                    Label("Text", systemImage: "doc.plaintext")
                }
            } label: {
                Label(model.isFiltering ? "Share Filtered (\(model.rows.count))" : "Share All (\(model.rows.count))", systemImage: "square.and.arrow.up")
            }
            .disabled(model.rows.isEmpty)
        }
        Section {
            Button(role: .destructive) {
                confirmsClear = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ListSheet) -> some View {
        switch sheet {
        case .filters:
            FilterSheet(model: model)
        case .hiddenHosts:
            HiddenHostsSheet(hosts: model.hosts)
        case .rules:
            RulesSheet()
        case let .newRule(draft):
            RuleEditorSheet(draft: draft, isNew: true)
        }
    }
}

// MARK: - Sheet routing

enum ListSheet: Identifiable {
    case filters
    case hiddenHosts
    case rules
    case newRule(RuleDraft)

    var id: String {
        switch self {
        case .filters: return "filters"
        case .hiddenHosts: return "hidden"
        case .rules: return "rules"
        case let .newRule(draft): return "rule-\(draft.id)"
        }
    }
}

// MARK: - Strip button

private struct StripButton: View {
    let icon: String
    let title: String
    let action: String
    let tone: DonkTone
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(action)
                    .font(.caption.weight(.bold))
                    .opacity(0.75)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .imageScale(.small)
                    .opacity(0.6)
            }
            .foregroundColor(tone.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tone.softBackground))
        }
        .buttonStyle(.donkPressable)
    }
}
