import DonkCore
import DonkUI
import SwiftUI

struct TextFilePreview: View {
    struct Loaded: Equatable {
        var text: String
        var lineCount: Int
        var byteCount: Int
        var isLossy: Bool
    }

    static let editLimit = 2 * 1024 * 1024

    let url: URL
    let isJSON: Bool
    let isEditable: Bool
    var onSave: ((URL) -> Void)?

    @State private var loaded: Loaded?
    @State private var loadError: String?
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @StateObject private var search = CodeSearchState()

    var body: some View {
        Group {
            if let loadError {
                StorageErrorView(title: "Can't read file", message: loadError)
            } else if let loaded {
                if isEditing {
                    editor
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
                        .disabled(isSaving || draft == loaded?.text)
                } else if canEdit {
                    Button("Edit") { beginEditing() }
                }
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { isEditing = false }
            Button("Keep Editing", role: .cancel) {}
        }
        .task { await load() }
    }

    private var canEdit: Bool {
        guard isEditable, let loaded else { return false }
        return !loaded.isLossy && loaded.byteCount <= Self.editLimit
    }

    // MARK: - Viewer

    @ViewBuilder
    private func viewer(_ loaded: Loaded) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DonkSpacing.s) {
                        TonePill(text: isJSON ? "JSON" : "Text", tone: isJSON ? .warning : .neutral, icon: isJSON ? "curlybraces" : "text.alignleft")
                        TonePill(text: DonkFormat.bytes(loaded.byteCount), tone: .neutral)
                        TonePill(text: loaded.lineCount == 1 ? "1 line" : "\(DonkFormat.number(loaded.lineCount)) lines", tone: .neutral)
                        if loaded.isLossy {
                            TonePill(text: "Lossy UTF-8", tone: .warning, icon: "exclamationmark.triangle.fill")
                        } else if isEditable && loaded.byteCount > Self.editLimit {
                            TonePill(text: "Too large to edit", tone: .warning)
                        } else if !isEditable {
                            TonePill(text: "Read-only", tone: .accent, icon: "lock.fill")
                        }
                    }
                }
                CodeSearchBar(state: search, prompt: "Find in file")
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.top, DonkSpacing.s)
            if isJSON {
                JSONBodyView(text: loaded.text, search: search, layout: .scrolling, fileName: url.lastPathComponent)
            } else if loaded.text.isEmpty {
                EmptyStateView(
                    icon: "doc.text",
                    title: "Empty file",
                    message: canEdit ? "Tap Edit to add some text." : nil,
                    tone: .neutral
                )
            } else {
                CodeView(text: loaded.text, language: .plain, search: search, layout: .scrolling)
            }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        CodeEditor(
            text: $draft,
            language: isJSON ? .json : .plain,
            layout: .scrolling,
            showsToolbar: true,
            placeholder: isJSON ? "JSON" : "Text"
        )
        .padding(.horizontal, DonkSpacing.l)
        .padding(.vertical, DonkSpacing.s)
    }

    // MARK: - Actions

    private func beginEditing() {
        draft = loaded?.text ?? ""
        isEditing = true
    }

    private func cancelEditing() {
        if draft != loaded?.text {
            isConfirmingDiscard = true
        } else {
            isEditing = false
        }
    }

    private func save() {
        let text = draft
        if isJSON, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !JSONFormatting.isValid(text) {
            DonkHaptics.error()
            DonkToast.show("Fix the JSON errors before saving", tone: .error)
            return
        }
        isSaving = true
        let url = self.url
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileOperations.writeText(text, to: url) }
            }.value
            isSaving = false
            switch result {
            case .success:
                loaded = Self.makeLoaded(text: text, byteCount: text.utf8.count, isLossy: false)
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
        guard loaded == nil else { return }
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
            Result {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if let text = String(data: data, encoding: .utf8) {
                    return Self.makeLoaded(text: text, byteCount: data.count, isLossy: false)
                }
                return Self.makeLoaded(text: String(decoding: data, as: UTF8.self), byteCount: data.count, isLossy: true)
            }
        }.value
        switch result {
        case let .success(value): loaded = value
        case let .failure(error): loadError = error.localizedDescription
        }
    }

    private nonisolated static func makeLoaded(text: String, byteCount: Int, isLossy: Bool) -> Loaded {
        var lines = text.isEmpty ? 0 : 1
        for byte in text.utf8 where byte == 0x0A {
            lines += 1
        }
        if text.utf8.last == 0x0A {
            lines -= 1
        }
        return Loaded(text: text, lineCount: max(lines, 0), byteCount: byteCount, isLossy: isLossy)
    }
}
