import Donk
import DonkUI
import SwiftUI

struct PerformanceDemoView: View {
    private let scenario: PerformanceDemoScenario?

    @StateObject private var burner = CPUBurner()
    @StateObject private var hog = MemoryHog()
    @State private var isRunning = DonkPerformance.isRunning
    @State private var isHUDVisible = false
    @State private var staysAboveKeyboard = false
    @State private var showsDashboard = false
    @State private var detailEvent: PerformanceEvent?
    @State private var showsJank = false
    @State private var note = ""
    @State private var didRunScenario = false
    @State private var scrollTarget: String?
    @FocusState private var isNoteFocused: Bool

    init(scenario: PerformanceDemoScenario? = nil) {
        self.scenario = scenario
        if scenario == nil {
            PerformanceDemoAutomation.bootstrapIfNeeded()
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                monitoringSection
                homeTileSection
                cpuSection
                memorySection
                hangSection
                jankSection
                keyboardSection
            }
            .listStyle(.insetGrouped)
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(isActive: $showsJank) {
                JankListView()
            } label: {
                EmptyView()
            }
            .hidden()
        )
        .sheet(isPresented: $showsDashboard) {
            DonkNavigationContainer {
                DonkPerformance.makeRootView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showsDashboard = false }
                        }
                    }
            }
        }
        .sheet(item: $detailEvent) { event in
            DonkNavigationContainer {
                DonkPerformance.makeEventDetailView(event)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { detailEvent = nil }
                        }
                    }
            }
        }
        .onAppear {
            startMonitoringIfNeeded()
            isHUDVisible = DonkPerformance.isHUDVisible
            staysAboveKeyboard = DonkPerformance.hudStaysAboveKeyboard
            runScenarioIfNeeded()
        }
        .onChange(of: isHUDVisible) { visible in
            if DonkPerformance.isHUDVisible != visible {
                DonkPerformance.isHUDVisible = visible
            }
        }
        .onChange(of: staysAboveKeyboard) { enabled in
            if DonkPerformance.hudStaysAboveKeyboard != enabled {
                DonkPerformance.hudStaysAboveKeyboard = enabled
            }
        }
    }

    // MARK: - Sections

    private var monitoringSection: some View {
        Section {
            HStack {
                Label(isRunning ? "Monitoring" : "Stopped", systemImage: isRunning ? "waveform.path.ecg" : "pause.circle")
                    .foregroundColor(isRunning ? .green : .secondary)
                Spacer()
                Button(isRunning ? "Stop" : "Start") {
                    if isRunning {
                        DonkPerformance.stop()
                    } else {
                        DonkPerformance.start(PerformanceConfiguration())
                    }
                    isRunning = DonkPerformance.isRunning
                }
                .buttonStyle(.bordered)
            }
            Toggle(isOn: $isHUDVisible) {
                Label("FPS HUD", systemImage: "gauge")
            }
            Button {
                showsDashboard = true
            } label: {
                Label("Open performance dashboard", systemImage: "chart.xyaxis.line")
            }
        } header: {
            Text("Monitoring")
        } footer: {
            Text("The HUD stays above sheets, pushes and alerts. Tap it to show CPU, memory and hitches; drag it to any edge.")
        }
    }

    private var homeTileSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showsDashboard = true
                } label: {
                    ToolTile(icon: "speedometer", title: "Performance", subtitle: "Live CPU · FPS", tone: .success) {
                        DonkPerformance.makeDashboardSparkline()
                            .frame(height: 36)
                    }
                }
                .buttonStyle(.donkPressable)
                Color.clear
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Home tile preview")
        } footer: {
            Text("DonkPerformance.makeDashboardSparkline() as the umbrella's home screen shows it.")
        }
    }

    private var cpuSection: some View {
        Section {
            Stepper(value: $burner.threadCount, in: 1...8) {
                HStack {
                    Text("Busy threads")
                    Spacer()
                    Text("\(burner.threadCount)")
                        .font(.body.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .disabled(burner.isBurning)
            Button {
                burner.isBurning ? burner.stop() : burner.burn(for: 10)
            } label: {
                Label(
                    burner.isBurning ? "Stop burning (\(burner.secondsLeft) s left)" : "Burn CPU for 10 s",
                    systemImage: burner.isBurning ? "stop.circle.fill" : "flame.fill"
                )
            }
            .tint(burner.isBurning ? .red : .orange)
        } header: {
            Text("CPU burner")
        } footer: {
            Text("Each thread spins one core. Two or more threads push total CPU past 100% (percent of one core) and trigger the sustained CPU alert after 10 s.")
        }
    }

    private var memorySection: some View {
        Section {
            HStack {
                Text("Allocated")
                Spacer()
                Text("\(hog.totalBytes / 1_048_576) MB in \(hog.chunkCount) chunk\(hog.chunkCount == 1 ? "" : "s")")
                    .font(.body.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Button {
                hog.allocateChunk()
            } label: {
                Label(hog.isAllocating ? "Allocating…" : "Allocate and touch 50 MB", systemImage: "plus.square.on.square")
            }
            .disabled(hog.isAllocating)
            Button(role: .destructive) {
                hog.releaseAll()
            } label: {
                Label("Release all", systemImage: "trash")
            }
            .disabled(hog.chunkCount == 0)
            Button {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
            } label: {
                Label("Post memory warning", systemImage: "exclamationmark.triangle")
            }
        } header: {
            Text("Memory hog")
        } footer: {
            Text("Growing by more than 50 MB within 3 minutes raises a memory growth alert. On the Simulator use Debug › Simulate Memory Warning for a real system warning.")
        }
    }

    private var hangSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach([0.5, 1.5, 3.0], id: \.self) { seconds in
                    Button {
                        MainThreadStall.simulateHeavyWork(seconds: seconds)
                    } label: {
                        Text(seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(seconds >= 2 ? .red : (seconds >= 1 ? .orange : .yellow))
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Main thread hang")
        } footer: {
            Text("Blocks the main thread with real work. Hangs of 250 ms or more are logged and alerted; from 1 s the main thread's stack is captured while it is still stuck. Open the dashboard and tap the hang to see it.")
        }
    }

    private var jankSection: some View {
        Section {
            Button {
                showsJank = true
            } label: {
                Label("Heavy animated list", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("Jank")
        } footer: {
            Text("Animated rows that burn main-thread time every frame. Watch FPS drop and the hitch ratio climb.")
        }
    }

    private var keyboardSection: some View {
        Section {
            Toggle(isOn: $staysAboveKeyboard) {
                Label("HUD stays above keyboard", systemImage: "keyboard")
            }
            TextField("Type to show the keyboard", text: $note)
                .focused($isNoteFocused)
                .id("keyboard")
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Off (default): the keyboard covers the HUD, so the pill never hides a key. On: the HUD is raised above the keyboard and moves up so it stays clear of the keys.")
        }
    }

    // MARK: - Helpers

    private func startMonitoringIfNeeded() {
        if !DonkPerformance.isRunning {
            DonkPerformance.start(PerformanceConfiguration())
        }
        isRunning = DonkPerformance.isRunning
    }

    private func runScenarioIfNeeded() {
        guard let scenario, !didRunScenario else { return }
        didRunScenario = true
        let showsHUD = scenario == .hud || scenario == .keyboard || scenario == .keyboardAbove || scenario == .jank
        DonkPerformance.isHUDVisible = showsHUD
        isHUDVisible = showsHUD
        switch scenario {
        case .demo:
            break
        case .hud:
            isHUDVisible = true
        case .burnDashboard:
            isHUDVisible = false
            burner.threadCount = 4
            burner.burn(for: 20)
            after(1) { showsDashboard = true }
            scrollDashboardIfRequested(after: 5)
        case .dashboard:
            after(1) { showsDashboard = true }
            scrollDashboardIfRequested(after: 4)
        case .dashboardReopen:
            for round in 0..<3 {
                let start = 1 + Double(round) * 5
                after(start) { showsDashboard = true }
                after(start + 3) { showsDashboard = false }
            }
        case .dashboardEvents:
            after(1) { MainThreadStall.simulateHeavyWork(seconds: 1.3) }
            after(3) { MainThreadStall.simulateHeavyWork(seconds: 0.4) }
            after(3.5) {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
            }
            after(5) { showsDashboard = true }
            scrollDashboardIfRequested(after: 8)
        case .hangToast:
            isHUDVisible = false
            after(2.5) { MainThreadStall.simulateHeavyWork(seconds: 0.8) }
        case .hangDetail:
            isHUDVisible = false
            after(1.5) {
                MainThreadStall.simulateHeavyWork(seconds: 1.8)
                presentLatestHang(attempts: 30)
            }
        case .keyboard, .keyboardAbove:
            isHUDVisible = true
            staysAboveKeyboard = scenario == .keyboardAbove
            DonkPerformance.hudStaysAboveKeyboard = staysAboveKeyboard
            after(0.8) { scrollTarget = "keyboard" }
            after(1.6) { isNoteFocused = true }
        case .debuggerDashboard:
            isHUDVisible = false
            after(1.5) { Donk.show(.performance) }
        case .jank:
            isHUDVisible = true
            after(0.5) { showsJank = true }
        }
    }

    private func scrollDashboardIfRequested(after delay: TimeInterval) {
        guard let fraction = PerformanceDemoAutomation.scrollFraction else { return }
        after(delay) { PerformanceDemoAutomation.scrollPresentedContent(to: fraction) }
    }

    private func presentLatestHang(attempts: Int) {
        if let hang = DonkPerformance.recentEvents.first(where: { $0.isHang && $0.backtrace != nil }) {
            detailEvent = hang
        } else if attempts > 0 {
            after(0.5) { presentLatestHang(attempts: attempts - 1) }
        }
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
