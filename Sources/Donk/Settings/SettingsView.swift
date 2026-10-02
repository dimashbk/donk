import DonkCore
import DonkUI
import SwiftUI

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @State private var isConfirmingReset = false

    var body: some View {
        List {
            launcherSection
            networkSection
            redactionSection
            breakpointSection
            dataSection
            aboutSection
        }
        .donkListStyle()
        .donkNavigationTitle("Settings")
    }

    // MARK: - Launcher

    private var launcherSection: some View {
        Section {
            toggleRow(
                icon: "ladybug.fill",
                tone: .accent,
                title: "Floating bubble",
                subtitle: "Tap to open, long-press for quick actions",
                isOn: Binding(get: { model.showsBubble }, set: { model.setShowsBubble($0) })
            )
            toggleRow(
                icon: "iphone.radiowaves.left.and.right",
                tone: .grpc,
                title: "Shake to open",
                subtitle: "Shake the device to toggle donk",
                isOn: Binding(get: { model.opensOnShake }, set: { model.setOpensOnShake($0) })
            )
        } header: {
            DonkSectionHeader("Launcher", icon: "cursorarrow.rays")
        } footer: {
            if !model.showsBubble && !model.opensOnShake {
                Text("With both off, open donk from code with Donk.show().")
            }
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            toggleRow(
                icon: "antenna.radiowaves.left.and.right",
                tone: .web,
                title: "Capture requests",
                subtitle: model.captureEnabled ? "Recording network traffic" : "Paused, nothing is recorded",
                isOn: Binding(get: { model.captureEnabled }, set: { model.setCaptureEnabled($0) })
            )
            SettingsMenuRow(
                icon: "doc.text",
                tone: .info,
                title: "Max body size",
                options: SettingsOptions.bodySizes,
                selection: model.network.maxBodySize,
                fallback: { DonkFormat.bytes($0) },
                onSelect: model.setMaxBodySize
            )
            SettingsMenuRow(
                icon: "list.bullet",
                tone: .accent,
                title: "Log limit",
                options: SettingsOptions.limits,
                selection: model.network.limit,
                fallback: { DonkFormat.number($0) },
                onSelect: model.setLimit
            )
            hostLink(.bypass)
            hostLink(.hidden)
        } header: {
            DonkSectionHeader("Network", icon: "network")
        } footer: {
            Text("Bodies larger than the limit are truncated. The oldest unpinned requests are dropped when the log is full.")
        }
    }

    private func hostLink(_ kind: HostListKind) -> some View {
        NavigationLink {
            HostListEditor(kind: kind, model: model)
        } label: {
            DonkLabelRow(
                icon: kind.icon,
                tone: kind.tone,
                title: kind.title,
                subtitle: linkSubtitle(kind),
                value: countLabel(model.items(kind).count)
            )
        }
    }

    private func linkSubtitle(_ kind: HostListKind) -> String {
        switch kind {
        case .bypass: return "Never intercepted"
        case .hidden: return "Captured, but not listed"
        case .redactedHeaders: return "Headers and gRPC metadata"
        case .redactedKeys: return "JSON, query and form fields"
        }
    }

    // MARK: - Redaction

    private var redactionSection: some View {
        Section {
            toggleRow(
                icon: "lock.shield",
                tone: .success,
                title: "Redact secrets",
                subtitle: model.redactsExports ? "Exports and header lists hide secrets" : "Exports contain raw values",
                isOn: Binding(get: { model.redactsExports }, set: { model.setRedactsExports($0) })
            )
            hostLink(.redactedHeaders)
            hostLink(.redactedKeys)
            if !model.usesDefaultRedaction {
                Button {
                    model.restoreDefaultRedaction()
                } label: {
                    DonkLabelRow(icon: "arrow.counterclockwise", tone: .neutral, title: "Restore default lists")
                }
                .buttonStyle(.plain)
            }
        } header: {
            DonkSectionHeader("Redaction", icon: "lock.shield")
        } footer: {
            Text(model.redactsExports
                ? "cURL, grpcurl, text and HAR exports replace matching values with \(RedactionPolicy.defaultReplacement). Matching headers are masked in request details; tap one to reveal it."
                : "Exports and header lists show captured values as they are.")
        }
    }

    private func countLabel(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }

    // MARK: - Breakpoints

    private var breakpointSection: some View {
        Section {
            SettingsMenuRow(
                icon: "timer",
                tone: .warning,
                title: "Auto-resume after",
                options: SettingsOptions.timeouts,
                selection: model.breakpointTimeout,
                fallback: { DonkFormat.duration($0) },
                onSelect: model.setBreakpointTimeout
            )
        } header: {
            DonkSectionHeader("Breakpoints", icon: "pause.circle")
        } footer: {
            Text(model.breakpointTimeout > 0
                ? "Paused requests continue unmodified if you don't act on them in time."
                : "Paused requests wait until you resume or abort them.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button {
                isConfirmingReset = true
            } label: {
                DonkLabelRow(
                    icon: "arrow.counterclockwise",
                    tone: .error,
                    title: "Reset donk data",
                    subtitle: "Network log, rules and settings"
                )
            }
            .buttonStyle(.plain)
            .confirmationDialog("Reset donk data?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Reset Everything", role: .destructive) {
                    model.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the network log (including pinned requests), all rules and every donk setting. This can't be undone.")
            }
        } header: {
            DonkSectionHeader("Data", icon: "externaldrive")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            DonkLabelRow(icon: "ladybug", tone: .accent, title: "donk", subtitle: "In-app debugger for iOS", value: Donk.version)
            DonkLabelRow(
                icon: "network",
                tone: .info,
                title: "Network capture",
                value: model.isCaptureRunning ? "Running" : "Stopped"
            )
            DonkLabelRow(
                icon: "exclamationmark.octagon",
                tone: .error,
                title: "Crash reporter",
                value: model.isCrashReporterInstalled ? "Installed" : "Not installed"
            )
            VStack(alignment: .leading, spacing: 6) {
                DonkLabelRow(icon: "folder", tone: .web, title: "Data folder")
                Text(DonkTextBreaking.breakable(model.dataDirectory))
                    .font(DonkFont.codeCaption)
                    .foregroundColor(DonkColor.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 42)
            }
            .contextMenu {
                Button {
                    DonkPasteboard.copy(model.dataDirectory, label: "Path")
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }
        } header: {
            DonkSectionHeader("About", icon: "info.circle")
        }
    }

    // MARK: - Rows

    private func toggleRow(icon: String, tone: DonkTone, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        DonkLabelRow(icon: icon, tone: tone, title: title, subtitle: subtitle) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
    }
}

// MARK: - Menu row

struct SettingsMenuRow<Value: Hashable>: View {
    let icon: String
    let tone: DonkTone
    let title: String
    let options: [SettingsOption<Value>]
    let selection: Value
    let fallback: (Value) -> String
    let onSelect: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option.value)
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            DonkLabelRow(icon: icon, tone: tone, title: title) {
                HStack(spacing: 4) {
                    Text(SettingsOptions.title(for: selection, in: options, fallback: fallback))
                        .foregroundColor(DonkColor.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(DonkColor.textTertiary)
                }
            }
        }
        .accessibilityValue(SettingsOptions.title(for: selection, in: options, fallback: fallback))
    }
}
