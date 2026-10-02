import DonkUI
import SwiftUI
import UIKit

// MARK: - Load state

enum StorageLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

// MARK: - Editing preference

struct StorageEditingPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// MARK: - Text prompt

@MainActor
enum StoragePrompt {
    static func text(
        title: String,
        message: String? = nil,
        text: String = "",
        placeholder: String = "",
        confirmTitle: String = "Save",
        selectsBaseName: Bool = false,
        completion: @escaping @MainActor (String) -> Void
    ) {
        guard let presenter = DonkWindowManager.presentingViewController else {
            DonkToast.show("Nothing to present from", tone: .error)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let confirm = UIAlertAction(title: confirmTitle, style: .default) { [weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            completion(value)
        }
        alert.addAction(confirm)
        alert.preferredAction = confirm
        presenter.present(alert, animated: true) {
            guard selectsBaseName, let field = alert.textFields?.first else { return }
            let name = field.text ?? ""
            let baseLength = (name as NSString).deletingPathExtension.utf16.count
            guard baseLength > 0,
                  let start = field.position(from: field.beginningOfDocument, offset: 0),
                  let end = field.position(from: field.beginningOfDocument, offset: baseLength)
            else { return }
            field.selectedTextRange = field.textRange(from: start, to: end)
        }
    }
}

// MARK: - Validation label

struct StorageValidationLabel: View {
    let isValid: Bool
    let validText: String
    let message: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
            Text(isValid ? validText : (message ?? "Invalid"))
                .font(.caption.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(isValid ? DonkColor.success : DonkColor.error)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Error state

struct StorageErrorView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        EmptyStateView(
            icon: "exclamationmark.triangle.fill",
            title: title,
            message: message,
            tone: .error,
            actionTitle: retry == nil ? nil : "Try Again",
            action: retry
        )
    }
}

// MARK: - Symbols

extension FileKind {
    var icon: String {
        switch self {
        case .folder: return "folder.fill"
        case .text: return "doc.text.fill"
        case .json: return "curlybraces"
        case .plist: return "list.bullet.rectangle"
        case .image: return "photo.fill"
        case .sqlite: return "cylinder.split.1x2.fill"
        case .pdf: return "doc.richtext"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        case .document: return "doc.fill"
        case .binary: return "cube.box.fill"
        }
    }

    var tone: DonkTone {
        switch self {
        case .folder: return .info
        case .text: return .neutral
        case .json: return .warning
        case .plist: return .grpc
        case .image: return .success
        case .sqlite: return .accent
        case .pdf: return .error
        case .video, .audio: return .web
        case .archive: return .warning
        case .document: return .info
        case .binary: return .neutral
        }
    }
}

extension FileItem {
    var icon: String {
        if isSymbolicLink { return "link" }
        return (kind ?? .binary).icon
    }

    var tone: DonkTone {
        if isSymbolicLink { return .web }
        return kind?.tone ?? .neutral
    }
}

extension DefaultsValueType {
    var icon: String {
        switch self {
        case .string: return "textformat"
        case .int: return "number"
        case .double: return "textformat.123"
        case .bool: return "switch.2"
        case .date: return "calendar"
        case .data: return "cube.box.fill"
        case .array: return "list.number"
        case .dictionary: return "curlybraces"
        }
    }

    var tone: DonkTone {
        switch self {
        case .string: return .web
        case .int, .double: return .info
        case .bool: return .accent
        case .date: return .warning
        case .data: return .neutral
        case .array, .dictionary: return .grpc
        }
    }
}

struct DefaultsTypeBadge: View {
    let type: DefaultsValueType?

    var body: some View {
        TonePill(text: type?.rawValue ?? "Other", tone: type?.tone ?? .neutral)
    }
}

// MARK: - Done button

struct StorageDoneButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Done") { dismiss() }
            .font(.body.weight(.semibold))
    }
}
