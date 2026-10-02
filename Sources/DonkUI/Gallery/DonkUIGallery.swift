import DonkJSON
import SwiftUI

// MARK: - Gallery root

public struct DonkUIGallery: View {
    private let embedInNavigation: Bool
    @State private var appearance: GalleryAppearance = .system

    public init(embedInNavigation: Bool = true) {
        self.embedInNavigation = embedInNavigation
    }

    public var body: some View {
        Group {
            if embedInNavigation {
                DonkNavigationContainer {
                    root
                }
            } else {
                root
            }
        }
        .donkTheme()
        .preferredColorScheme(appearance.colorScheme)
    }

    private var root: some View {
        List {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(GalleryAppearance.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }
            Section {
                link("Colors & Type", icon: "paintpalette.fill", tone: .accent) { GalleryTokensPage() }
            } header: {
                Text("Foundations")
            }
            Section {
                link("Badges & Pills", icon: "tag.fill", tone: .info) { GalleryBadgesPage() }
                link("Cards & Rows", icon: "rectangle.stack.fill", tone: .grpc) { GalleryRowsPage() }
                link("Controls", icon: "slider.horizontal.3", tone: .web) { GalleryControlsPage() }
                link("Tiles & Charts", icon: "chart.xyaxis.line", tone: .success) { GalleryTilesPage() }
                link("Empty State", icon: "tray", tone: .neutral) { GalleryEmptyPage() }
            } header: {
                Text("Components")
            }
            Section {
                link("Code View", icon: "curlybraces", tone: .accent) { GalleryCodePage() }
                link("Code Editor", icon: "pencil.and.outline", tone: .warning) { GalleryEditorPage() }
                link("JSON Tree", icon: "list.bullet.indent", tone: .grpc) { GalleryTreePage(large: false) }
                link("JSON Tree · 5k nodes", icon: "square.stack.3d.up.fill", tone: .grpc) { GalleryTreePage(large: true) }
                link("Body View", icon: "doc.text.magnifyingglass", tone: .info) { GalleryBodyPage() }
            } header: {
                Text("Content")
            }
            Section {
                link("Toasts, Haptics, Share", icon: "bell.badge.fill", tone: .error) { GalleryFeedbackPage() }
            } header: {
                Text("Feedback")
            }
        }
        .donkListStyle()
        .donkNavigationTitle("DonkUI Gallery")
    }

    private func link<Destination: View>(
        _ title: String,
        icon: String,
        tone: DonkTone,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .donkNavigationTitle(title)
        } label: {
            DonkLabelRow(icon: icon, tone: tone, title: title)
        }
    }
}

enum GalleryAppearance: String, CaseIterable, Hashable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Tokens

