import Donk
import DonkUI
import SwiftUI

struct DemoMenuView: View {
    @EnvironmentObject private var inbox: PushInbox

    var body: some View {
        NavigationView {
            List {
                Section {
                    DemoHeroCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink(destination: NetworkDemoView()) {
                        DemoRow(icon: "network", tone: .info, title: "HTTP / URLSession", subtitle: "Requests, uploads, streaming, errors")
                    }
                    NavigationLink(destination: GRPCDemoView()) {
                        DemoRow(icon: "point.3.connected.trianglepath.dotted", tone: .grpc, title: "gRPC", subtitle: "Unary and streaming calls")
                    }
                    NavigationLink(destination: WebViewDemoView()) {
                        DemoRow(icon: "safari", tone: .web, title: "WebView", subtitle: "Page loads, fetch and XHR")
                    }
                    NavigationLink(destination: NetworkUIDemoView()) {
                        DemoRow(icon: "tray.full", tone: .accent, title: "Sample traffic", subtitle: "Fill the log with realistic entries")
                    }
                } header: {
                    DonkSectionHeader("Network")
                }
                Section {
                    NavigationLink(destination: InspectorDemoView()) {
                        DemoRow(icon: "square.dashed", tone: .accent, title: "Inspector playground", subtitle: "Layouts to select, measure and sample")
                    }
                } header: {
                    DonkSectionHeader("UI")
                }
                Section {
                    NavigationLink(destination: PerformanceDemoView()) {
                        DemoRow(icon: "speedometer", tone: .success, title: "Performance", subtitle: "CPU load, hitches and hangs")
                    }
                    NavigationLink(destination: CrashDemoView()) {
                        DemoRow(icon: "exclamationmark.octagon", tone: .error, title: "Crashes", subtitle: "Signals, exceptions and reports")
                    }
                    NavigationLink(destination: PushDemoView()) {
                        DemoRow(icon: "bell.badge", tone: .warning, title: "Push notifications", subtitle: "Simulated and real pushes")
                    }
                    NavigationLink(destination: StorageDemoView()) {
                        DemoRow(icon: "folder", tone: .web, title: "Files & defaults", subtitle: "Sample files, defaults and keychain")
                    }
                } header: {
                    DonkSectionHeader("System")
                }
                DemoDiagnosticsSection()
                if !inbox.items.isEmpty {
                    Section {
                        ForEach(inbox.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.payload)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .lineLimit(6)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        DonkSectionHeader("Received pushes", count: inbox.items.count)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("donk demo")
        }
        .navigationViewStyle(.stack)
        .tint(DonkColor.accent)
    }
}

private struct DemoHeroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [DonkColor.accent, DonkColor.grpc], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug this app")
                        .font(DonkFont.headline)
                    Text("Tap the bubble, shake the device, or open a tool below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button {
                    Donk.show()
                } label: {
                    Label("Open donk", systemImage: "ladybug.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(DonkColor.accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.donkPressable)
                Menu {
                    ForEach(DonkTool.allCases, id: \.self) { tool in
                        Button {
                            Donk.show(tool)
                        } label: {
                            Label(tool.demoTitle, systemImage: tool.demoIcon)
                        }
                    }
                } label: {
                    Label("Jump to", systemImage: "chevron.up.chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(DonkColor.accent.opacity(0.14)))
                        .foregroundColor(DonkColor.accent)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct DemoRow: View {
    let icon: String
    let tone: DonkTone
    let title: String
    let subtitle: String

    var body: some View {
        DonkLabelRow(icon: icon, tone: tone, title: title, subtitle: subtitle)
    }
}

private extension DonkTool {
    var demoTitle: String {
        switch self {
        case .network: return "Network"
        case .rules: return "Network rules"
        case .performance: return "Performance"
        case .inspector: return "UI Inspector"
        case .push: return "Push"
        case .storage: return "Storage"
        case .crashes: return "Crashes"
        case .settings: return "Settings"
        }
    }

    var demoIcon: String {
        switch self {
        case .network: return "network"
        case .rules: return "wand.and.stars"
        case .performance: return "speedometer"
        case .inspector: return "viewfinder"
        case .push: return "bell.badge"
        case .storage: return "folder"
        case .crashes: return "exclamationmark.octagon"
        case .settings: return "gearshape"
        }
    }
}
