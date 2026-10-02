import DonkCore
import DonkUI
import SwiftUI

// MARK: - Model

@MainActor
final class DefaultsEditorModel: ObservableObject {
    let domain: DefaultsDomain
    let key: String

    @Published private(set) var exists = true
    @Published private(set) var type: DefaultsValueType?
    @Published var stringValue = ""
    @Published private(set) var originalString = ""
    @Published var numberText = ""
    @Published private(set) var originalNumber = ""
    @Published var boolValue = false
    @Published private(set) var originalBool = false
    @Published var dateValue = Date()
    @Published private(set) var originalDate = Date()
    @Published private(set) var dataValue = Data()
    @Published var base64Text = ""
    @Published var jsonText = "" {
        didSet {
            if jsonText != oldValue { jsonError = nil }
        }
    }
    @Published private(set) var originalJSON: String?
    @Published private(set) var jsonError: String?
    @Published private(set) var tree: JSONValue?
    @Published private(set) var otherDescription = ""

    init(domain: DefaultsDomain, key: String) {
        self.domain = domain
        self.key = key
        load()
    }

    var isJSONEditable: Bool {
        originalJSON != nil
    }

    var isEditable: Bool {
        switch type {
        case .string, .int, .double, .bool, .date, .data: return true
        case .array, .dictionary: return isJSONEditable
        case nil: return false
        }
    }

    var hasChanges: Bool {
        guard exists else { return false }
        switch type {
        case .string:
            return stringValue != originalString
        case .int, .double:
            return numberText.trimmingCharacters(in: .whitespaces) != originalNumber
        case .bool:
            return boolValue != originalBool
        case .date:
            return dateValue != originalDate
        case .data:
            return base64Text.components(separatedBy: .whitespacesAndNewlines).joined() != dataValue.base64EncodedString()
        case .array, .dictionary:
            guard let originalJSON else { return false }
            return jsonText != originalJSON
        case nil:
            return false
        }
    }

    var validationError: String? {
        switch type {
        case .int:
            return DefaultsValues.parseInt(numberText) == nil ? "Enter a whole number" : nil
        case .double:
            return DefaultsValues.parseDouble(numberText) == nil ? "Enter a number, e.g. 3.14" : nil
        case .data:
            return DefaultsValues.parseBase64(base64Text) == nil ? "Not valid base64" : nil
        case .array, .dictionary:
            return jsonError
        default:
            return nil
        }
    }

    var canSave: Bool {
        hasChanges && validationError == nil
    }

    func load() {
        guard let value = DefaultsStore.value(forKey: key, in: domain) else {
            exists = false
            return
        }
        exists = true
        let detected = DefaultsValueType.detect(value)
        type = detected
        jsonError = nil
        switch detected {
        case .string:
            originalString = value as? String ?? ""
            stringValue = originalString
        case .int:
            originalNumber = "\((value as? NSNumber)?.int64Value ?? 0)"
            numberText = originalNumber
        case .double:
            originalNumber = DefaultsValues.formatDouble((value as? NSNumber)?.doubleValue ?? 0)
            numberText = originalNumber
        case .bool:
            originalBool = (value as? NSNumber)?.boolValue ?? false
            boolValue = originalBool
        case .date:
            originalDate = value as? Date ?? Date()
            dateValue = originalDate
        case .data:
            dataValue = value as? Data ?? Data()
            base64Text = dataValue.base64EncodedString()
        case .array, .dictionary:
            originalJSON = DefaultsValues.jsonText(for: value)
            jsonText = originalJSON ?? ""
            jsonError = nil
            tree = PlistTree.jsonValue(from: value)
        case nil:
            otherDescription = String(describing: value)
        }
    }

    @discardableResult
    func save() -> Bool {
        guard exists, let type, hasChanges else { return false }
        switch DefaultsValues.draftValue(
            type: type,
            string: stringValue,
            number: numberText,
            bool: boolValue,
            date: dateValue,
            base64: base64Text,
            json: jsonText
        ) {
        case let .success(value):
            DefaultsStore.set(value, forKey: key, in: domain)
            load()
            DonkHaptics.success()
            DonkToast.show("Saved", tone: .success)
            return true
        case let .failure(error):
            if type.isCollection {
                jsonError = error.message
            }
            DonkHaptics.error()
            return false
        }
    }

    func cancel() {
        load()
        DonkHaptics.light()
    }

    func delete() {
        DefaultsStore.remove(key, in: domain)
        exists = false
        DonkHaptics.success()
        DonkToast.show("Removed “\(key)”", icon: "trash.fill", tone: .success)
    }
}

extension DefaultsValues {
    static func draftValue(
        type: DefaultsValueType,
        string: String,
        number: String,
        bool: Bool,
        date: Date,
        base64: String,
        json: String
    ) -> Result<Any, FileOperationError> {
        switch type {
        case .string:
            return .success(string)
        case .int:
            guard let value = parseInt(number) else { return .failure(FileOperationError(message: "Enter a whole number")) }
            return .success(value)
        case .double:
            guard let value = parseDouble(number) else { return .failure(FileOperationError(message: "Enter a number, e.g. 3.14")) }
            return .success(value)
        case .bool:
            return .success(bool)
        case .date:
            return .success(date)
        case .data:
            guard let data = parseBase64(base64) else { return .failure(FileOperationError(message: "Not valid base64")) }
            return .success(data)
        case .array, .dictionary:
            return parseCollection(json, as: type)
        }
    }
}