struct GalleryTokensPage: View {
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: DonkSpacing.m)]

    private let surfaces: [(String, Color)] = [
        ("background", DonkColor.background),
        ("card", DonkColor.card),
        ("elevated", DonkColor.elevated),
        ("fill", DonkColor.fill),
        ("separator", DonkColor.separator),
        ("textPrimary", DonkColor.textPrimary),
        ("textSecondary", DonkColor.textSecondary),
        ("textTertiary", DonkColor.textTertiary),
    ]

    private let code: [(String, Color)] = [
        ("codeKey", DonkColor.codeKey),
        ("codeString", DonkColor.codeString),
        ("codeNumber", DonkColor.codeNumber),
        ("codeLiteral", DonkColor.codeLiteral),
        ("codePunctuation", DonkColor.codePunctuation),
        ("searchMatch", DonkColor.searchMatch),
        ("searchCurrent", DonkColor.searchCurrentMatch),
        ("patch", DonkColor.patch),
    ]

    var body: some View {
        DonkScrollContainer {
            DonkSectionHeader("Tones", count: DonkTone.allCases.count)
            LazyVGrid(columns: columns, spacing: DonkSpacing.m) {
                ForEach(DonkTone.allCases) { tone in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                            .fill(tone.color)
                            .frame(height: 44)
                        RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                            .fill(tone.softBackground)
                            .frame(height: 22)
                            .overlay(Text("soft").font(.caption2.weight(.semibold)).foregroundColor(tone.color))
                        Text(tone.rawValue)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(10)
                    .donkCardBackground(radius: DonkRadius.medium)
                }
            }
            DonkSectionHeader("Surfaces & text")
            swatches(surfaces)
            DonkSectionHeader("Code")
            swatches(code)
            DonkSectionHeader("Typography")
            DonkCard {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    Text("Large title").font(DonkFont.largeTitle)
                    Text("Title").font(DonkFont.title)
                    Text("Title 3").font(DonkFont.title3)
                    Text("Headline").font(DonkFont.headline)
                    Text("Row title").font(DonkFont.rowTitle)
                    Text("Body text for descriptions").font(DonkFont.body)
                    Text("Footnote secondary").font(DonkFont.footnote).foregroundColor(DonkColor.textSecondary)
                    Text("{\"code\": \"monospaced\"}").font(DonkFont.code)
                    Text("128.4").font(DonkFont.metric)
                }
            }
            DonkSectionHeader("Spacing & radius")
            DonkCard {
                HStack(alignment: .bottom, spacing: DonkSpacing.m) {
                    ForEach([DonkSpacing.xs, DonkSpacing.s, DonkSpacing.m, DonkSpacing.l, DonkSpacing.xl, DonkSpacing.xxl], id: \.self) { value in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DonkColor.accent.opacity(0.7))
                                .frame(width: 14, height: value * 2)
                            Text("\(Int(value))").font(.caption2.monospacedDigit()).foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    Spacer()
                    ForEach([DonkRadius.badge, DonkRadius.medium, DonkRadius.card], id: \.self) { radius in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(DonkColor.accent, lineWidth: 1.5)
                            .frame(width: 36, height: 36)
                    }
                }
            }
        }
    }

    private func swatches(_ items: [(String, Color)]) -> some View {
        LazyVGrid(columns: columns, spacing: DonkSpacing.m) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous)
                        .fill(item.1)
                        .frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous)
                                .strokeBorder(DonkColor.separator, lineWidth: 0.5)
                        )
                    Text(item.0)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(10)
                .donkCardBackground(radius: DonkRadius.medium)
            }
        }
    }
}

// MARK: - Badges

struct GalleryBadgesPage: View {
    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "UNARY", "SERVER STREAM", "WS"]
    private let codes = [101, 200, 201, 204, 301, 304, 400, 401, 404, 429, 500, 503, 0]

    var body: some View {
        DonkScrollContainer {
            DonkCard(title: "Method badges", icon: "tag") {
                FlowRows(items: methods) { MethodBadge($0) }
            }
            DonkCard(title: "Status pills", icon: "number") {
                VStack(alignment: .leading, spacing: DonkSpacing.m) {
                    FlowRows(items: codes) { StatusPill(code: $0) }
                    HStack(spacing: DonkSpacing.s) {
                        StatusPill("OK", tone: DonkTone.grpcStatus(0))
                        StatusPill("NOT_FOUND", tone: DonkTone.grpcStatus(5))
                        StatusPill("UNAVAILABLE", tone: DonkTone.grpcStatus(14))
                        StatusPill("STREAMING", tone: .grpc, isLive: true)
                    }
                }
            }
            DonkCard(title: "Tone pills", icon: "capsule") {
                FlowRows(items: DonkTone.allCases) { tone in
                    TonePill(text: tone.rawValue.capitalized, tone: tone, icon: tone.defaultIcon)
                }
            }
            DonkCard(title: "Live & counts", icon: "dot.radiowaves.left.and.right") {
                HStack(spacing: DonkSpacing.l) {
                    ForEach([DonkTone.info, .success, .warning, .error, .grpc], id: \.self) { tone in
                        LiveDot(tone: tone)
                    }
                    Spacer()
                    CountBadge(3)
                    CountBadge(42, tone: .accent)
                    CountBadge(1280, tone: .warning, filled: false)
                }
                .padding(.vertical, 4)
            }
            DonkSectionHeader("Composed rows", count: 3)
            VStack(spacing: 0) {
                sampleRow(method: "GET", path: "/v1/accounts/42", host: "api.example.com", code: 200, duration: 0.084, size: 1_264)
                Divider().padding(.leading, DonkSpacing.l)
                sampleRow(method: "POST", path: "/v1/payments/authorize", host: "pay.example.com", code: 422, duration: 1.24, size: 312, modified: true)
                Divider().padding(.leading, DonkSpacing.l)
                sampleRow(method: "UNARY", path: "bank.v1.AccountService/GetBalance", host: "grpc.example.com", code: 0, duration: nil, size: 0)
            }
            .donkCardBackground()
        }
    }

    private func sampleRow(method: String, path: String, host: String, code: Int, duration: TimeInterval?, size: Int, modified: Bool = false) -> some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    MethodBadge(method)
                    if modified {
                        TonePill(text: "Modified", tone: .warning, icon: "wand.and.stars")
                    }
                }
                Text(path)
                    .font(DonkFont.code.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(2)
                Text([host, duration.map(DonkFormat.duration), size > 0 ? DonkFormat.bytes(size) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DonkSpacing.s)
            StatusPill(code: code)
        }
        .padding(.horizontal, DonkSpacing.l)
        .padding(.vertical, DonkSpacing.rowVertical)
    }
}

