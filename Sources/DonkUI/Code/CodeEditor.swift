import DonkJSON
import SwiftUI
import UIKit

// MARK: - Public view

public struct CodeEditor: View {
    @Binding private var text: String
    private let language: CodeLanguage
    private let layout: DonkLayoutMode
    private let showsToolbar: Bool
    private let placeholder: String?
    @StateObject private var model = CodeEditorModel()

    public init(
        text: Binding<String>,
        language: CodeLanguage = .json,
        layout: DonkLayoutMode = .scrolling,
        showsToolbar: Bool = true,
        placeholder: String? = nil
    ) {
        self._text = text
        self.language = language
        self.layout = layout
        self.showsToolbar = showsToolbar
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            if showsToolbar && language == .json {
                toolbar
            }
            editor
        }
        .onAppear {
            model.validate(text, language: language, immediate: true)
        }
        .onChange(of: text) { value in
            model.validate(value, language: language, immediate: false)
        }
        .onChange(of: language) { value in
            model.validate(text, language: value, immediate: true)
        }
    }

    private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
        return CodeEditorTextView(text: $text, language: language, layout: layout, model: model)
            .frame(minHeight: layout == .embedded ? 120 : 80, maxHeight: layout == .scrolling ? .infinity : nil)
            .background(shape.fill(DonkColor.card))
            .overlay(alignment: .topLeading) {
                if let placeholder, text.isEmpty {
                    Text(placeholder)
                        .font(DonkFont.code)
                        .foregroundColor(DonkColor.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                shape.strokeBorder(
                    model.validation.isInvalid ? DonkColor.error.opacity(0.55) : DonkColor.separator,
                    lineWidth: model.validation.isInvalid ? 1 : 0.5
                )
            )
            .clipShape(shape)
    }

    private var toolbar: some View {
        HStack(spacing: DonkSpacing.s) {
            validationLabel
                .layoutPriority(1)
            Spacer(minLength: DonkSpacing.xs)
            Button {
                minify()
            } label: {
                Text("Minify")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(DonkColor.accent)
            Button {
                prettify()
            } label: {
                Label("Pretty", systemImage: "text.alignleft")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(DonkColor.accent)
        }
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch model.validation {
        case .empty:
            validationPill("Empty", icon: "circle.dashed", tone: .neutral)
        case .valid:
            validationPill("Valid JSON", icon: "checkmark.circle.fill", tone: .success)
        case let .invalid(line, column, reason, _):
            Button {
                model.revealError()
            } label: {
                validationPill("Line \(line):\(column) · \(reason)", icon: "exclamationmark.triangle.fill", tone: .error)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Moves the cursor to the error")
        }
    }

    private func validationPill(_ title: String, icon: String, tone: DonkTone) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.caption2.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tone.softBackground))
        .accessibilityElement(children: .combine)
    }

    private func prettify() {
        guard let pretty = JSONFormatting.pretty(text) else {
            DonkHaptics.error()
            DonkToast.show("Invalid JSON", tone: .error)
            return
        }
        DonkHaptics.light()
        text = pretty
    }

    private func minify() {
        guard let value = try? JSONValue.parse(text) else {
            DonkHaptics.error()
            DonkToast.show("Invalid JSON", tone: .error)
            return
        }
        DonkHaptics.light()
        text = value.compact()
    }
}

// MARK: - Model

@MainActor
final class CodeEditorModel: ObservableObject {
    enum Validation: Equatable, Sendable {
        case empty
        case valid
        case invalid(line: Int, column: Int, reason: String, offset: Int)

        var isInvalid: Bool {
            if case .invalid = self { return true }
            return false
        }
    }

    @Published private(set) var validation: Validation = .empty
    weak var textView: UITextView?
    private var task: Task<Void, Never>?

    func validate(_ text: String, language: CodeLanguage, immediate: Bool) {
        task?.cancel()
        guard language == .json else {
            validation = .empty
            return
        }
        if immediate && text.utf8.count <= 32_000 {
            validation = Self.evaluate(text)
            return
        }
        task = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                CodeEditorModel.evaluate(text)
            }.value
            guard !Task.isCancelled else { return }
            self?.validation = result
        }
    }

    func revealError() {
        guard case let .invalid(_, _, _, offset) = validation, let textView else { return }
        let text = textView.text ?? ""
        var bytes = 0
        var location = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            if bytes + width > offset { break }
            bytes += width
            location += UTF16.width(scalar)
        }
        let length = (textView.text as NSString?)?.length ?? 0
        let range = NSRange(location: min(location, length), length: location < length ? 1 : 0)
        DonkHaptics.warning()
        textView.becomeFirstResponder()
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    nonisolated static func evaluate(_ text: String) -> Validation {
        if text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .empty
        }
        do {
            _ = try JSONValue.parse(text)
            return .valid
        } catch let error as JSONParseError {
            let position = position(of: error.offset, in: text)
            return .invalid(line: position.line, column: position.column, reason: error.reason, offset: error.offset)
        } catch {
            return .invalid(line: 1, column: 1, reason: "invalid JSON", offset: 0)
        }
    }

    nonisolated static func position(of offset: Int, in text: String) -> (line: Int, column: Int) {
        var line = 1
        var column = 1
        var index = 0
        for byte in text.utf8 {
            if index >= offset { break }
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
            index += 1
        }
        return (line, column)
    }
}

