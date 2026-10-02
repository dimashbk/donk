import DonkCore
import DonkUI
import SwiftUI

// MARK: - Sheet

struct RuleEditorSheet: View {
    let draft: RuleDraft
    let isNew: Bool

    var body: some View {
        DonkNavigationContainer {
            RuleEditorView(draft: draft, isNew: isNew, showsCancel: true)
        }
        .donkTheme()
    }
}

// MARK: - Editor

struct RuleEditorView: View {
    @State private var draft: RuleDraft
    private let isNew: Bool
    private let showsCancel: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    @State private var preview = MatchPreview()

    init(draft: RuleDraft, isNew: Bool, showsCancel: Bool) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.showsCancel = showsCancel
    }

    var body: some View {
        Form {
            ruleSection
            appliesSection
            matchSection
            previewSection
            actionSection
            switch draft.action {
            case .mapLocal:
                mapLocalSections
            case .rewrite:
                rewriteSections
            case .breakpoint:
                breakpointSection
            }
            if !isNew {
                Section {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete Rule", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .donkListStyle()
        .donkNavigationTitle(isNew ? "New Rule" : "Edit Rule")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showsCancel {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save", action: save)
                    .font(.body.weight(.semibold))
                    .disabled(!draft.isValid)
            }
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                RuleStore.shared.remove(draft.id)
                DonkHaptics.warning()
                DonkToast.show("Rule deleted", icon: "trash", tone: .neutral)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: previewKey) {
            await refreshPreview()
        }
    }

    // MARK: - Sections

    private var ruleSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text(draft.displayName))
                .font(.body.weight(.medium))
            Toggle("Enabled", isOn: $draft.isEnabled)
        } header: {
            DonkSectionHeader("Rule")
        }
    }

    private var appliesSection: some View {
        Section {
            Toggle(isOn: $draft.http) {
                Label {
                    Text("HTTP")
                } icon: {
                    Image(systemName: EntryStyle.kindIcon(.http)).foregroundColor(DonkColor.info)
                }
            }
            Toggle(isOn: $draft.grpc) {
                Label {
                    Text("gRPC")
                } icon: {
                    Image(systemName: EntryStyle.kindIcon(.grpc)).foregroundColor(DonkColor.grpc)
                }
            }
        } header: {
            DonkSectionHeader("Applies to")
        } footer: {
            if !draft.http && !draft.grpc {
                IssueText("Choose HTTP, gRPC or both")
            } else {
                Text("WebView traffic is never modified.")
            }
        }
    }

    private var matchSection: some View {
        Section {
            if draft.http {
                Picker("Method", selection: $draft.method) {
                    ForEach(RuleDraft.methods, id: \.self) { method in
                        Text(method.isEmpty ? "Any" : method).tag(method)
                    }
                }
            }
            Picker("Mode", selection: $draft.mode) {
                Text("Contains").tag(URLMatcher.Mode.contains)
                Text("Wildcard").tag(URLMatcher.Mode.wildcard)
                Text("Regex").tag(URLMatcher.Mode.regex)
            }
            .pickerStyle(.segmented)
            TextField(patternPlaceholder, text: $draft.pattern)
                .font(DonkFont.code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
        } header: {
            DonkSectionHeader("Match")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let issue = draft.patternIssue, !draft.pattern.isEmpty || draft.mode == .regex {
                    IssueText(issue)
                } else if !draft.pattern.isEmpty {
                    Label("Valid pattern", systemImage: "checkmark.circle.fill")
                        .foregroundColor(DonkColor.success)
                }
                Text(modeHint)
                if draft.grpc {
                    Text("gRPC calls are matched against grpc://host/package.Service/Method; the method picker does not apply to them.")
                }
            }
        }
    }

    private var patternPlaceholder: String {
        switch draft.mode {
        case .contains: return "api.example.com/v1/accounts"
        case .wildcard: return "https://*.example.com/v1/*/balance"
        case .regex: return #"^https://api\.example\.com/v\d+/users/\d+$"#
        }
    }

    private var modeHint: String {
        switch draft.mode {
        case .contains: return "Matches when the full URL contains this text (case-insensitive)."
        case .wildcard: return "* matches any run of characters, ? a single one. The pattern must cover the whole URL."
        case .regex: return "Case-insensitive regular expression searched in the full URL."
        }
    }

    private var previewSection: some View {
        Section {
            if draft.patternIssue != nil {
                Text("Enter a valid pattern to preview matches.")
                    .font(.footnote)
                    .foregroundColor(DonkColor.textTertiary)
            } else if preview.items.isEmpty {
                HStack(spacing: DonkSpacing.s) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(DonkColor.textTertiary)
                    Text(preview.isLoading ? "Checking recent requests…" : "No recent requests match")
                        .font(.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                }
            } else {
                ForEach(preview.items) { item in
                    HStack(spacing: DonkSpacing.s) {
                        MethodBadge(item.method)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(DonkTextBreaking.breakable(item.title))
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.host ?? "—")
                                .font(.caption2)
                                .foregroundColor(DonkColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: DonkSpacing.s)
                        StatusPill(item.status, tone: item.statusTone)
                    }
                }
                if preview.count > preview.items.count {
                    Text("and \(preview.count - preview.items.count) more")
                        .font(.caption)
                        .foregroundColor(DonkColor.textTertiary)
                }
            }
        } header: {
            DonkSectionHeader(previewTitle, icon: "scope")
        }
    }

    private var previewTitle: String {
        guard draft.patternIssue == nil else { return "Matches" }
        return preview.count == 1 ? "Matches 1 recent request" : "Matches \(preview.count) recent requests"
    }

    private var actionSection: some View {
        Section {
            Picker("Action", selection: $draft.action) {
                ForEach(RuleActionKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            DonkSectionHeader("Action")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.action.explanation)
                if let issue = draft.actionIssue {
                    IssueText(issue)
                }
            }
        }
    }

    // MARK: - Map Local

    @ViewBuilder
    private var mapLocalSections: some View {
        if draft.http {
            Section {
                HStack(spacing: DonkSpacing.s) {
                    Text("Status")
                    Spacer(minLength: DonkSpacing.s)
                    TextField("200", text: $draft.mockStatus)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 80)
                    Menu {
                        ForEach(RuleDraft.statusPresets, id: \.self) { code in
                            Button("\(code) \(ResponseSnapshot.reasonPhrase(for: code))") {
                                draft.mockStatus = String(code)
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Status presets")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text(draft.mockDelay == 0 ? "None" : String(format: "%.2g s", draft.mockDelay))
                            .font(.body.monospacedDigit())
                            .foregroundColor(DonkColor.textSecondary)
                    }
                    Slider(value: $draft.mockDelay, in: 0...10, step: 0.25)
                }
            } header: {
                DonkSectionHeader("HTTP response")
            } footer: {
                if let code = Int(draft.mockStatus), !ResponseSnapshot.reasonPhrase(for: code).isEmpty {
                    Text("\(code) \(ResponseSnapshot.reasonPhrase(for: code))")
                }
            }
            Section {
                HeaderRowsEditor(headers: $draft.mockHeaders)
            } header: {
                DonkSectionHeader("Headers", count: draft.mockHeaders.count)
            }
            Section {
                CodeEditor(
                    text: $draft.mockBody,
                    language: CodeLanguage.detect(contentType: contentType(draft.mockHeaders), text: draft.mockBody.isEmpty ? "{" : draft.mockBody),
                    placeholder: "Response body"
                )
                .frame(height: 300)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            } header: {
                DonkSectionHeader("Body")
            } footer: {
                Text("Prefix the body with base64: to send binary data.")
            }
        }
        if draft.grpc {
            Section {
                GRPCStatusPicker(title: "Status", selection: $draft.mockGRPCStatus, allowsKeep: false)
                TextField("Status message (optional)", text: $draft.mockGRPCMessage)
            } header: {
                DonkSectionHeader("gRPC response")
            }
            Section {
                ForEach($draft.mockGRPCMessages) { $message in
                    CodeEditor(text: $message.text, language: .json, placeholder: "{ }")
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
                .onDelete { draft.mockGRPCMessages.remove(atOffsets: $0) }
                Button {
                    draft.mockGRPCMessages.append(TextDraft(text: "{}"))
                } label: {
                    AddLabel(title: "Add Message")
                }
            } header: {
                DonkSectionHeader("Response messages", count: draft.mockGRPCMessages.count)
            } footer: {
                Text("Each entry is the JSON of one response message, delivered in order. Swipe to remove.")
            }
        }
    }

    // MARK: - Rewrite

    @ViewBuilder
    private var rewriteSections: some View {
        Section {
            Toggle("Rewrite request", isOn: $draft.rewritesRequest)
            if draft.rewritesRequest {
                TextField("New URL (leave empty to keep)", text: $draft.rewriteURL)
                    .font(DonkFont.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                if draft.http {
                    Picker("Method", selection: $draft.rewriteMethod) {
                        ForEach(RuleDraft.methods, id: \.self) { method in
                            Text(method.isEmpty ? "Keep" : method).tag(method)
                        }
                    }
                }
            }
        } header: {
            DonkSectionHeader("Request", icon: "arrow.up.circle")
        }
        if draft.rewritesRequest {
            HeaderPatchSections(title: "Request headers", patch: $draft.rewriteRequestHeaders)
            BodyPatchSection(title: "Request body", patch: $draft.rewriteRequestBody)
        }
        Section {
            Toggle("Rewrite response", isOn: $draft.rewritesResponse)
            if draft.rewritesResponse {
                if draft.http {
                    HStack {
                        Text("Status")
                        Spacer()
                        TextField("Keep", text: $draft.rewriteStatus)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 100)
                    }
                }
                if draft.grpc {
                    GRPCStatusPicker(title: "gRPC status", selection: $draft.rewriteGRPCStatus, allowsKeep: true)
                    if draft.rewriteGRPCStatus >= 0 {
                        TextField("Status message (optional)", text: $draft.rewriteGRPCMessage)
                    }
                }
            }
        } header: {
            DonkSectionHeader("Response", icon: "arrow.down.circle")
        } footer: {
            if draft.rewritesResponse {
                Text("Response rewrites buffer the whole body before the app receives it.")
            }
        }
        if draft.rewritesResponse {
            HeaderPatchSections(title: "Response headers", patch: $draft.rewriteResponseHeaders)
            BodyPatchSection(title: "Response body", patch: $draft.rewriteResponseBody)
        }
    }

    // MARK: - Breakpoint

    private var breakpointSection: some View {
        Section {
            Toggle(isOn: $draft.breaksOnRequest) {
                DonkLabelRow(icon: "arrow.up.circle.fill", tone: .info, title: "Pause requests", subtitle: "Edit method, URL, headers and body before sending — or answer locally")
            }
            Toggle(isOn: $draft.breaksOnResponse) {
                DonkLabelRow(icon: "arrow.down.circle.fill", tone: .success, title: "Pause responses", subtitle: "Edit status, headers and body before the app receives them")
            }
        } header: {
            DonkSectionHeader("Breakpoint")
        } footer: {
            Text("Paused exchanges continue unchanged after \(DonkFormat.duration(BreakpointCenter.shared.timeout)) if nobody resolves them.")
        }
    }

    // MARK: - Helpers

    private func contentType(_ headers: [HeaderDraft]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    private func save() {
        guard draft.isValid else { return }
        RuleStore.shared.add(draft.makeRule())
        DonkHaptics.success()
        DonkToast.show(isNew ? "Rule added" : "Rule saved", icon: "wand.and.stars", tone: .success)
        dismiss()
    }

    private struct PreviewKey: Hashable {
        var kinds: Set<NetworkKind>
        var method: String
        var pattern: String
        var mode: URLMatcher.Mode
    }

    private var previewKey: PreviewKey {
        PreviewKey(kinds: draft.kinds, method: draft.method, pattern: draft.pattern, mode: draft.mode)
    }

    private func refreshPreview() async {
        guard draft.patternIssue == nil else {
            preview = MatchPreview()
            return
        }
        preview.isLoading = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let match = draft.match
        let result = await Task.detached(priority: .userInitiated) { () -> MatchPreview in
            var items: [NetworkRowItem] = []
            var count = 0
            for entry in NetworkStore.shared.snapshot() where match.matches(kind: entry.kind, method: entry.request.method, url: entry.request.url) {
                count += 1
                if items.count < 6 { items.append(NetworkRowItem(entry)) }
            }
            return MatchPreview(items: items, count: count, isLoading: false)
        }.value
        guard !Task.isCancelled else { return }
        preview = result
    }
}

struct MatchPreview: Equatable, Sendable {
    var items: [NetworkRowItem] = []
    var count = 0
    var isLoading = false
}

// MARK: - Sub-editors

struct IssueText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundColor(DonkColor.error)
    }
}