struct FlowRows<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: DonkSpacing.s, alignment: .leading)], alignment: .leading, spacing: DonkSpacing.s) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

// MARK: - Rows

struct GalleryRowsPage: View {
    var body: some View {
        DonkScrollContainer {
            DonkSectionHeader("Overview", icon: "info.circle") {
                Text("trailing").foregroundColor(DonkColor.textTertiary)
            }
            DonkCard(title: "Request", icon: "arrow.up.circle.fill", tone: .info) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "URL", value: "https://api.example.com/v1/accounts/42?expand=owner,limits", monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Method", value: "GET")
                    Divider()
                    KeyValueRow(key: "Status", value: "200 OK", valueTone: .success)
                    Divider()
                    KeyValueRow(key: "Duration", value: DonkFormat.duration(0.0842))
                    Divider()
                    KeyValueRow(key: "Started", value: DonkFormat.time(Date()), monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Remote address", value: "17.253.144.10:443", monospacedValue: true, layout: .vertical)
                }
            } accessory: {
                CopyButton(text: "https://api.example.com/v1/accounts/42", label: "URL")
            }
            HeaderListView(GallerySamples.headers, title: "Response Headers")
            HeaderListView([(String, String)](), title: "Trailers", emptyText: "No trailers")
            DonkCard(title: "cURL", icon: "terminal") {
                CodeView(text: GallerySamples.curl, language: .plain)
            } accessory: {
                CopyButton(text: GallerySamples.curl, label: "cURL", title: "Copy")
            }
            DonkSectionHeader("Label rows")
            VStack(spacing: 0) {
                DonkLabelRow(icon: "network", tone: .info, title: "Network", subtitle: "1,284 requests", value: "On")
                Divider().padding(.leading, 58)
                DonkLabelRow(icon: "speedometer", tone: .success, title: "Performance", subtitle: "FPS overlay hidden")
                Divider().padding(.leading, 58)
                DonkLabelRow(icon: "exclamationmark.triangle.fill", tone: .error, title: "Crashes") {
                    CountBadge(2)
                }
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.vertical, DonkSpacing.xs)
            .donkCardBackground()
        }
    }
}

// MARK: - Controls

