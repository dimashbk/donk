import Combine
import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

@MainActor
final class DefaultsListModel: ObservableObject {
    static let changeInterval: DispatchQueue.SchedulerTimeType.Stride = .seconds(1)

    let domain: DefaultsDomain
    @Published private(set) var entries: [DefaultsEntry] = []
    @Published private(set) var hasLoaded = false
    @Published var query = ""
    private var changeSubscription: AnyCancellable?
    private var reloadTask: Task<Void, Never>?
    private var generation = 0
    private var appearedInDebugger = false

    init(domain: DefaultsDomain) {
        self.domain = domain
    }

    var isObservingChanges: Bool {
        changeSubscription != nil
    }

    var filteredEntries: [DefaultsEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.key.localizedCaseInsensitiveContains(trimmed) || $0.preview.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var keys: Set<String> {
        Set(entries.map(\.key))
    }

    func becameVisible() {
        appearedInDebugger = DonkEnvironment.isDebuggerVisible
        reload()
        guard changeSubscription == nil else { return }
        changeSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in () }
            .merge(with: DonkEnvironment.debuggerVisibility.dropFirst().filter { $0 }.map { _ in () })
            .throttle(for: Self.changeInterval, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isOnScreen else { return }
                    self.reload()
                }
            }
    }

    private var isOnScreen: Bool {
        !appearedInDebugger || DonkEnvironment.isDebuggerVisible
    }

    func becameHidden() {
        changeSubscription = nil
        reloadTask?.cancel()
        reloadTask = nil
    }

    func reload() {
        generation += 1
        let token = generation
        let domain = self.domain
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                DefaultsStore.entries(in: domain)
            }.value
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.entries = entries
            self.hasLoaded = true
        }
    }

    func reloadNow() async {
        reload()
        await reloadTask?.value
    }

    func delete(_ entry: DefaultsEntry) {
        DefaultsStore.remove(entry.key, in: domain)
        entries.removeAll { $0.key == entry.key }
        reload()
        DonkHaptics.success()
        DonkToast.show("Removed “\(entry.key)”", icon: "trash.fill", tone: .success)
    }

    func reset() {
        DefaultsStore.reset(domain)
        entries = []
        reload()
        DonkHaptics.success()
        DonkToast.show("Domain reset", tone: .success)
    }

    func export() {
        do {
            let data = try DefaultsStore.exportPlist(domain)
            let name = (domain.name.isEmpty ? "defaults" : domain.name) + ".plist"
            DonkShare.share(fileNamed: name, data: data)
        } catch {
            DonkHaptics.error()
            DonkToast.show("Couldn't export: \(error.localizedDescription)", tone: .error)
        }
    }
}

// MARK: - List

struct DefaultsListView: View {
    @StateObject private var model: DefaultsListModel
    @State private var isAdding = false
    @State private var isConfirmingReset = false

    init(domain: DefaultsDomain) {
        self._model = StateObject(wrappedValue: DefaultsListModel(domain: domain))
    }

    var body: some View {
        List {
            Section {
                header
            }
            if model.domain.name.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "folder.badge.questionmark",
                        title: "No bundle identifier",
                        message: "The standard domain needs Bundle.main.bundleIdentifier.",
                        tone: .warning
                    )
                    .frame(minHeight: 260)
                    .listRowBackground(Color.clear)
                }
            } else if model.filteredEntries.isEmpty {
                Section {
                    emptyState
                        .frame(minHeight: 280)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(model.filteredEntries) { entry in
                        NavigationLink {
                            DefaultsEditorView(domain: model.domain, key: entry.key)
                        } label: {
                            DefaultsRow(entry: entry)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { model.delete(entry) } label: { Label("Delete", systemImage: "trash") }
                                .tint(DonkColor.error)
                        }
                        .contextMenu {
                            Button { DonkPasteboard.copy(entry.key, label: "Key") } label: {
                                Label("Copy Key", systemImage: "key.fill")
                            }
                            Button { DonkPasteboard.copy(DefaultsValues.copyText(entry.value, type: entry.type), label: "Value") } label: {
                                Label("Copy Value", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) { model.delete(entry) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    DonkSectionHeader("Keys", count: model.filteredEntries.count)
                }
            }
        }
        .donkListStyle()
        .donkNavigationTitle(model.domain.title)
        .searchable(text: $model.query, prompt: "Search keys and values")
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .refreshable { await model.reloadNow() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { isAdding = true } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("Add Key")
                }
                .disabled(model.domain.name.isEmpty)
                Menu {
                    Button { model.export() } label: { Label("Export as Plist", systemImage: "square.and.arrow.up") }
                    Button { DonkPasteboard.copy(model.domain.name, label: "Domain") } label: {
                        Label("Copy Domain Name", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) { isConfirmingReset = true } label: {
                        Label("Reset Domain", systemImage: "trash")
                    }
                    .disabled(model.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Options")
                }
                .disabled(model.domain.name.isEmpty)
            }
        }
        .confirmationDialog(
            "Reset “\(model.domain.title)”?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Remove All \(model.entries.count) Keys", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every key in this domain is removed. This can't be undone.")
        }
        .sheet(isPresented: $isAdding) {
            DefaultsAddKeyView(domain: model.domain, existingKeys: model.keys) {
                model.reload()
            }
        }
        .onAppear { model.becameVisible() }
        .onDisappear { model.becameHidden() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            Text(DonkTextBreaking.breakable(model.domain.name.isEmpty ? "—" : model.domain.name))
                .font(DonkFont.codeCaption)
                .foregroundColor(DonkColor.textSecondary)
                .textSelection(.enabled)
            HStack(spacing: DonkSpacing.s) {
                TonePill(
                    text: model.entries.count == 1 ? "1 key" : "\(model.entries.count) keys",
                    tone: .neutral,
                    icon: "key.fill"
                )
                TonePill(text: model.domain.kind == .standard ? "App domain" : "Suite", tone: .accent)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "No keys",
                message: "Values the app writes to this domain appear here.",
                tone: .neutral,
                actionTitle: "Add Key"
            ) { isAdding = true }
        } else {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No matches",
                message: "No key or value matches “\(model.query)”.",
                tone: .neutral
            )
        }
    }
}

struct DefaultsRow: View {
    let entry: DefaultsEntry

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.key)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.preview)
                    .font(DonkFont.codeCaption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DonkSpacing.s)
            DefaultsTypeBadge(type: entry.type)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension DefaultsValues {
    static func copyText(_ value: Any, type: DefaultsValueType?) -> String {
        switch type {
        case .string:
            return value as? String ?? ""
        case .date:
            return (value as? Date).map(StorageFormat.iso8601) ?? "\(value)"
        case .data:
            return (value as? Data)?.base64EncodedString() ?? ""
        case .array, .dictionary:
            if let json = jsonText(for: value) { return json }
            return (try? PlistDocument.xmlText(for: value)) ?? "\(value)"
        default:
            return preview(value, type: type)
        }
    }
}
