import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

enum KeychainValueState: Equatable {
    case idle
    case loading
    case authenticating
    case loaded(Data)
    case missing
    case protected
    case failed(String)

    var data: Data? {
        if case let .loaded(data) = self { return data }
        return nil
    }

    var isBusy: Bool {
        self == .loading || self == .authenticating
    }
}

@MainActor
final class KeychainModel: ObservableObject {
    @Published private(set) var items: [KeychainItem] = []
    @Published private(set) var state: StorageLoadState = .idle
    @Published private(set) var error: KeychainError?
    @Published private(set) var values: [String: KeychainValueState] = [:]
    @Published var query = ""

    var sections: [(KeychainItemClass, [KeychainItem])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = trimmed.isEmpty ? items : items.filter { item in
            [item.service, item.account, item.server, item.label, item.accessGroup]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
        return KeychainItemClass.allCases.compactMap { itemClass in
            let matching = visible.filter { $0.itemClass == itemClass }
            return matching.isEmpty ? nil : (itemClass, matching)
        }
    }

    func item(_ id: String) -> KeychainItem? {
        items.first { $0.id == id }
    }

    func valueState(_ id: String) -> KeychainValueState {
        values[id] ?? .idle
    }

    func load() async {
        if items.isEmpty {
            state = .loading
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[KeychainItem], KeychainError> in
            do {
                return .success(try KeychainStore.items())
            } catch let error as KeychainError {
                return .failure(error)
            } catch {
                return .failure(.status(errSecInternalError))
            }
        }.value
        values = [:]
        switch result {
        case let .success(items):
            self.items = items
            error = nil
            state = .loaded
        case let .failure(error):
            self.items = []
            self.error = error
            state = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func loadValue(for item: KeychainItem, authenticate: Bool = false) async -> KeychainValueState {
        guard !valueState(item.id).isBusy else { return valueState(item.id) }
        values[item.id] = authenticate ? .authenticating : .loading
        let authentication: KeychainAuthentication = authenticate ? .prompt(reason: "Reveal “\(item.title)” in donk") : .never
        let result = await Task.detached(priority: .userInitiated) { () -> Result<KeychainValueLookup, KeychainError> in
            do {
                return .success(try KeychainStore.value(for: item, authentication: authentication))
            } catch let error as KeychainError {
                return .failure(error)
            } catch {
                return .failure(.status(errSecInternalError))
            }
        }.value
        let newState: KeychainValueState
        switch result {
        case let .success(.value(data)):
            newState = .loaded(data)
        case .success(.missing):
            newState = .missing
        case .success(.requiresAuthentication):
            newState = .protected
        case .failure(.userCanceled), .failure(.authenticationFailed):
            newState = .protected
            if case let .failure(error) = result {
                DonkToast.show(error.localizedDescription, tone: .warning)
            }
        case let .failure(error):
            newState = .failed(error.localizedDescription)
        }
        if items.contains(where: { $0.id == item.id }) {
            values[item.id] = newState
        }
        return newState
    }

    func copyValue(_ item: KeychainItem) async {
        let state = valueState(item.id).data == nil ? await loadValue(for: item) : valueState(item.id)
        switch state {
        case let .loaded(data):
            DonkPasteboard.copy(KeychainStore.text(from: data) ?? HexDump.hex(data, grouped: false), label: "Value")
        case .protected:
            DonkHaptics.warning()
            DonkToast.show("Protected by biometrics or passcode. Open the item to authenticate.", icon: "lock.fill", tone: .warning, duration: 3)
        case .missing:
            DonkToast.show("The item has no value", tone: .warning)
        case let .failed(message):
            DonkToast.show("Couldn't read the value: \(message)", tone: .error, duration: 3)
        case .idle, .loading, .authenticating:
            break
        }
    }

    @discardableResult
    func delete(_ item: KeychainItem) async -> Bool {
        let result = await Task.detached(priority: .userInitiated) { () -> Error? in
            do {
                try KeychainStore.delete(item)
                return nil
            } catch {
                return error
            }
        }.value
        if let result {
            DonkHaptics.error()
            DonkToast.show("Couldn't delete: \(result.localizedDescription)", tone: .error, duration: 3)
            return false
        }
        items.removeAll { $0.id == item.id }
        values[item.id] = nil
        DonkHaptics.success()
        DonkToast.show("Keychain item deleted", icon: "trash.fill", tone: .success)
        return true
    }

    @discardableResult
    func update(_ item: KeychainItem, value: Data) async -> Bool {
        let result = await Task.detached(priority: .userInitiated) { () -> Error? in
            do {
                try KeychainStore.updateValue(value, for: item)
                return nil
            } catch {
                return error
            }
        }.value
        if let result {
            DonkHaptics.error()
            DonkToast.show("Couldn't update: \(result.localizedDescription)", tone: .error, duration: 3)
            return false
        }
        await load()
        values[item.id] = .loaded(value)
        DonkHaptics.success()
        DonkToast.show("Value updated", tone: .success)
        return true
    }
}

// MARK: - List

struct KeychainListView: View {
    @StateObject private var model = KeychainModel()
    @State private var pendingDelete: KeychainItem?

    var body: some View {
        content
            .donkNavigationTitle("Keychain")
            .searchable(text: $model.query, prompt: "Search service, account, server")
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .confirmationDialog(
                "Delete keychain item?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                Button("Delete “\(item.title)”", role: .destructive) {
                    Task { await model.delete(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The app loses this credential. This can't be undone.")
            }
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .donkScreenBackground()
        case let .failed(message):
            ScrollView {
                EmptyStateView(
                    icon: model.error == .missingEntitlement ? "lock.slash" : "exclamationmark.triangle.fill",
                    title: "Keychain unavailable",
                    message: message,
                    tone: .warning,
                    actionTitle: "Try Again"
                ) { Task { await model.load() } }
                .frame(minHeight: 420)
            }
            .donkScreenBackground()
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            let sections = model.sections
            if sections.isEmpty {
                Section {
                    EmptyStateView(
                        icon: model.query.isEmpty ? "key.fill" : "magnifyingglass",
                        title: model.query.isEmpty ? "No keychain items" : "No matches",
                        message: model.query.isEmpty
                            ? "Generic and internet passwords the app stores with SecItemAdd appear here."
                            : "Nothing matches “\(model.query)”.",
                        tone: .warning
                    )
                    .frame(minHeight: 320)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(sections, id: \.0) { itemClass, items in
                    Section {
                        ForEach(items) { item in
                            NavigationLink {
                                KeychainDetailView(model: model, itemID: item.id)
                            } label: {
                                KeychainRow(item: item, valueSize: model.valueState(item.id).data?.count)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                                    .tint(DonkColor.error)
                            }
                            .contextMenu {
                                Button { Task { await model.copyValue(item) } } label: {
                                    Label("Copy Value", systemImage: "doc.on.doc")
                                }
                                if let account = item.account {
                                    Button { DonkPasteboard.copy(account, label: "Account") } label: {
                                        Label("Copy Account", systemImage: "person.crop.circle.badge.checkmark")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) { pendingDelete = item } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        DonkSectionHeader(
                            itemClass.title,
                            icon: itemClass == .genericPassword ? "key.fill" : "globe",
                            count: items.count
                        )
                    }
                }
            }
        }
        .donkListStyle()
        .refreshable { await model.load() }
    }
}

struct KeychainRow: View {
    let item: KeychainItem
    var valueSize: Int?

    var body: some View {
        HStack(spacing: DonkSpacing.m) {
            DonkIconBadge(
                item.itemClass == .genericPassword ? "key.fill" : "globe",
                tone: item.itemClass == .genericPassword ? .warning : .web,
                size: 32
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle ?? item.accessibilityDescription ?? item.itemClass.shortTitle)
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DonkSpacing.s)
            if item.isSynchronizable {
                Image(systemName: "icloud.fill")
                    .font(.caption)
                    .foregroundColor(DonkColor.info)
                    .accessibilityLabel("Synchronizable")
            }
            if let size = valueSize {
                Text(DonkFormat.bytes(size))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct KeychainDetailView: View {
    @ObservedObject var model: KeychainModel
    let itemID: String

    @State private var isRevealed = false
    @State private var editorValue: KeychainEditorTarget?
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item = model.item(itemID) {
                content(item)
            } else {
                EmptyStateView(icon: "key.fill", title: "Item not found", message: "It may have been deleted.", tone: .neutral)
                    .donkScreenBackground()
            }
        }
        .donkNavigationTitle(model.item(itemID)?.title ?? "Keychain item")
    }

    private func content(_ item: KeychainItem) -> some View {
        DonkScrollContainer {
            valueCard(item)
            DonkCard(title: item.itemClass.shortTitle, icon: item.itemClass == .genericPassword ? "key.fill" : "globe", tone: .warning) {
                VStack(spacing: 0) {
                    ForEach(Array(attributes(item).enumerated()), id: \.offset) { index, pair in
                        if index > 0 {
                            Divider()
                        }
                        KeyValueRow(key: pair.key, value: pair.value, monospacedValue: pair.monospaced)
                    }
                }
            }
            HStack(spacing: DonkSpacing.m) {
                if item.isEditable {
                    Button {
                        Task { await beginEditing(item) }
                    } label: {
                        Label("Edit Value", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DonkColor.accent)
                    .disabled(model.valueState(item.id).isBusy)
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(DonkColor.error)
            }
        }
        .confirmationDialog("Delete keychain item?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete(item) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app loses this credential. This can't be undone.")
        }
        .sheet(item: $editorValue) { target in
            KeychainValueEditor(title: item.title, original: target.data) { data in
                await model.update(item, value: data)
            }
        }
    }

    private func beginEditing(_ item: KeychainItem) async {
        var state = model.valueState(item.id)
        if state.data == nil {
            state = await model.loadValue(for: item)
        }
        switch state {
        case let .loaded(data):
            editorValue = KeychainEditorTarget(data: data)
        case .missing:
            editorValue = KeychainEditorTarget(data: Data())
        case .protected:
            withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true }
            DonkHaptics.warning()
            DonkToast.show("Authenticate to read the value before editing", icon: "lock.fill", tone: .warning)
        case .idle, .loading, .authenticating, .failed:
            break
        }
    }

    private func reveal(_ item: KeychainItem) {
        DonkHaptics.light()
        withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true }
        guard model.valueState(item.id).data == nil else { return }
        Task { await model.loadValue(for: item) }
    }

    @ViewBuilder
    private func valueCard(_ item: KeychainItem) -> some View {
        let state = model.valueState(item.id)
        DonkCard(title: "Value", icon: isRevealed && state.data != nil ? "eye.fill" : "eye.slash", tone: .accent) {
            if !isRevealed {
                maskedButton { reveal(item) }
            } else {
                switch state {
                case .idle, .loading:
                    progressRow("Reading the value…")
                case .authenticating:
                    progressRow("Waiting for authentication…")
                case let .loaded(value):
                    revealedValue(value)
                case .missing:
                    Text("The keychain returned no data for this item.")
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                case .protected:
                    protectedButton { Task { await model.loadValue(for: item, authenticate: true) } }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: DonkSpacing.s) {
                        StorageValidationLabel(isValid: false, validText: "", message: message)
                        Button("Try Again") { Task { await model.loadValue(for: item) } }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        } accessory: {
            if isRevealed, let value = state.data {
                CopyButton(label: "Value") { KeychainStore.text(from: value) ?? HexDump.hex(value, grouped: false) }
            }
        }
    }

    private func revealedValue(_ value: Data) -> some View {
        let text = KeychainStore.text(from: value)
        return VStack(alignment: .leading, spacing: DonkSpacing.s) {
            HStack(spacing: 6) {
                TonePill(text: text == nil ? "Binary · hex" : "UTF-8 text", tone: .neutral)
                TonePill(text: DonkFormat.bytes(value.count), tone: .neutral)
            }
            if value.isEmpty {
                Text("Empty value")
                    .font(.subheadline)
                    .foregroundColor(DonkColor.textSecondary)
            } else if let text {
                CodeView(text: text, language: JSONFormatting.isValid(text) ? .json : .plain)
            } else {
                CodeView(text: HexDump.hex(value, limit: 4096, grouped: true))
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isRevealed = false }
            } label: {
                Label("Hide", systemImage: "eye.slash")
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private func maskedButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DonkSpacing.s) {
                Text(String(repeating: "•", count: 8))
                    .font(DonkFont.code(.body, weight: .bold))
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel("Hidden value")
                Spacer(minLength: DonkSpacing.s)
                Label("Tap to reveal", systemImage: "eye")
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkColor.elevated))
        }
        .buttonStyle(.plain)
        .foregroundColor(DonkColor.accent)
    }

    private func protectedButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DonkSpacing.m) {
                Image(systemName: "lock.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(DonkColor.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Protected by biometrics/passcode — tap to authenticate")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(DonkColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("donk read it without user interaction and the keychain refused. Authenticating shows the system Face ID, Touch ID or passcode prompt.")
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkTone.warning.softBackground))
        }
        .buttonStyle(.plain)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: DonkSpacing.s) {
            ProgressView()
            Text(text)
                .font(.footnote)
                .foregroundColor(DonkColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private struct Attribute {
        let key: String
        let value: String
        let monospaced: Bool
    }

    private func attributes(_ item: KeychainItem) -> [Attribute] {
        var result: [Attribute] = []
        func add(_ key: String, _ value: String?, monospaced: Bool = true) {
            guard let value, !value.isEmpty else { return }
            result.append(Attribute(key: key, value: value, monospaced: monospaced))
        }
        add("Service", item.service)
        add("Account", item.account)
        add("Server", item.server)
        add("Protocol", item.protocolName)
        add("Port", item.port.map(String.init))
        add("Path", item.path)
        add("Security domain", item.securityDomain)
        add("Auth type", item.authenticationType)
        add("Label", item.label, monospaced: false)
        add("Description", item.itemDescription, monospaced: false)
        add("Comment", item.comment, monospaced: false)
        add("Access group", item.accessGroup)
        add("Accessibility", item.accessibilityDescription, monospaced: false)
        add("Synchronizable", item.isSynchronizable ? "Yes (iCloud Keychain)" : "No", monospaced: false)
        add("Created", item.created.map(StorageFormat.dateTime), monospaced: false)
        add("Modified", item.modified.map(StorageFormat.dateTime), monospaced: false)
        return result
    }
}

// MARK: - Editor

struct KeychainEditorTarget: Identifiable {
    let id = UUID()
    let data: Data
}

struct KeychainValueEditor: View {
    let title: String
    let original: Data
    let onSave: (Data) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: KeychainValueDraft
    @State private var isSaving = false

    init(title: String, original: Data, onSave: @escaping (Data) async -> Bool) {
        self.title = title
        self.original = original
        self.onSave = onSave
        self._draft = State(initialValue: KeychainValueDraft(data: original))
    }

    var body: some View {
        DonkNavigationContainer {
            VStack(alignment: .leading, spacing: DonkSpacing.m) {
                SegmentedTabs(selection: encodingBinding, tabs: KeychainValueEncoding.allCases, title: \.rawValue)
                    .frame(maxWidth: 240)
                CodeEditor(text: $draft.text, language: .plain, layout: .scrolling, showsToolbar: false, placeholder: "Value")
                if draft.encoding == .base64, draft.data == nil {
                    StorageValidationLabel(isValid: false, validText: "", message: "Not valid base64")
                }
                Text("Saved with SecItemUpdate; other attributes are kept.")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
            }
            .padding(DonkSpacing.l)
            .donkScreenBackground()
            .donkNavigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .font(.body.weight(.semibold))
                            .disabled(draft.data == nil || draft.data == original)
                    }
                }
            }
        }
        .donkTheme()
    }

    private var encodingBinding: Binding<KeychainValueEncoding> {
        Binding(
            get: { draft.encoding },
            set: { select($0) }
        )
    }

    private func select(_ encoding: KeychainValueEncoding) {
        switch draft.converted(to: encoding) {
        case let .success(converted):
            draft = converted
        case let .failure(issue):
            DonkHaptics.warning()
            DonkToast.show(issue.message, tone: .warning)
        }
    }

    private func save() {
        guard let data = draft.data else { return }
        isSaving = true
        Task {
            let saved = await onSave(data)
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }
}