struct GalleryControlsPage: View {
    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case request = "Request"
        case response = "Response"
    }

    enum WideTab: String, CaseIterable {
        case overview = "Overview"
        case request = "Request"
        case response = "Response"
        case timing = "Timing"
        case messages = "Messages"
        case metadata = "Metadata"
    }

    @State private var tab: DetailTab = .overview
    @State private var wideTab: WideTab = .overview
    @State private var http = true
    @State private var grpc = false
    @State private var web = false
    @State private var errors = false
    @State private var pinned = false
    @State private var query = ""

    var body: some View {
        DonkScrollContainer {
            DonkSectionHeader("Segmented tabs")
            SegmentedTabs(selection: $tab, tabs: DetailTab.allCases, title: \.rawValue)
            SegmentedTabs(
                selection: $wideTab,
                tabs: WideTab.allCases,
                title: \.rawValue,
                icon: { $0 == .messages ? "bubble.left.and.bubble.right.fill" : nil },
                badge: { $0 == .messages ? 12 : nil }
            )
            DonkSectionHeader("Filter chips")
            ChipRow(horizontalPadding: 0) {
                FilterChip(title: "HTTP", icon: "network", isOn: $http, tone: .info, count: 1284)
                FilterChip(title: "gRPC", icon: "point.3.connected.trianglepath.dotted", isOn: $grpc, tone: .grpc, count: 87)
                FilterChip(title: "Web", icon: "globe", isOn: $web, tone: .web, count: 12)
                FilterChip(title: "Errors", icon: "exclamationmark.triangle.fill", isOn: $errors, tone: .error, count: 5)
                FilterChip(title: "Pinned", icon: "pin.fill", isOn: $pinned, tone: .warning)
            }
            DonkSectionHeader("Search field")
            DonkSearchField(text: $query, prompt: "Filter by URL, header or body")
            DonkSectionHeader("Copy buttons")
            DonkCard {
                HStack(spacing: DonkSpacing.l) {
                    CopyButton(text: "icon only")
                    CopyButton(text: "titled", label: "Value", title: "Copy value")
                    Spacer()
                    Button("Pressable") {}
                        .buttonStyle(.donkPressable)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(DonkColor.accent.opacity(0.15)))
                }
            }
        }
    }
}

// MARK: - Tiles & charts

struct GalleryTilesPage: View {
    private let columns = [GridItem(.flexible(), spacing: DonkSpacing.m), GridItem(.flexible(), spacing: DonkSpacing.m)]

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let cpu = GallerySamples.series(seed: 0.3, base: 38, amplitude: 22, time: time)
            let memory = GallerySamples.series(seed: 1.7, base: 212, amplitude: 18, time: time)
            let fps = GallerySamples.series(seed: 2.9, base: 56, amplitude: 4, time: time).map { min(60, $0) }
            DonkScrollContainer {
                DonkSectionHeader("Tools")
                LazyVGrid(columns: columns, spacing: DonkSpacing.m) {
                    ToolTile(icon: "network", title: "Network", subtitle: "1,284 requests · 3 failed", tone: .info, badge: 3)
                    ToolTile(icon: "speedometer", title: "Performance", subtitle: "CPU \(Int(cpu.last ?? 0))% · \(Int(fps.last ?? 0)) FPS", tone: .success) {
                        SparklineView(values: cpu, range: 0...100, tone: .success)
                            .frame(height: 22)
                    }
                    ToolTile(icon: "viewfinder", title: "Inspector", subtitle: "Select, measure, grid", tone: .accent)
                    ToolTile(icon: "exclamationmark.triangle.fill", title: "Crashes", subtitle: "Last: 2h ago", tone: .error, badge: 2)
                    ToolTile(icon: "bell.badge.fill", title: "Push", subtitle: "Token registered", tone: .warning)
                    ToolTile(icon: "externaldrive.fill", title: "Storage", subtitle: "Files, defaults, keychain", tone: .web)
                }
                DonkSectionHeader("Metrics")
                LazyVGrid(columns: columns, spacing: DonkSpacing.m) {
                    MetricTile(title: "CPU", value: String(format: "%.0f", cpu.last ?? 0), unit: "%", tone: .success, icon: "cpu", sparkline: cpu, sparklineRange: 0...100)
                    MetricTile(title: "Memory", value: String(format: "%.0f", memory.last ?? 0), unit: "MB", tone: .info, icon: "memorychip", sparkline: memory)
                    MetricTile(title: "FPS", value: String(format: "%.0f", fps.last ?? 0), tone: .accent, icon: "gauge", sparkline: fps, sparklineRange: 0...60, footnote: "2 hitches")
                    MetricTile(title: "Thermal", value: "Nominal", tone: .neutral, icon: "thermometer")
                }
                DonkCard(title: "CPU & Memory", icon: "waveform.path.ecg") {
                    LineChartView(
                        series: [
                            DonkChartSeries("CPU", values: cpu, tone: .success),
                            DonkChartSeries("Main thread", values: cpu.map { $0 * 0.6 }, tone: .accent),
                        ],
                        range: 0...100,
                        threshold: 80,
                        unit: "%",
                        capacity: 60
                    )
                    .frame(height: 200)
                }
                DonkCard(title: "Memory", icon: "memorychip") {
                    LineChartView(values: memory, tone: .info, name: "Memory", unit: "MB", capacity: 60)
                        .frame(height: 180)
                }
                DonkCard(title: "Sparkline edge cases") {
                    HStack(spacing: DonkSpacing.l) {
                        sparkCase("Empty", values: [])
                        sparkCase("One", values: [42])
                        sparkCase("Flat", values: Array(repeating: 5, count: 20))
                        sparkCase("Filling", values: Array(cpu.suffix(12)), capacity: 60)
                    }
                }
            }
        }
    }

    private func sparkCase(_ title: String, values: [Double], capacity: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SparklineView(values: values, tone: .accent, capacity: capacity)
                .frame(height: 30)
            Text(title)
                .font(.caption2)
                .foregroundColor(DonkColor.textSecondary)
        }
    }
}

