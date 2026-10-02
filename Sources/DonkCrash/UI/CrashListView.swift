import Combine
import DonkUI
import SwiftUI

@MainActor
final class CrashListModel: ObservableObject {
    @Published private(set) var reports: [CrashReport]
    @Published private(set) var sections: [CrashDaySection]
    @Published var detectsUncleanExits: Bool {
        didSet {
            guard detectsUncleanExits != oldValue else { return }
            engine.detectsUncleanExits = detectsUncleanExits
        }
    }

    let engine: CrashEngine
    private var cancellable: AnyCancellable?

    init(engine: CrashEngine) {
        self.engine = engine
        let reports = engine.store.all()
        self.reports = reports
        sections = CrashDaySection.group(reports)
        detectsUncleanExits = engine.detectsUncleanExits
        cancellable = engine.store.changes
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] reports in
                self?.apply(reports)
            }
    }

    var isInstalled: Bool { engine.isInstalled }

    var installedAfterAnotherReporter: Bool { engine.installedAfterAnotherReporter }

    func delete(_ report: CrashReport) {
        engine.store.delete([report.id])
        DonkHaptics.light()
    }

    func deleteAll() {
        engine.store.deleteAll()
        DonkHaptics.success()
        DonkToast.show("Crash reports deleted", icon: "trash", tone: .neutral)
    }

    private func apply(_ reports: [CrashReport]) {
        self.reports = reports
        sections = CrashDaySection.group(reports)
    }
}

struct CrashListView: View {
    @StateObject private var model: CrashListModel
    @State private var isConfirmingClear = false

    init(engine: CrashEngine) {
        _model = StateObject(wrappedValue: CrashListModel(engine: engine))
    }

    var body: some View {
        content
            .donkNavigationTitle("Crashes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    menu
                }
            }
            .confirmationDialog("Delete all crash reports?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    model.deleteAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: "This removes \(model.reports.count) saved report\(model.reports.count == 1 ? "" : "s") from this device.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.reports.isEmpty {
            VStack(spacing: DonkSpacing.l) {
                if model.installedAfterAnotherReporter {
                    DonkCard(padding: DonkSpacing.m) {
                        InstallOrderBanner()
                    }
                    .padding(.horizontal, DonkSpacing.screen)
                    .padding(.top, DonkSpacing.m)
                }
                emptyState
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .donkScreenBackground()
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !model.isInstalled {
                Section {
                    NotInstalledBanner()
                }
            }
            if model.installedAfterAnotherReporter {
                Section {
                    InstallOrderBanner()
                }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.reports) { report in
                        NavigationLink {
                            CrashDetailView(report: report) {
                                model.delete(report)
                            }
                        } label: {
                            CrashRowView(report: report)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.delete(report)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            CrashReportMenuItems(report: report) {
                                model.delete(report)
                            }
                        }
                    }
                } header: {
                    DonkSectionHeader(CrashDayFormatter.title(for: section.day), count: section.reports.count)
                }
            }
        }
        .donkListStyle()
    }

    private var emptyState: some View {
        Group {
            if model.isInstalled {
                EmptyStateView(
                    icon: "checkmark.shield",
                    title: "No crashes",
                    message: "Reports appear here on the next launch after a crash. Call DonkCrash.install() before FirebaseApp.configure() so Crashlytics chains to Donk. Crashes under the Xcode debugger are caught by LLDB first, so relaunch the app without the debugger to record them.",
                    tone: .success
                )
            } else {
                EmptyStateView(
                    icon: "exclamationmark.shield",
                    title: "Crash reporter not installed",
                    message: "Call DonkCrash.install() (or Donk.installCrashReporter()) in application(_:willFinishLaunchingWithOptions:), before FirebaseApp.configure(). Crashes under the Xcode debugger are caught by LLDB first.",
                    tone: .warning
                )
            }
        }
    }

    private var menu: some View {
        Menu {
            Toggle(isOn: $model.detectsUncleanExits) {
                Label("Detect Unclean Exits", systemImage: "power")
            }
            Divider()
            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(model.reports.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More")
        }
    }
}

// MARK: - Row

struct CrashRowView: View {
    let report: CrashReport

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge(report.icon, tone: report.kind.tone, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
                    Text(report.title)
                        .font(DonkFont.rowTitle)
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DonkSpacing.xs)
                    Text(DonkFormat.relative(report.date))
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let subtitle = report.subtitle {
                    Text(subtitle.replacingOccurrences(of: "\n", with: " "))
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: DonkSpacing.xs) {
                    TonePill(report.kind.label, tone: report.kind.tone)
                    TonePill(report.versionLabel.isEmpty ? "—" : "v\(report.versionLabel)", tone: .neutral)
                    if let symbol = report.topAppFrame?.symbol.map(CrashSymbolFormatter.short), symbol != report.subtitle {
                        Text(symbol)
                            .font(DonkFont.codeCaption2)
                            .foregroundColor(DonkColor.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, DonkSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared menu

struct CrashReportMenuItems: View {
    let report: CrashReport
    var onDelete: (() -> Void)?

    var body: some View {
        Button {
            CrashShareActions.shareText(report)
        } label: {
            Label("Share .crash Report", systemImage: "square.and.arrow.up")
        }
        Button {
            CrashShareActions.shareJSON(report)
        } label: {
            Label("Share JSON", systemImage: "curlybraces")
        }
        Button {
            DonkPasteboard.copy(CrashTextFormatter.text(for: report), label: "Report")
        } label: {
            Label("Copy Report", systemImage: "doc.on.doc")
        }
        Button {
            DonkPasteboard.copy(report.title, label: "Title")
        } label: {
            Label("Copy Title", systemImage: "textformat")
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

@MainActor
enum CrashShareActions {
    static func shareText(_ report: CrashReport) {
        let text = CrashTextFormatter.text(for: report)
        DonkShare.share(fileNamed: CrashExport.fileBaseName(for: report) + ".crash", data: Data(text.utf8))
    }

    static func shareJSON(_ report: CrashReport) {
        guard let data = CrashExport.json(for: report) else {
            DonkToast.show("Could not encode the report", tone: .error)
            return
        }
        DonkShare.share(fileNamed: CrashExport.fileBaseName(for: report) + ".json", data: data)
    }
}

struct NotInstalledBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge("exclamationmark.shield", tone: .warning, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Crash reporter not installed")
                    .font(DonkFont.rowTitle)
                Text("New crashes are not recorded. Call DonkCrash.install() before FirebaseApp.configure().")
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DonkSpacing.xs)
    }
}

struct InstallOrderBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            DonkIconBadge("exclamationmark.triangle.fill", tone: .warning, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Installed after another crash reporter")
                    .font(DonkFont.rowTitle)
                    .foregroundColor(DonkColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CrashEngine.installOrderWarning)
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DonkSpacing.xs)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                DonkPasteboard.copy(CrashEngine.installOrderWarning, label: "Warning")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
