import DonkCore
import DonkInspector
import DonkPerformance
import DonkUI
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject var router: DebuggerRouter

    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DonkSpacing.xl) {
                HomeHeaderCard(info: DonkEnvironment.appInfo)
                banners
                if !visibleTools.isEmpty {
                    toolsSection
                }
                if hasToggles {
                    togglesSection
                }
                if model.tools.contains(.settings) {
                    settingsSection
                }
                footer
            }
            .padding(.horizontal, DonkSpacing.screen)
            .padding(.top, DonkSpacing.s)
            .padding(.bottom, DonkSpacing.xxl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: HomeWidthKey.self, value: proxy.size.width)
                }
            )
        }
        .onPreferenceChange(HomeWidthKey.self) { contentWidth = $0 }
        .background(routeLinks)
        .donkScreenBackground()
        .navigationTitle("donk")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    DonkRuntime.shared.hide()
                } label: {
                    Text("Done").fontWeight(.semibold)
                }
                .accessibilityHint("Closes the debugger")
            }
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Routes

    private var routeLinks: some View {
        VStack(spacing: 0) {
            ForEach(DonkTool.allCases.filter { model.tools.contains($0) }, id: \.self) { tool in
                NavigationLink(isActive: router.binding(for: tool)) {
                    HomeDestination(tool: tool)
                } label: {
                    EmptyView()
                }
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: - Banners

    private var showsRulesBanner: Bool {
        model.activeRuleCount > 0 && model.tools.contains(.rules)
    }

    @ViewBuilder
    private var banners: some View {
        if !model.paused.isEmpty || showsRulesBanner {
            VStack(spacing: DonkSpacing.s) {
                if !model.paused.isEmpty {
                    HomeBanner(
                        icon: "pause.circle.fill",
                        title: pausedTitle,
                        message: "Waiting for your decision · tap to review",
                        tone: .warning,
                        isLive: true
                    ) {
                        DonkRuntime.shared.breakpoints.presentFirstPending()
                    }
                }
                if showsRulesBanner {
                    HomeBanner(
                        icon: "wand.and.stars",
                        title: "\(model.activeRuleCount) \(model.activeRuleCount == 1 ? "rule" : "rules") active",
                        message: "Responses may be modified",
                        tone: .accent
                    ) {
                        router.open(.rules)
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var pausedTitle: String {
        let count = model.paused.count
        return count == 1 ? "1 request paused" : "\(count) requests paused"
    }

    // MARK: - Tools

    private var columns: Int {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 2 }
        let width = contentWidth > 0 ? contentWidth : 700
        return min(max(Int(width / 200), 2), 4)
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            DonkSectionHeader("Tools")
                .padding(.horizontal, DonkSpacing.xs)
            VStack(spacing: DonkSpacing.m) {
                ForEach(rows(of: visibleTools, columns: columns), id: \.self) { row in
                    HStack(alignment: .top, spacing: DonkSpacing.m) {
                        ForEach(row, id: \.self) { tool in
                            toolLink(tool)
                        }
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func rows(of tools: [HomeTool], columns: Int) -> [[HomeTool]] {
        stride(from: 0, to: tools.count, by: columns).map { start in
            Array(tools[start..<min(start + columns, tools.count)])
        }
    }

    private var visibleTools: [HomeTool] {
        HomeTool.grid.filter { model.tools.contains($0.destination) }
    }

    private func toolLink(_ tool: HomeTool) -> some View {
        Button {
            router.open(tool.destination)
        } label: {
            tile(for: tool)
        }
        .buttonStyle(.donkPressable)
    }

    @ViewBuilder
    private func tile(for tool: HomeTool) -> some View {
        switch tool {
        case .network:
            ToolTile(
                icon: "network",
                title: "Network",
                subtitle: model.isCaptureEnabled ? model.stats.subtitle : "Capture paused",
                tone: .info
            ) {
                if model.stats.failures > 0 {
                    TonePill(text: "\(DonkFormat.compact(model.stats.failures)) failed", tone: .error, icon: "exclamationmark.triangle.fill")
                }
            }
        case .performance:
            ToolTile(icon: "speedometer", title: "Performance", subtitle: "CPU, memory, FPS", tone: .success) {
                DonkPerformance.makeDashboardSparkline()
                    .frame(maxWidth: 132)
                    .frame(height: 26)
                    .clipped()
                    .allowsHitTesting(false)
            }
        case .inspector:
            ToolTile(
                icon: "viewfinder",
                title: "UI Inspector",
                subtitle: model.inspectorMode.map { "Active · \($0.shortTitle)" } ?? "Select, frames, grid, colors",
                tone: .accent
            )
        case .push:
            ToolTile(icon: "bell.badge", title: "Push", subtitle: "Simulate & review", tone: .warning)
        case .storage:
            ToolTile(icon: "folder", title: "Storage", subtitle: "Files, defaults, keychain", tone: .web)
        case .crashes:
            ToolTile(
                icon: "exclamationmark.octagon",
                title: "Crashes",
                subtitle: crashSubtitle,
                tone: .error,
                badge: model.crashCount > 0 ? model.crashCount : nil
            )
        }
    }

    private var crashSubtitle: String {
        if model.crashCount > 0 {
            return model.crashCount == 1 ? "1 report" : "\(DonkFormat.compact(model.crashCount)) reports"
        }
        return model.isCrashReporterInstalled ? "No crashes recorded" : "Reporter not installed"
    }

    // MARK: - Toggles

    private enum QuickToggle: Hashable {
        case hud, inspector(InspectorMode), capture
    }

    private var quickToggles: [QuickToggle] {
        var toggles: [QuickToggle] = []
        if model.tools.contains(.performance) {
            toggles.append(.hud)
        }
        if model.tools.contains(.inspector) {
            toggles.append(contentsOf: [InspectorMode.frames, .grid, .colorPicker].map(QuickToggle.inspector))
        }
        if model.tools.contains(.network) {
            toggles.append(.capture)
        }
        return toggles
    }

    private var hasToggles: Bool {
        !quickToggles.isEmpty
    }

    private var togglesSection: some View {
        let toggles = quickToggles
        return VStack(alignment: .leading, spacing: DonkSpacing.s) {
            DonkSectionHeader("Quick toggles")
                .padding(.horizontal, DonkSpacing.xs)
            DonkCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(toggles.enumerated()), id: \.element) { index, toggle in
                        if index > 0 {
                            rowDivider
                        }
                        quickToggleRow(toggle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quickToggleRow(_ toggle: QuickToggle) -> some View {
        switch toggle {
        case .hud:
            toggleRow(
                icon: "speedometer",
                tone: .success,
                title: "FPS HUD",
                subtitle: "Frame-rate overlay",
                isOn: Binding(get: { model.isHUDVisible }, set: { model.setHUDVisible($0) })
            )
        case .inspector(.frames):
            inspectorToggle(.frames, icon: "square.dashed", tone: .info, subtitle: "Outline every view")
        case .inspector(.grid):
            inspectorToggle(.grid, icon: "square.grid.3x3", tone: .accent, subtitle: "Alignment grid overlay")
        case let .inspector(mode):
            inspectorToggle(mode, icon: "eyedropper", tone: .grpc, subtitle: "Sample any pixel")
        case .capture:
            toggleRow(
                icon: "antenna.radiowaves.left.and.right",
                tone: .web,
                title: "Capture network",
                subtitle: model.isCaptureEnabled ? "Recording all traffic" : "Paused, nothing is recorded",
                isOn: Binding(get: { model.isCaptureEnabled }, set: { model.setCaptureEnabled($0) })
            )
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 58)
    }

    private func inspectorToggle(_ mode: InspectorMode, icon: String, tone: DonkTone, subtitle: String) -> some View {
        toggleRow(
            icon: icon,
            tone: tone,
            title: mode.menuTitle,
            subtitle: subtitle,
            isOn: Binding(
                get: { model.inspectorMode == mode },
                set: { model.setInspector(mode, isOn: $0) }
            )
        )
    }

    private func toggleRow(icon: String, tone: DonkTone, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        DonkLabelRow(icon: icon, tone: tone, title: title, subtitle: subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, DonkSpacing.l)
        .padding(.vertical, 6)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Button {
            router.open(.settings)
        } label: {
            DonkLabelRow(icon: "gearshape.fill", tone: .neutral, title: "Settings", subtitle: "Launcher, capture limits, hosts, data") {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.vertical, 10)
            .donkCardBackground()
        }
        .buttonStyle(.donkPressable)
    }

    private var footer: some View {
        Text("donk \(Donk.version)")
            .font(DonkFont.codeCaption)
            .foregroundColor(DonkColor.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, DonkSpacing.xs)
            .accessibilityLabel("donk version \(Donk.version)")
    }
}

// MARK: - Tools

enum HomeTool: Hashable, CaseIterable {
    case network, performance, inspector, push, storage, crashes

    static let grid: [HomeTool] = allCases

    var destination: DonkTool {
        switch self {
        case .network: return .network
        case .performance: return .performance
        case .inspector: return .inspector
        case .push: return .push
        case .storage: return .storage
        case .crashes: return .crashes
        }
    }
}

struct HomeDestination: View {
    let tool: DonkTool

    var body: some View {
        DebuggerDestination.view(for: tool)
    }
}

private struct HomeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Banner

struct HomeBanner: View {
    let icon: String
    let title: String
    let message: String
    let tone: DonkTone
    var isLive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge(icon, tone: tone, size: 34, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(DonkFont.rounded(.subheadline, weight: .semibold))
                            .foregroundColor(DonkColor.textPrimary)
                        if isLive {
                            LiveDot(tone: tone, size: 7)
                        }
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DonkSpacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(tone.color)
            }
            .padding(.horizontal, DonkSpacing.m + 2)
            .padding(.vertical, DonkSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .fill(tone.softBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .strokeBorder(tone.color.opacity(0.28), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous))
        }
        .buttonStyle(.donkPressable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