// MARK: - Empty state

struct GalleryEmptyPage: View {
    var body: some View {
        EmptyStateView(
            icon: "network.slash",
            title: "No requests yet",
            message: "Requests made by the app appear here as they happen. Pull to refresh or clear filters.",
            tone: .info,
            actionTitle: "Clear Filters"
        ) {
            DonkToast.show("Filters cleared", tone: .success)
        }
        .donkScreenBackground()
    }
}

// MARK: - Code

struct GalleryCodePage: View {
    @StateObject private var search = CodeSearchState()

    var body: some View {
        DonkScrollContainer {
            CodeSearchBar(state: search)
            DonkCard(title: "Response body", icon: "curlybraces") {
                CodeView(text: GallerySamples.json, language: .json, search: search)
            } accessory: {
                CopyButton(text: GallerySamples.json, label: "Body")
            }
            DonkCard(title: "Plain text", icon: "text.alignleft") {
                CodeView(text: GallerySamples.plainText, search: search)
            }
            NavigationLink {
                GalleryLargeCodePage()
                    .donkNavigationTitle("Large Body")
            } label: {
                DonkLabelRow(icon: "doc.text.fill", tone: .warning, title: "Open ~1 MB body", subtitle: "Scrolling mode, no highlighting above 300 KB")
                    .padding(DonkSpacing.m)
                    .donkCardBackground()
            }
            .buttonStyle(.donkPressable)
        }
    }
}

struct GalleryLargeCodePage: View {
    @StateObject private var search = CodeSearchState()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            CodeSearchBar(state: search)
                .padding(.horizontal, DonkSpacing.l)
                .padding(.vertical, DonkSpacing.s)
            if text.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeView(text: text, language: .json, search: search, layout: .scrolling)
            }
        }
        .donkScreenBackground()
        .task {
            guard text.isEmpty else { return }
            text = await Task.detached(priority: .userInitiated) {
                GallerySamples.largeValue(items: 4_000).prettyPrinted()
            }.value
        }
    }
}

struct GalleryEditorPage: View {
    @State private var text = GallerySamples.invalidJSON

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            CodeEditor(text: $text, language: .json, placeholder: "Paste JSON here")
            Text("\(DonkFormat.bytes(text.utf8.count)) · tap the error pill to jump to it")
                .font(.caption)
                .foregroundColor(DonkColor.textTertiary)
        }
        .padding(DonkSpacing.l)
        .donkScreenBackground()
    }
}

struct GalleryTreePage: View {
    @StateObject private var search = CodeSearchState()
    @State private var value: JSONValue

    init(large: Bool) {
        let value = large ? GallerySamples.largeValue(items: 700) : ((try? JSONValue.parse(GallerySamples.json)) ?? .null)
        self._value = State(initialValue: value)
    }

    var body: some View {
        GalleryTreeContent(value: value, search: search)
            .searchable(text: $search.query, prompt: "Search keys and values")
    }
}

struct GalleryTreeContent: View {
    let value: JSONValue
    @ObservedObject var search: CodeSearchState

    var body: some View {
        JSONTreeView(value: value, search: search)
            .background(DonkColor.card.ignoresSafeArea())
    }
}