// MARK: - View

struct DefaultsEditorView: View {
    @StateObject private var model: DefaultsEditorModel
    @State private var dataTab: DataTab = .hex
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    enum DataTab: String, CaseIterable, Hashable {
        case hex = "Hex"
        case base64 = "Base64"
    }

    init(domain: DefaultsDomain, key: String) {
        self._model = StateObject(wrappedValue: DefaultsEditorModel(domain: domain, key: key))
    }

    var body: some View {
        Group {
            if model.exists {
                editor
            } else {
                EmptyStateView(
                    icon: "key.fill",
                    title: "Key not found",
                    message: "“\(model.key)” no longer exists in this domain.",
                    tone: .neutral
                )
                .donkScreenBackground()
            }
        }
        .donkNavigationTitle(model.key)
        .navigationBarBackButtonHidden(model.hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.hasChanges {
                    Button("Cancel") { model.cancel() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.hasChanges {
                    Button("Save") { model.save() }
                        .font(.body.weight(.semibold))
                        .disabled(!model.canSave)
                }
            }
        }
        .confirmationDialog("Delete “\(model.key)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var editor: some View {
        DonkScrollContainer {
            DonkCard(title: "Key", icon: model.type?.icon ?? "key.fill", tone: model.type?.tone ?? .neutral) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Key", value: model.key, monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Domain", value: model.domain.name, monospacedValue: true)
                    Divider()
                    HStack {
                        Text("Type")
                            .font(.subheadline)
                            .foregroundColor(DonkColor.textSecondary)
                        Spacer()
                        DefaultsTypeBadge(type: model.type)
                    }
                    .padding(.vertical, 10)
                }
            } accessory: {
                CopyButton(text: model.key, label: "Key")
            }
            valueCard
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Key", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(DonkColor.error)
        }
    }

    @ViewBuilder
    private var valueCard: some View {
        switch model.type {
        case .string:
            DonkCard(title: "Value", icon: "pencil", tone: .web) {
                CodeEditor(text: $model.stringValue, language: .plain, layout: .embedded, showsToolbar: false, placeholder: "Empty string")
                editStatus
            } accessory: {
                CopyButton(label: "Value") { model.stringValue }
            }
        case .int, .double:
            DonkCard(title: "Value", icon: "number", tone: .info) {
                TextField(model.type == .int ? "Integer" : "Number", text: $model.numberText)
                    .font(DonkFont.code(.body))
                    .keyboardType(.numbersAndPunctuation)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { model.save() }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkColor.elevated))
                editStatus
            } accessory: {
                CopyButton(label: "Value") { model.numberText }
            }
        case .bool:
            DonkCard(title: "Value", icon: "switch.2", tone: .accent) {
                Toggle(isOn: $model.boolValue) {
                    Text(model.boolValue ? "true" : "false")
                        .font(DonkFont.code(.body, weight: .semibold))
                        .foregroundColor(model.boolValue ? DonkColor.success : DonkColor.textSecondary)
                }
                editStatus
            }
        case .date:
            DonkCard(title: "Value", icon: "calendar", tone: .warning) {
                DatePicker("Date", selection: $model.dateValue, displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline)
                KeyValueRow(key: "ISO 8601", value: StorageFormat.iso8601(model.dateValue), monospacedValue: true)
                Button {
                    model.dateValue = Date()
                } label: {
                    Label("Set to Now", systemImage: "clock.fill")
                        .font(.footnote.weight(.semibold))
                }
                editStatus
            } accessory: {
                CopyButton(label: "Date") { StorageFormat.iso8601(model.dateValue) }
            }
        case .data:
            dataCard
        case .array, .dictionary:
            collectionCard
        case nil:
            DonkCard(title: "Value", icon: "questionmark.circle", tone: .neutral) {
                Text(model.otherDescription)
                    .font(DonkFont.code)
                    .textSelection(.enabled)
                Text("This value type can't be edited.")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var editStatus: some View {
        if let error = model.validationError, model.hasChanges {
            StorageValidationLabel(isValid: false, validText: "", message: error)
        } else if model.hasChanges {
            HStack(spacing: DonkSpacing.s) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundColor(DonkColor.warning)
                Text(model.type == .int || model.type == .double
                     ? "Unsaved changes. Tap Save or press Return."
                     : "Unsaved changes. Tap Save to write them, or Cancel.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundColor(DonkColor.textSecondary)
        } else {
            Text("Saved as \(model.type?.rawValue ?? "value"). Edits are written only when you tap Save.")
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dataCard: some View {
        DonkCard(title: "Value · \(DonkFormat.bytes(model.dataValue.count))", icon: "cube.box.fill", tone: .neutral) {
            SegmentedTabs(selection: $dataTab, tabs: DataTab.allCases, title: \.rawValue)
            switch dataTab {
            case .hex:
                if model.dataValue.isEmpty {
                    Text("Empty data")
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                } else {
                    CodeView(text: HexDump.hex(model.dataValue, limit: 8192, grouped: true))
                }
            case .base64:
                CodeEditor(text: $model.base64Text, language: .plain, layout: .embedded, showsToolbar: false, placeholder: "Base64")
            }
            editStatus
        } accessory: {
            CopyButton(label: "Base64") { model.dataValue.base64EncodedString() }
        }
    }

    @ViewBuilder
    private var collectionCard: some View {
        if model.isJSONEditable {
            DonkCard(title: "Value", icon: model.type?.icon ?? "curlybraces", tone: .grpc) {
                CodeEditor(text: $model.jsonText, language: .json, layout: .embedded, showsToolbar: true)
                editStatus
                Text("Saved as a property list \(model.type == .array ? "array" : "dictionary").")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
            } accessory: {
                CopyButton(label: "JSON") { model.jsonText }
            }
        } else if let tree = model.tree {
            DonkCard(title: "Value", icon: model.type?.icon ?? "curlybraces", tone: .grpc) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Contains dates or data, so it can't be edited as JSON.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
                JSONTreeView(value: tree, layout: .embedded, showsToolbar: false)
            } accessory: {
                CopyButton(label: "Value") { tree.prettyPrinted() }
            }
        }
    }
}

// MARK: - Add key

struct DefaultsAddKeyView: View {
    let domain: DefaultsDomain
    let existingKeys: Set<String>
    var onAdd: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var type: DefaultsValueType = .string
    @State private var stringValue = ""
    @State private var numberText = "0"
    @State private var boolValue = false
    @State private var dateValue = Date()
    @State private var base64Text = ""
    @State private var jsonText = "[]"

    var body: some View {
        DonkNavigationContainer {
            Form {
                Section {
                    TextField("Key name", text: $key)
                        .font(DonkFont.code(.body))
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    if existingKeys.contains(trimmedKey) {
                        StorageValidationLabel(isValid: false, validText: "", message: "A key with this name exists and will be overwritten.")
                    }
                } header: {
                    Text("Key")
                }
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(DefaultsValueType.allCases) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                } header: {
                    Text("Type")
                }
                Section {
                    valueEditor
                    if case let .failure(error) = parsedValue {
                        StorageValidationLabel(isValid: false, validText: "", message: error.message)
                    }
                } header: {
                    Text("Value")
                }
            }
            .donkNavigationTitle("New Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .font(.body.weight(.semibold))
                        .disabled(!canAdd)
                }
            }
            .onChange(of: type) { newType in
                if newType == .array, jsonText.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" { jsonText = "[]" }
                if newType == .dictionary, jsonText.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" { jsonText = "{}" }
                if newType == .double, numberText == "0" { numberText = "0.0" }
                if newType == .int, numberText == "0.0" { numberText = "0" }
            }
        }
        .donkTheme()
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard !trimmedKey.isEmpty else { return false }
        if case .success = parsedValue { return true }
        return false
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch type {
        case .string:
            TextField("Text", text: $stringValue)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
        case .int, .double:
            TextField(type == .int ? "Integer" : "Number", text: $numberText)
                .font(DonkFont.code(.body))
                .keyboardType(.numbersAndPunctuation)
                .disableAutocorrection(true)
        case .bool:
            Toggle(boolValue ? "true" : "false", isOn: $boolValue)
        case .date:
            DatePicker("Date", selection: $dateValue, displayedComponents: [.date, .hourAndMinute])
        case .data:
            TextField("Base64, e.g. 3q2+7w==", text: $base64Text)
                .font(DonkFont.code(.body))
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
        case .array, .dictionary:
            CodeEditor(text: $jsonText, language: .json, layout: .scrolling, showsToolbar: true)
                .frame(height: 200)
                .padding(.vertical, 4)
        }
    }

    private var parsedValue: Result<Any, FileOperationError> {
        switch type {
        case .string:
            return .success(stringValue)
        case .int:
            guard let value = DefaultsValues.parseInt(numberText) else { return .failure(FileOperationError(message: "Enter a whole number")) }
            return .success(value)
        case .double:
            guard let value = DefaultsValues.parseDouble(numberText) else { return .failure(FileOperationError(message: "Enter a number")) }
            return .success(value)
        case .bool:
            return .success(boolValue)
        case .date:
            return .success(dateValue)
        case .data:
            guard let data = DefaultsValues.parseBase64(base64Text) else { return .failure(FileOperationError(message: "Not valid base64")) }
            return .success(data)
        case .array, .dictionary:
            return DefaultsValues.parseCollection(jsonText, as: type)
        }
    }

    private func add() {
        guard case let .success(value) = parsedValue, !trimmedKey.isEmpty else { return }
        DefaultsStore.set(value, forKey: trimmedKey, in: domain)
        DonkHaptics.success()
        DonkToast.show("Added “\(trimmedKey)”", tone: .success)
        onAdd()
        dismiss()
    }
}
