import DonkCore
import DonkUI
import SwiftUI

struct PlistFilePreview: View {
    enum Tab: String, CaseIterable, Hashable {
        case tree = "Tree"
        case xml = "XML"
    }

    struct Loaded {
        var document: PlistDocument
        var xml: String
        var tree: JSONValue
    }

    let url: URL
    let isEditable: Bool
    var onSave: ((URL) -> Void)?
    var onUnreadable: (() -> Void)?

    @State private var loaded: Loaded?
    @State private var loadError: String?
    @State private var tab: Tab = .tree
    @State private var isEditing = false
    @State private var draft = ""
    @State private var validationMessage: String?
    @State private var isDraftValid = true
    @State private var validationTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @StateObject private var search = CodeSearchState()

    var body: some View {
        Group {
            if let loadError {
                StorageErrorView(title: "Not a readable property list", message: loadError)
                    .overlay(alignment: .bottom) {
                        if let onUnreadable {
                            Button("View as Hex", action: onUnreadable)
                                .buttonStyle(.bordered)
                                .padding(.bottom, DonkSpacing.xxl)
                        }
                    }
            } else if let loaded {
                if isEditing {
                    editor(loaded)
                } else {
                    viewer(loaded)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .donkScreenBackground()
        .navigationBarBackButtonHidden(isEditing)
        .preference(key: StorageEditingPreferenceKey.self, value: isEditing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Cancel") { cancelEditing() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isEditing {
                    Button("Save") { save() }
                        .font(.body.weight(.semibold))
                        .disabled(isSaving || !isDraftValid || draft == loaded?.xml)
                } else if isEditable, loaded != nil {
                    Button("Edit") { beginEditing() }
                }
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { isEditing = false }
            Button("Keep Editing", role: .cancel) {}
        }
        .onChange(of: draft) { value in
            scheduleValidation(value)
        }
        .task { await load() }
    }

    // MARK: - Viewer

    private var preferencesDomain: DefaultsDomain? {
        PreferencesFile.domain(for: url)
    }

    @ViewBuilder
    private var preferencesWarning: some View {
        if let domain = preferencesDomain {
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                HStack(alignment: .top, spacing: DonkSpacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DonkColor.warning)
                    Text("cfprefsd owns this file. The app keeps UserDefaults in memory and cfprefsd caches and rewrites the file, so edits made here can be lost or go stale.")
                        .font(.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink {
                    DefaultsListView(domain: domain)
                } label: {
                    Label("Open in UserDefaults editor", systemImage: domain.kind == .standard ? "gearshape.fill" : "square.stack.3d.up.fill")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(DonkSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkTone.warning.softBackground))
        }
    }

    private func viewer(_ loaded: Loaded) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                preferencesWarning
                HStack(spacing: DonkSpacing.s) {
                    SegmentedTabs(selection: $tab, tabs: Tab.allCases, title: \.rawValue)
                        .frame(maxWidth: 180)
                    Spacer(minLength: DonkSpacing.xs)
                    TonePill(text: loaded.document.formatName, tone: .grpc, icon: "list.bullet.rectangle")
                }
                CodeSearchBar(state: search, prompt: "Find in property list")
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.top, DonkSpacing.s)
            switch tab {
            case .tree:
                JSONTreeView(value: loaded.tree, search: search, layout: .scrolling)
            case .xml:
                CodeView(text: loaded.xml, language: .plain, search: search, layout: .scrolling)
            }
        }
    }

    // MARK: - Editor

    private func editor(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            preferencesWarning
            HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
                StorageValidationLabel(isValid: isDraftValid, validText: "Valid XML plist", message: validationMessage)
                    .layoutPriority(1)
                Spacer(minLength: DonkSpacing.xs)
                TonePill(text: "Saves as " + (loaded.document.format == .binary ? "binary" : "XML"), tone: .neutral)
            }
            CodeEditor(text: $draft, language: .plain, layout: .scrolling, showsToolbar: false, placeholder: "<plist>…</plist>")
        }
        .padding(.horizontal, DonkSpacing.l)
        .padding(.vertical, DonkSpacing.s)
    }

    // MARK: - Actions

    private func beginEditing() {
        draft = loaded?.xml ?? ""
        isDraftValid = true
        validationMessage = nil
        isEditing = true
    }

    private func cancelEditing() {
        if draft != loaded?.xml {
            isConfirmingDiscard = true
        } else {
            isEditing = false
        }
    }

    private func scheduleValidation(_ text: String) {
        guard isEditing else { return }
        validationTask?.cancel()
        validationTask = Task {
            if text.utf8.count > 64 * 1024 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            let message = await Task.detached(priority: .userInitiated) { () -> String? in
                switch PlistDocument.parseXML(text) {
                case .success: return nil
                case let .failure(error): return error.message
                }
            }.value
            guard !Task.isCancelled else { return }
            isDraftValid = message == nil
            validationMessage = message
        }
    }

    private func save() {
        guard let loaded else { return }
        let text = draft
        let format = loaded.document.format
        let url = self.url
        isSaving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
                Result {
                    let object = try PlistDocument.parseXML(text).get()
                    let data = try PlistDocument.encode(object, format: format)
                    try FileOperations.writeData(data, to: url)
                    return try Self.makeLoaded(data)
                }
            }.value
            isSaving = false
            switch result {
            case let .success(value):
                self.loaded = value
                isEditing = false
                DonkHaptics.success()
                DonkToast.show("Saved", tone: .success)
                onSave?(url)
            case let .failure(error):
                DonkHaptics.error()
                DonkToast.show("Couldn't save: \(error.localizedDescription)", tone: .error, duration: 3)
            }
        }
    }

    private func load() async {
        guard loaded == nil, loadError == nil else { return }
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
            Result { try Self.makeLoaded(Data(contentsOf: url)) }
        }.value
        switch result {
        case let .success(value): loaded = value
        case let .failure(error): loadError = error.localizedDescription
        }
    }

    private nonisolated static func makeLoaded(_ data: Data) throws -> Loaded {
        let document = try PlistDocument.load(data)
        return Loaded(
            document: document,
            xml: try PlistDocument.xmlText(for: document.object),
            tree: PlistTree.jsonValue(from: document.object)
        )
    }
}
