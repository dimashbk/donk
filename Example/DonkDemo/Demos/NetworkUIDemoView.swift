import Combine
import Donk
import DonkUI
import SwiftUI
import UIKit

struct NetworkUIDemoView: View {
    @State private var showsNetwork = false
    @State private var count = NetworkStore.shared.count
    @State private var captureEnabled = NetworkStore.shared.isCaptureEnabled
    @State private var activeRules = RuleStore.shared.rules.filter(\.isEnabled).count

    init() {
        NetworkUIDemoLauncher.handleLaunchArgumentsOnce()
    }

    var body: some View {
        List {
            Section {
                Button {
                    showsNetwork = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Network Inspector")
                                .font(.headline)
                            Text("\(count) captured · \(activeRules) rules active")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("The capture engine is not running in this demo, so the buttons below write realistic traffic straight into NetworkStore and drive gRPC calls through GRPCCallRecorder.")
            }

            Section("Sample traffic") {
                action("Seed everything", icon: "sparkles", detail: "HTTP, gRPC, WebView, live streams") {
                    SampleTraffic.seedAll()
                }
                action("HTTP showcase", icon: "network", detail: "All methods, 2xx–5xx, bodies of every kind") {
                    SampleTraffic.seedHTTP(base: Date().addingTimeInterval(-120))
                }
                action("In-flight requests", icon: "hourglass", detail: "Complete after 3–9 seconds") {
                    SampleTraffic.startInFlight()
                }
                action("Server-sent events", icon: "dot.radiowaves.left.and.right", detail: "Body grows every 650 ms") {
                    SampleTraffic.startEventStream()
                }
                action("gRPC calls", icon: "point.3.connected.trianglepath.dotted", detail: "Unary, UNAVAILABLE, server/client/bidi streams") {
                    SampleTraffic.startGRPC()
                }
                action("WebView traffic", icon: "safari", detail: "Full, metadata-only and observed") {
                    SampleTraffic.seedWebView(base: Date())
                }
                action("Live trickle", icon: "drop", detail: "A new request every 1.5 s for a minute") {
                    SampleTraffic.startTrickle()
                }
                action("Add 1,000 requests", icon: "square.stack.3d.up.fill", detail: "Stress the list") {
                    SampleTraffic.addBulk(count: 1000)
                }
            }

            Section("Rules & breakpoints") {
                action("Install sample rules", icon: "wand.and.stars", detail: "Map Local, Rewrite, Breakpoint") {
                    SampleTraffic.installRules()
                }
                action("Pause an HTTP request", icon: "pause.circle", detail: "Request-phase breakpoint") {
                    SampleTraffic.triggerRequestBreakpoint()
                    showsNetwork = true
                }
                action("Pause a gRPC response", icon: "pause.rectangle", detail: "Response-phase breakpoint") {
                    SampleTraffic.triggerGRPCResponseBreakpoint()
                    showsNetwork = true
                }
            }

            Section("Store") {
                Toggle(isOn: Binding(get: { captureEnabled }, set: { value in
                    captureEnabled = value
                    NetworkStore.shared.isCaptureEnabled = value
                })) {
                    Label("Capture enabled", systemImage: "record.circle")
                }
                Button(role: .destructive) {
                    NetworkStore.shared.clear(keepPinned: false)
                } label: {
                    Label("Clear everything (including pinned)", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Sample traffic")
        .sheet(isPresented: $showsNetwork) {
            NetworkDemoContainer(closable: true)
        }
        .onReceive(NetworkStore.shared.events.throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)) { _ in
            count = NetworkStore.shared.count
        }
        .onReceive(RuleStore.shared.changes.receive(on: DispatchQueue.main)) { rules in
            activeRules = rules.filter(\.isEnabled).count
        }
        .onAppear {
            captureEnabled = NetworkStore.shared.isCaptureEnabled
            count = NetworkStore.shared.count
        }
    }

    private func action(_ title: String, icon: String, detail: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 26)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Container

struct NetworkDemoContainer: View {
    let closable: Bool
    @StateObject private var breakpoints = DemoBreakpointObserver()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DonkNavigationContainer {
            DonkNetworkUI.makeRootView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if closable {
                            Button("Close") { dismiss() }
                        }
                    }
                }
        }
        .donkTheme()
        .sheet(item: Binding(get: { breakpoints.current }, set: { breakpoints.current = $0 })) { exchange in
            DonkNavigationContainer {
                DonkNetworkUI.makeBreakpointView(exchange)
            }
            .donkTheme()
        }
    }
}

@MainActor
final class DemoBreakpointObserver: ObservableObject {
    @Published var current: PausedExchange?
    private var cancellable: AnyCancellable?

    init() {
        cancellable = BreakpointCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard let self else { return }
                if let current = self.current, pending.contains(where: { $0.id == current.id }) { return }
                self.current = pending.first
            }
    }
}

// MARK: - Launch arguments

@MainActor
enum NetworkUIDemoLauncher {
    private static var handled = false

    static func handleLaunchArgumentsOnce() {
        guard !handled else { return }
        handled = true
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-NetworkUIDemo") else { return }
        NetworkStore.shared.clear(keepPinned: false)
        SampleTraffic.installRules()
        if !arguments.contains("-NetworkUIDemoEmpty") {
            SampleTraffic.seedAll()
        }
        if arguments.contains("-NetworkUIDemoBulk") {
            SampleTraffic.addBulk(count: 1000)
        }
        if arguments.contains("-NetworkUIDemoTrickle") {
            SampleTraffic.startTrickle()
        }
        let entryQuery = value(after: "-NetworkUIDemoEntry", in: arguments)
        let screen = value(after: "-NetworkUIDemoScreen", in: arguments)
        DispatchQueue.main.asyncAfter(deadline: .now() + (entryQuery == nil ? 0.5 : 1.5)) {
            if let entryQuery, let entry = NetworkStore.shared.snapshot().first(where: { $0.request.url.contains(entryQuery) }) {
                present(DonkNavigationContainer { DonkNetworkUI.makeDetailView(entryID: entry.id) }.donkTheme())
            } else if screen == "rules" {
                present(DonkNavigationContainer { DonkNetworkUI.makeRulesView() }.donkTheme())
            } else {
                present(NetworkDemoContainer(closable: false))
            }
        }
        if arguments.contains("-NetworkUIDemoBreakpoint") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                SampleTraffic.triggerRequestBreakpoint()
            }
        }
        if arguments.contains("-NetworkUIDemoGRPCBreakpoint") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                SampleTraffic.triggerGRPCResponseBreakpoint()
            }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func present<Content: View>(_ content: Content) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        let host = UIHostingController(rootView: content)
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)
    }
}
