import Donk
import DonkUI
import SwiftUI

struct CrashDemoView: View {
    @State private var showsReports = false
    @State private var pendingCrash: DemoCrashKind?
    @State private var reportCount = DonkCrash.reportCount()
    @State private var detectsUncleanExits = DonkCrash.detectsUncleanExits

    init() {
        CrashDemoLaunch.handleArguments()
    }

    var body: some View {
        List {
            Section {
                statusRow
                Button {
                    showsReports = true
                } label: {
                    Label("Open crash reports", systemImage: "list.bullet.rectangle.portrait")
                }
                Toggle(isOn: $detectsUncleanExits) {
                    Label("Detect unclean exits", systemImage: "power")
                }
                .onChange(of: detectsUncleanExits) { DonkCrash.detectsUncleanExits = $0 }
            }

            Section {
                ForEach(DemoCrashKind.allCases) { kind in
                    Button {
                        pendingCrash = kind
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.icon)
                                .foregroundColor(DonkColor.error)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .foregroundColor(DonkColor.textPrimary)
                                Text(kind.expectation)
                                    .font(.caption)
                                    .foregroundColor(DonkColor.textSecondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Crash the app")
            } footer: {
                Text("The app terminates immediately. Relaunch it from the Home Screen (not under the Xcode debugger, which catches the crash first) to see the report.")
            }

            Section {
                launchArgument("-DonkCrashDemo <kind>", "Crashes 1 s after launch. Kinds: " + DemoCrashKind.allCases.map(\.rawValue).joined(separator: ", "))
                launchArgument("-DonkCrashShowList", "Presents the crash list at launch")
                launchArgument("-DonkCrashShowLatest", "Presents the newest report at launch")
                launchArgument("-DonkCrashLaterReporter", "Installs a Crashlytics-style signal handler after Donk (unmasks all signals and calls Donk directly), to check the crash still ends at the original site")
            } header: {
                Text("Launch arguments")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Crashes")
        .confirmationDialog(
            pendingCrash.map { "Crash with \($0.title)?" } ?? "",
            isPresented: Binding(get: { pendingCrash != nil }, set: { if !$0 { pendingCrash = nil } }),
            titleVisibility: .visible
        ) {
            if let kind = pendingCrash {
                Button("Crash Now", role: .destructive) {
                    kind.trigger()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The report is saved on the device and shown on the next launch.")
        }
        .sheet(isPresented: $showsReports) {
            CrashReportsSheet()
        }
        .onReceive(DonkCrash.reportsDidChange.receive(on: DispatchQueue.main)) { reports in
            reportCount = reports.count
        }
        .onAppear {
            reportCount = DonkCrash.reportCount()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            DonkIconBadge(statusIcon, tone: statusTone)
            VStack(alignment: .leading, spacing: 2) {
                Text(DonkCrash.isInstalled ? "Crash reporter installed" : "Crash reporter not installed")
                    .font(DonkFont.rowTitle)
                Text(verbatim: "\(reportCount) saved report\(reportCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                if DonkCrash.installedAfterAnotherReporter {
                    Text("Installed after another crash reporter: hardware crashes are not captured")
                        .font(.caption)
                        .foregroundColor(DonkColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        guard DonkCrash.isInstalled else { return "exclamationmark.shield.fill" }
        return DonkCrash.installedAfterAnotherReporter ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
    }

    private var statusTone: DonkTone {
        DonkCrash.isInstalled && !DonkCrash.installedAfterAnotherReporter ? .success : .warning
    }

    private func launchArgument(_ argument: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(argument)
                .font(DonkFont.code)
            Text(description)
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                DonkPasteboard.copy(argument, label: "Argument")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