struct GalleryBodyPage: View {
    enum Sample: String, CaseIterable {
        case json = "JSON"
        case text = "Text"
        case binary = "Binary"
        case empty = "Empty"
    }

    @State private var sample: Sample = .json
    @StateObject private var search = CodeSearchState()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DonkSpacing.s) {
                SegmentedTabs(selection: $sample, tabs: Sample.allCases, title: \.rawValue)
                CodeSearchBar(state: search)
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.vertical, DonkSpacing.s)
            Divider()
            Group {
                switch sample {
                case .json: JSONBodyView(data: GallerySamples.jsonData, search: search)
                case .text: JSONBodyView(text: GallerySamples.plainText, search: search)
                case .binary: JSONBodyView(data: GallerySamples.binaryData, search: search)
                case .empty: JSONBodyView(data: Data(), search: search)
                }
            }
            .id(sample)
        }
        .background(DonkColor.card.ignoresSafeArea())
    }
}

// MARK: - Feedback

struct GalleryFeedbackPage: View {
    var body: some View {
        DonkScrollContainer {
            DonkCard(title: "Toasts", icon: "bubble.middle.top.fill") {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    actionRow("Neutral") { DonkToast.show("Capture paused") }
                    actionRow("Success") { DonkToast.show("Rule saved", tone: .success) }
                    actionRow("Warning") { DonkToast.show("Breakpoint will auto-resume in 5 min", tone: .warning) }
                    actionRow("Error") { DonkToast.show("Export failed", tone: .error) }
                    actionRow("Repeat (replaces)") { DonkToast.show("Copied", icon: "doc.on.doc.fill", tone: .success) }
                    actionRow("Burst (stacks)") {
                        DonkToast.show("Request mocked", icon: "wand.and.stars", tone: .accent)
                        DonkToast.show("gRPC stream opened", tone: .grpc)
                        DonkToast.show("WebView navigation", tone: .web)
                        DonkToast.show("A much longer toast message that needs two lines to fit on narrow phones", tone: .info)
                    }
                    actionRow("Dismiss all") { DonkToast.dismissAll() }
                }
            }
            DonkCard(title: "Haptics", icon: "hand.tap.fill") {
                HStack(spacing: DonkSpacing.s) {
                    hapticButton("Light", DonkHaptics.light)
                    hapticButton("Medium", DonkHaptics.medium)
                    hapticButton("Select", DonkHaptics.selection)
                }
                HStack(spacing: DonkSpacing.s) {
                    hapticButton("Success", DonkHaptics.success)
                    hapticButton("Warning", DonkHaptics.warning)
                    hapticButton("Error", DonkHaptics.error)
                }
            }
            DonkCard(title: "Share & copy", icon: "square.and.arrow.up") {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    actionRow("Share text") { DonkShare.share(text: GallerySamples.curl) }
                    actionRow("Share JSON file") { DonkShare.share(fileNamed: "sample.json", data: GallerySamples.jsonData) }
                    actionRow("Copy with label") { DonkPasteboard.copy(GallerySamples.curl, label: "cURL") }
                }
            }
            DonkCard(title: "Formatting", icon: "textformat.123") {
                VStack(spacing: 0) {
                    KeyValueRow(key: "bytes(512)", value: DonkFormat.bytes(512), monospacedValue: true)
                    KeyValueRow(key: "bytes(1_234_567)", value: DonkFormat.bytes(1_234_567), monospacedValue: true)
                    KeyValueRow(key: "duration(0.084)", value: DonkFormat.duration(0.084), monospacedValue: true)
                    KeyValueRow(key: "duration(1.237)", value: DonkFormat.duration(1.237), monospacedValue: true)
                    KeyValueRow(key: "duration(123)", value: DonkFormat.duration(123), monospacedValue: true)
                    KeyValueRow(key: "relative(-12s)", value: DonkFormat.relative(Date().addingTimeInterval(-12)), monospacedValue: true)
                    KeyValueRow(key: "percent(0.423)", value: DonkFormat.percent(0.423), monospacedValue: true)
                    KeyValueRow(key: "compact(12_400)", value: DonkFormat.compact(12_400), monospacedValue: true)
                }
            }
        }
    }

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hapticButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(DonkColor.accent)
    }
}