// MARK: - Representable

struct CodeEditorTextView: UIViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let layout: DonkLayoutMode
    let model: CodeEditorModel

    func makeCoordinator() -> CodeEditorCoordinator {
        CodeEditorCoordinator(text: $text)
    }

    func makeUIView(context: Context) -> DonkCodeTextView {
        let view = DonkCodeTextView.make(fitsContent: layout == .embedded)
        view.isEditable = true
        view.isSelectable = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .default
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.delegate = context.coordinator
        if language == .json {
            view.inputAccessoryView = CodeEditorCoordinator.makeAccessory(for: view)
        }
        context.coordinator.textView = view
        context.coordinator.language = language
        context.coordinator.setText(text)
        model.textView = view
        return view
    }

    func updateUIView(_ view: DonkCodeTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = $text
        let fitsContent = layout == .embedded
        if view.fitsContent != fitsContent {
            view.fitsContent = fitsContent
        }
        if coordinator.language != language {
            coordinator.language = language
            view.inputAccessoryView = language == .json ? CodeEditorCoordinator.makeAccessory(for: view) : nil
            coordinator.setText(text)
        } else if coordinator.lastText != text {
            coordinator.setText(text)
        }
        if model.textView !== view {
            model.textView = view
        }
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DonkCodeTextView, context: Context) -> CGSize? {
        guard layout == .embedded, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(120, ceil(size.height)))
    }
}

// MARK: - Coordinator

@MainActor
final class CodeEditorCoordinator: NSObject, UITextViewDelegate {
    var binding: Binding<String>
    var language: CodeLanguage = .json
    weak var textView: DonkCodeTextView?
    private(set) var lastText = ""
    private var highlightTask: Task<Void, Never>?

    init(text: Binding<String>) {
        self.binding = text
    }

    func setText(_ text: String) {
        guard let textView else { return }
        lastText = text
        let selection = textView.selectedRange
        let font = DonkFont.uiCode()
        let attributed = JSONSyntax.attributedString(text, language: language, font: font)
        if language == .json && attributed.length <= JSONSyntax.editorLimit {
            JSONSyntax.apply(JSONSyntax.tokens(in: text), to: attributed)
        }
        textView.attributedText = attributed
        textView.typingAttributes = typingAttributes(font: font)
        let length = attributed.length
        let location = min(selection.location, length)
        textView.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        textView.invalidateIntrinsicContentSize()
    }

    func textViewDidChange(_ textView: UITextView) {
        let value = textView.text ?? ""
        lastText = value
        binding.wrappedValue = value
        textView.invalidateIntrinsicContentSize()
        scheduleHighlight()
    }

    private func typingAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: JSONSyntax.paragraphStyle(),
        ]
    }

    private func scheduleHighlight() {
        highlightTask?.cancel()
        guard language == .json else { return }
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.highlightNow()
        }
    }

    private func highlightNow() {
        guard let textView, textView.markedTextRange == nil else { return }
        let storage = textView.textStorage
        let length = storage.length
        guard length > 0, length <= JSONSyntax.editorLimit else { return }
        let tokens = JSONSyntax.tokens(in: storage.string)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: JSONSyntax.baseColor(for: .json), range: NSRange(location: 0, length: length))
        JSONSyntax.apply(tokens, to: storage)
        storage.endEditing()
    }

    static func makeAccessory(for textView: UITextView) -> UIView {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let font = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        var items: [UIBarButtonItem] = []
        let symbols: [(title: String, insert: String)] = [
            ("{", "{"), ("}", "}"), ("[", "["), ("]", "]"), ("\"", "\""), (":", ": "), (",", ","), ("⇥", "  "),
        ]
        for symbol in symbols {
            let item = UIBarButtonItem(title: symbol.title, primaryAction: UIAction { [weak textView] _ in
                textView?.insertText(symbol.insert)
            })
            item.setTitleTextAttributes([.font: font], for: .normal)
            item.setTitleTextAttributes([.font: font], for: .highlighted)
            items.append(item)
            items.append(.flexibleSpace())
        }
        items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak textView] _ in
            textView?.resignFirstResponder()
        }))
        toolbar.items = items
        toolbar.sizeToFit()
        return toolbar
    }
}
