import DonkUI
import SwiftUI

struct PerformanceDashboardView: View {
    @StateObject private var model = DashboardModel()
    @State private var confirmsReset = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DonkSpacing.l) {
                content
            }
            .padding(DonkSpacing.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .donkScreenBackground()
        .donkNavigationTitle("Performance")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                moreMenu
            }
        }
        .confirmationDialog("Reset performance history?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset History", role: .destructive) {
                model.resetHistory()
            }
        } message: {
            Text("Clears the last 5 minutes of samples, threads and events.")
        }
        .onAppear { model.screenDidAppear() }
        .onDisappear { model.screenDidDisappear() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.isRunning {
            StoppedCard(hasHistory: !model.snapshot.samples.isEmpty) {
                model.startMonitoring()
            }
        }
        StatusCard(model: model)
        SegmentedTabs(selection: $model.chartWindow, tabs: ChartWindow.allCases, title: { $0.rawValue })
        CPUCard(model: model)
        MemoryCard(model: model)
        FramesCard(model: model)
        GPUCard(model: model)
        ThreadsCard(threads: model.snapshot.threads)
        EventsCard(events: model.snapshot.events)
        ControlsCard(model: model, confirmsReset: $confirmsReset)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                DonkPasteboard.copy(model.reportText, label: "Report")
            } label: {
                Label("Copy Report", systemImage: "doc.on.doc")
            }
            Button {
                DonkShare.share(fileNamed: "donk-performance.txt", data: Data(model.reportText.utf8))
            } label: {
                Label("Share Report", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                confirmsReset = true
            } label: {
                Label("Reset History", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

// MARK: - Stopped

private struct StoppedCard: View {
    let hasHistory: Bool
    let start: () -> Void

    var body: some View {
        DonkCard(title: "Monitoring is stopped", icon: "pause.circle.fill", tone: .warning) {
            Text(hasHistory ? "Showing the history recorded before monitoring stopped." : "Start monitoring to collect CPU, memory, frame and hang data.")
                .font(DonkFont.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: start) {
                Label("Start Monitoring", systemImage: "play.fill")
                    .font(DonkFont.label)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Status

private struct StatusCard: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        let sample = model.latest
        DonkCard(padding: 14) {
            HStack(spacing: DonkSpacing.m) {
                LiveDot(tone: model.isRunning ? .success : .neutral, size: 9, isAnimating: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isRunning ? "Live" : "Stopped")
                        .font(DonkFont.rounded(.subheadline, weight: .semibold))
                        .foregroundColor(DonkColor.textPrimary)
                    Text("Sampling at \(model.rate.title) · \(model.snapshot.samples.count) samples · 5 min history")
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            ChipRow(spacing: DonkSpacing.xs, horizontalPadding: 0) {
                let thermal = sample?.thermalState ?? ProcessInfo.processInfo.thermalState
                TonePill("Thermal: \(thermal.title)", tone: thermal.tone, icon: "thermometer")
                if sample?.isLowPowerModeEnabled ?? ProcessInfo.processInfo.isLowPowerModeEnabled {
                    TonePill("Low Power", tone: .warning, icon: "battery.25")
                }
                TonePill("\(model.maximumFPS) Hz", tone: .info, icon: "display")
                if !model.alertsEnabled {
                    TonePill("Alerts off", tone: .neutral, icon: "bell.slash")
                }
            }
        }
    }
}

// MARK: - Controls

private struct ControlsCard: View {
    @ObservedObject var model: DashboardModel
    @Binding var confirmsReset: Bool
    @State private var showsOverhead = false

    static let overheadText = "While monitoring runs, donk keeps a CADisplayLink on the main run loop (one callback per frame: 60 Hz, or up to 120 Hz only when you request it below), a watchdog thread that pings the main queue 10 times a second, and a sampler at the selected rate. Expect a small, constant CPU and battery cost, mostly from waking the main thread each frame. Stop monitoring with DonkPerformance.stop() when you don't need it."

    var body: some View {
        DonkCard(title: "Controls", icon: "slider.horizontal.3", tone: .neutral) {
            InfoDisclosure(text: Self.overheadText, isExpanded: $showsOverhead)
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { model.preferences.isHUDVisible }, set: { model.setHUDVisible($0) })) {
                    DonkLabelRow(icon: "gauge", tone: .accent, title: "FPS HUD", subtitle: "Floating counter above all screens")
                }
                .padding(.vertical, DonkSpacing.s)
                Divider()
                Toggle(isOn: Binding(get: { model.preferences.hudStaysAboveKeyboard }, set: { model.setHUDStaysAboveKeyboard($0) })) {
                    DonkLabelRow(icon: "keyboard", tone: .info, title: "Stay above keyboard", subtitle: "Raise the HUD over the keyboard and keep it clear of the keys")
                }
                .disabled(!model.preferences.isHUDVisible)
                .padding(.vertical, DonkSpacing.s)
                Divider()
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    DonkLabelRow(icon: "metronome", tone: .info, title: "Sampling rate", subtitle: "CPU, memory and GPU sampling off the main thread")
                    SegmentedTabs(
                        selection: Binding(get: { model.rate }, set: { model.setRate($0) }),
                        tabs: PerformanceSamplingRate.allCases,
                        title: { $0.title }
                    )
                }
                .padding(.vertical, DonkSpacing.m)
                Divider()
                Toggle(isOn: Binding(get: { model.preferences.prefersHighRefreshRate }, set: { model.setPrefersHighRefreshRate($0) })) {
                    DonkLabelRow(
                        icon: "speedometer",
                        tone: .success,
                        title: "Request \(max(model.maximumFPS, 120)) Hz",
                        subtitle: model.maximumFPS > 60 ? "Frame counter display link only, off by default" : "This display is limited to \(model.maximumFPS) Hz"
                    )
                }
                .disabled(model.maximumFPS <= 60)
                .padding(.vertical, DonkSpacing.s)
                Divider()
                NavigationLink {
                    AlertSettingsView()
                } label: {
                    DonkLabelRow(icon: "bell.badge.fill", tone: .warning, title: "Alert settings", subtitle: alertSummary) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(DonkColor.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, DonkSpacing.s)
                Divider()
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    DonkLabelRow(icon: "trash", tone: .error, title: "Reset history", subtitle: "Clear samples and events")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, DonkSpacing.s)
            }
        } accessory: {
            InfoButton(isExpanded: $showsOverhead, label: "About monitoring overhead")
        }
    }

    private var alertSummary: String {
        guard model.alertsEnabled else { return "Alerts are off" }
        let enabled = PerformanceAlertKind.allCases.filter { model.preferences.alerts[$0].isEnabled }.count
        return "\(enabled) of \(PerformanceAlertKind.allCases.count) enabled · \(Int(model.preferences.alerts.cooldown)) s cooldown"
    }
}