struct HeaderRowsEditor: View {
    @Binding var headers: [HeaderDraft]
    var addTitle = "Add Header"

    var body: some View {
        ForEach($headers) { $header in
            HStack(spacing: DonkSpacing.s) {
                TextField("Name", text: $header.name)
                    .font(DonkFont.code.weight(.semibold))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .frame(maxWidth: 140)
                Divider()
                TextField("Value", text: $header.value)
                    .font(DonkFont.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .onDelete { headers.remove(atOffsets: $0) }
        Button {
            withAnimation { headers.append(HeaderDraft()) }
        } label: {
            AddLabel(title: addTitle)
        }
    }
}

private struct NameRowsEditor: View {
    @Binding var names: [TextDraft]

    var body: some View {
        ForEach($names) { $name in
            TextField("Header name", text: $name.text)
                .font(DonkFont.code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
        .onDelete { names.remove(atOffsets: $0) }
        Button {
            withAnimation { names.append(TextDraft()) }
        } label: {
            AddLabel(title: "Remove Header…", icon: "minus.circle.fill", tone: .error)
        }
    }
}

private struct HeaderPatchSections: View {
    let title: String
    @Binding var patch: HeaderPatchDraft

    var body: some View {
        Section {
            HeaderRowsEditor(headers: $patch.set, addTitle: "Set Header")
        } header: {
            DonkSectionHeader("\(title) · set", count: patch.set.isEmpty ? nil : patch.set.count)
        } footer: {
            Text("Set replaces an existing header with the same name or adds it.")
        }
        Section {
            NameRowsEditor(names: $patch.remove)
        } header: {
            DonkSectionHeader("\(title) · remove", count: patch.remove.isEmpty ? nil : patch.remove.count)
        }
    }
}

private struct BodyPatchSection: View {
    let title: String
    @Binding var patch: BodyPatchDraft

    var body: some View {
        Section {
            Picker("Body", selection: $patch.mode) {
                ForEach(BodyPatchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            switch patch.mode {
            case .keep:
                EmptyView()
            case .replace:
                CodeEditor(text: $patch.replacement, language: CodeLanguage.detect(text: patch.replacement.isEmpty ? "{" : patch.replacement), placeholder: "New body")
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            case .findReplace:
                ForEach($patch.operations) { $operation in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Find", text: $operation.find)
                            .font(DonkFont.code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Divider()
                        TextField("Replace with", text: $operation.replace)
                            .font(DonkFont.code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Toggle("Regular expression", isOn: $operation.isRegex)
                            .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { patch.operations.remove(atOffsets: $0) }
                Button {
                    withAnimation { patch.operations.append(FindReplaceDraft()) }
                } label: {
                    AddLabel(title: "Add Replacement")
                }
            }
        } header: {
            DonkSectionHeader(title)
        } footer: {
            switch patch.mode {
            case .keep: Text("The body passes through unchanged.")
            case .replace: Text("The whole body is replaced. Prefix with base64: for binary data.")
            case .findReplace: Text("Replacements run in order on the UTF-8 body. Regex templates can use $1, $2…")
            }
        }
    }
}

struct AddLabel: View {
    let title: String
    var icon = "plus.circle.fill"
    var tone: DonkTone = .accent

    var body: some View {
        Label {
            Text(title)
                .foregroundColor(DonkColor.accent)
        } icon: {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(tone.color)
        }
    }
}

struct GRPCStatusPicker: View {
    let title: String
    @Binding var selection: Int
    let allowsKeep: Bool

    var body: some View {
        Picker(title, selection: $selection) {
            if allowsKeep {
                Text("Keep").tag(-1)
            }
            ForEach(RuleDraft.grpcCodes, id: \.self) { code in
                Text("\(code) · \(GRPCDetails.statusName(for: code))").tag(code)
            }
        }
    }
}
