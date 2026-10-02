import DonkUI
import SwiftUI

// MARK: - Rule metadata

struct AlertValueSpec {
    var label: String
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
}

extension PerformanceAlertKind {
    var tone: DonkTone {
        switch self {
        case .cpu, .lowFPS: return .success
        case .memoryLimit, .memoryGrowth, .memoryWarning: return .info
        case .hitches, .thermal: return .warning
        case .hang: return .error
        }
    }

    var explanation: String {
        switch self {
        case .cpu: return "Total CPU above the threshold (% of one core) for the whole window while the app is in the foreground."
        case .memoryLimit: return "Footprint above this share of the estimated Jetsam limit. Needs a real device; the Simulator reports no limit."
        case .memoryGrowth: return "Footprint grows by more than the threshold within the window without dropping in between."
        case .lowFPS: return "Frame rate below the threshold for the whole window while the app is in the foreground."
        case .hitches: return "Hitch time ratio above the threshold for the whole window. Apple: under 5 ms/s good, 5–10 warning, 10+ critical."
        case .hang: return "The main thread did not respond for at least this long. Reported once, when the hang ends."
        case .thermal: return "The device reached the selected thermal state."
        case .memoryWarning: return "The system sent UIApplication.didReceiveMemoryWarningNotification."
        }
    }

    var thresholdSpec: AlertValueSpec? {
        switch self {
        case .cpu: return AlertValueSpec(label: "Threshold", range: 10...800, step: 10) { "\(Int($0))%" }
        case .memoryLimit: return AlertValueSpec(label: "Share of limit", range: 50...99, step: 1) { "\(Int($0))%" }
        case .memoryGrowth: return AlertValueSpec(label: "Growth", range: 10...2000, step: 10) { "\(Int($0)) MB" }
        case .lowFPS: return AlertValueSpec(label: "Below", range: 10...118, step: 1) { "\(Int($0)) fps" }
        case .hitches: return AlertValueSpec(label: "Above", range: 1...200, step: 1) { "\(Int($0)) ms/s" }
        case .hang: return AlertValueSpec(label: "At least", range: 250...10_000, step: 250) { PerformanceText.duration($0 / 1000) }
        case .thermal, .memoryWarning: return nil
        }
    }

    var durationSpec: AlertValueSpec? {
        switch self {
        case .cpu, .lowFPS, .hitches:
            return AlertValueSpec(label: "Sustained for", range: 1...120, step: 1) { "\(Int($0)) s" }
        case .memoryGrowth:
            return AlertValueSpec(label: "Within", range: 30...900, step: 30) { PerformanceText.duration($0) }
        case .memoryLimit, .hang, .thermal, .memoryWarning:
            return nil
        }
    }

    func summary(_ rule: PerformanceAlertRule) -> String {
        guard rule.isEnabled else { return "Off" }
        switch self {
        case .cpu: return "> \(Int(rule.threshold))% for \(Int(rule.duration)) s"
        case .memoryLimit: return "> \(Int(rule.threshold))% of limit"
        case .memoryGrowth: return "+\(Int(rule.threshold)) MB within \(PerformanceText.duration(rule.duration))"
        case .lowFPS: return "< \(Int(rule.threshold)) fps for \(Int(rule.duration)) s"
        case .hitches: return "> \(Int(rule.threshold)) ms/s for \(Int(rule.duration)) s"
        case .hang: return "≥ \(PerformanceText.duration(rule.threshold / 1000))"
        case .thermal: return Int(rule.threshold.rounded()) >= ProcessInfo.ThermalState.critical.rawValue ? "Critical" : "Serious or critical"
        case .memoryWarning: return "Every warning"
        }
    }
}

// MARK: - Screen

struct AlertSettingsView: View {
    @State private var settings = PerformanceMonitor.shared.preferences.value.alerts
    @State private var alertsEnabled = PerformanceMonitor.shared.alertsEnabled

    var body: some View {
        List {
            Section {
                Toggle(isOn: $alertsEnabled) {
                    DonkLabelRow(icon: "bell.fill", tone: .accent, title: "Show alerts", subtitle: "Toasts when abnormal activity is detected")
                }
            } footer: {
                Text("Starts from PerformanceConfiguration.alertsEnabled each time monitoring starts. Hangs and memory warnings are always logged in Events.")
            }
            ForEach(PerformanceAlertKind.allCases) { kind in
                Section {
                    AlertRuleEditor(kind: kind, rule: binding(for: kind))
                } footer: {
                    Text(kind.explanation)
                }
                .disabled(!alertsEnabled)
            }
            Section {
                Stepper(value: $settings.cooldown, in: 5...600, step: 5) {
                    valueRow("Cooldown per type", value: "\(Int(settings.cooldown)) s")
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text("After an alert fires, the same type stays quiet for this long.")
            }
            .disabled(!alertsEnabled)
            Section {
                Button("Restore Defaults") {
                    settings = .default
                    DonkHaptics.success()
                }
                .disabled(settings == .default)
            }
        }
        .donkListStyle()
        .donkNavigationTitle("Alerts")
        .tracksDonkScreen()
        .onChange(of: settings) { value in
            PerformanceMonitor.shared.updateAlertSettings(value)
        }
        .onChange(of: alertsEnabled) { value in
            PerformanceMonitor.shared.alertsEnabled = value
            DonkHaptics.light()
        }
    }

    private func binding(for kind: PerformanceAlertKind) -> Binding<PerformanceAlertRule> {
        Binding(
            get: { settings[kind] },
            set: { settings[kind] = $0 }
        )
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(DonkFont.number)
                .foregroundColor(DonkColor.textSecondary)
        }
    }
}

private struct AlertRuleEditor: View {
    let kind: PerformanceAlertKind
    @Binding var rule: PerformanceAlertRule

    var body: some View {
        Toggle(isOn: $rule.isEnabled) {
            DonkLabelRow(icon: kind.icon, tone: rule.isEnabled ? kind.tone : .neutral, title: kind.title, subtitle: kind.summary(rule))
        }
        .onChange(of: rule.isEnabled) { _ in DonkHaptics.light() }
        if rule.isEnabled {
            if let spec = kind.thresholdSpec {
                Stepper(value: $rule.threshold, in: spec.range, step: spec.step) {
                    row(spec.label, value: spec.format(rule.threshold))
                }
            }
            if let spec = kind.durationSpec {
                Stepper(value: $rule.duration, in: spec.range, step: spec.step) {
                    row(spec.label, value: spec.format(rule.duration))
                }
            }
            if kind == .thermal {
                Picker("Minimum state", selection: thermalSelection) {
                    Text("Serious").tag(ProcessInfo.ThermalState.serious.rawValue)
                    Text("Critical").tag(ProcessInfo.ThermalState.critical.rawValue)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var thermalSelection: Binding<Int> {
        Binding(
            get: { Int(rule.threshold.rounded()) >= ProcessInfo.ThermalState.critical.rawValue ? ProcessInfo.ThermalState.critical.rawValue : ProcessInfo.ThermalState.serious.rawValue },
            set: { rule.threshold = Double($0) }
        )
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(DonkColor.textPrimary)
            Spacer()
            Text(value)
                .font(DonkFont.number.weight(.semibold))
                .foregroundColor(DonkColor.textSecondary)
        }
    }
}
