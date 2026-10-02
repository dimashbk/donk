import Combine
import DonkCore
import DonkUI
import SwiftUI

// MARK: - Queue

@MainActor
final class BreakpointQueueModel: ObservableObject {
    @Published private(set) var pending: [PausedExchange] = []
    private var cancellable: AnyCancellable?

    init(center: BreakpointCenter = .shared) {
        pending = center.pending
        cancellable = center.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.pending = value
            }
    }

    func position(of id: UUID) -> Int? {
        pending.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}

// MARK: - Drafts

struct RequestEdit: Equatable {
    var method: String
    var url: String
    var headers: [HeaderDraft]
    var body: String
    var bodyIsBinary: Bool

    init(_ request: EditableRequest) {
        method = request.method.uppercased()
        url = request.url
        headers = HeaderDraft.list(request.headers)
        body = BreakpointView.prettified(request.body, binary: request.bodyIsBinary)
        bodyIsBinary = request.bodyIsBinary
    }

    var editable: EditableRequest {
        EditableRequest(url: url.trimmingCharacters(in: .whitespacesAndNewlines), method: method, headers: HeaderDraft.headers(headers), body: body, bodyIsBinary: bodyIsBinary)
    }
}

struct ResponseEdit: Equatable {
    var status: String
    var headers: [HeaderDraft]
    var body: String
    var bodyIsBinary: Bool
    var grpcStatus: Int
    var grpcMessage: String

    init(_ response: EditableResponse) {
        status = String(response.statusCode)
        headers = HeaderDraft.list(response.headers)
        body = BreakpointView.prettified(response.body, binary: response.bodyIsBinary)
        bodyIsBinary = response.bodyIsBinary
        grpcStatus = response.grpcStatusCode ?? 0
        grpcMessage = response.grpcStatusMessage ?? ""
    }

    func editable(isGRPC: Bool) -> EditableResponse {
        EditableResponse(
            statusCode: Int(status.trimmingCharacters(in: .whitespaces)) ?? 200,
            headers: HeaderDraft.headers(headers),
            body: body,
            bodyIsBinary: bodyIsBinary,
            grpcStatusCode: isGRPC ? grpcStatus : nil,
            grpcStatusMessage: isGRPC && !grpcMessage.isEmpty ? grpcMessage : nil
        )
    }

    var isStatusValid: Bool {
        Int(status.trimmingCharacters(in: .whitespaces)).map { (100...599).contains($0) } ?? false
    }
}

// MARK: - View

struct BreakpointView: View {
    let exchange: PausedExchange
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue = BreakpointQueueModel()
    @State private var request: RequestEdit
    @State private var response: ResponseEdit
    @State private var executesLocally = false
    @State private var isResolved = false
    private let originalRequest: RequestEdit?
    private let originalResponse: ResponseEdit?

    init(exchange: PausedExchange) {
        self.exchange = exchange
        switch exchange.payload {
        case let .request(value):
            let edit = RequestEdit(value)
            _request = State(initialValue: edit)
            _response = State(initialValue: ResponseEdit(EditableResponse()))
            originalRequest = edit
            originalResponse = nil
        case let .response(value):
            let edit = ResponseEdit(value)
            _request = State(initialValue: RequestEdit(EditableRequest(url: "")))
            _response = State(initialValue: edit)
            originalRequest = nil
            originalResponse = edit
        }
    }

    private var isGRPC: Bool { exchange.kind == .grpc }
    private var editsResponse: Bool { exchange.phase == .response || executesLocally }
    private var isPending: Bool { queue.position(of: exchange.id) != nil }

    var body: some View {
        VStack(spacing: 0) {
            form
            actionBar
        }
        .donkScreenBackground()
        .donkNavigationTitle(isGRPC ? "gRPC Breakpoint" : "Breakpoint")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Later") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEdited {
                    Button("Revert") {
                        DonkHaptics.light()
                        revert()
                    }
                }
            }
        }
        .donkTheme()
    }

    private var form: some View {
        Form {
            headerSection
            if !isPending && !isResolved {
                Section {
                    NoticeBanner(icon: "play.circle", text: "This exchange already continued — it was resolved elsewhere or timed out.", tone: .neutral)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            if editsResponse {
                responseSections
            } else {
                requestSections
            }
        }
        .donkListStyle()
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DonkSpacing.m) {
                HStack(alignment: .center, spacing: DonkSpacing.m) {
                    DonkIconBadge(exchange.phase == .request ? "arrow.up.circle.fill" : "arrow.down.circle.fill", tone: .warning, size: 42, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            TonePill(text: phaseTitle, tone: .warning, icon: "pause.fill")
                            TonePill(text: EntryStyle.kindTitle(exchange.kind), tone: EntryStyle.kindTone(exchange.kind), icon: EntryStyle.kindIcon(exchange.kind))
                        }
                        Text("Rule “\(exchange.ruleName)”")
                            .font(.footnote)
                            .foregroundColor(DonkColor.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let position = queue.position(of: exchange.id), queue.pending.count > 1 {
                        VStack(spacing: 0) {
                            Text("\(position)/\(queue.pending.count)")
                                .font(DonkFont.metricSmall)
                            Text("queued")
                                .font(.caption2)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                }
                HStack(spacing: 6) {
                    MethodBadge(isGRPC ? "GRPC" : (exchange.phase == .request ? request.method : originalMethod))
                    Text(DonkTextBreaking.breakable(targetURL))
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Countdown(createdAt: exchange.createdAt, timeout: BreakpointCenter.shared.timeout, isActive: isPending)
            }
            .padding(DonkSpacing.l)
            .background(
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .fill(DonkColor.card)
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var phaseTitle: String {
        if executesLocally { return "Answering locally" }
        return exchange.phase == .request ? "Request paused" : "Response paused"
    }

    private var targetURL: String {
        if exchange.phase == .request { return request.url }
        return NetworkStore.shared.entry(exchange.entryID)?.request.url ?? "Response"
    }

    private var originalMethod: String {
        NetworkStore.shared.entry(exchange.entryID)?.request.method ?? "GET"
    }

    // MARK: - Request editor

    @ViewBuilder
    private var requestSections: some View {
        Section {
            if !isGRPC {
                Picker("Method", selection: $request.method) {
                    ForEach(Array(Set(RuleDraft.methods.filter { !$0.isEmpty } + [request.method])).sorted(), id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
            }
            TextField("URL", text: $request.url)
                .font(DonkFont.code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .disabled(isGRPC)
        } header: {
            DonkSectionHeader(isGRPC ? "Call" : "Request", icon: "arrow.up.circle")
        } footer: {
            if isGRPC {
                Text("The method path of a gRPC call cannot be changed.")
            } else if URL(string: request.url.trimmingCharacters(in: .whitespaces)) == nil {
                IssueText("Invalid URL")
            }
        }
        Section {
            HeaderRowsEditor(headers: $request.headers, addTitle: isGRPC ? "Add Metadata" : "Add Header")
        } header: {
            DonkSectionHeader(isGRPC ? "Metadata" : "Headers", count: request.headers.count)
        }
        bodySection(text: $request.body, isBinary: request.bodyIsBinary, contentType: contentType(request.headers), title: isGRPC ? "Message" : "Body", placeholder: isGRPC ? "{ }" : "Request body")
    }

    // MARK: - Response editor

    @ViewBuilder
    private var responseSections: some View {
        Section {
            if isGRPC {
                GRPCStatusPicker(title: "Status", selection: $response.grpcStatus, allowsKeep: false)
                TextField("Status message (optional)", text: $response.grpcMessage)
            } else {
                HStack(spacing: DonkSpacing.s) {
                    Text("Status")
                    Spacer(minLength: DonkSpacing.s)
                    TextField("200", text: $response.status)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 80)
                    Menu {
                        ForEach(RuleDraft.statusPresets, id: \.self) { code in
                            Button("\(code) \(ResponseSnapshot.reasonPhrase(for: code))") {
                                response.status = String(code)
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Status presets")
                }
            }
        } header: {
            DonkSectionHeader(executesLocally ? "Local response" : "Response", icon: "arrow.down.circle")
        } footer: {
            if executesLocally {
                Text("This response is delivered to the app without contacting the server.")
            } else if !isGRPC && !response.isStatusValid {
                IssueText("Status must be from 100 to 599")
            } else if !isGRPC, let code = Int(response.status), !ResponseSnapshot.reasonPhrase(for: code).isEmpty {
                Text("\(code) \(ResponseSnapshot.reasonPhrase(for: code))")
            }
        }
        Section {
            HeaderRowsEditor(headers: $response.headers, addTitle: isGRPC ? "Add Metadata" : "Add Header")
        } header: {
            DonkSectionHeader("Headers", count: response.headers.count)
        }
        bodySection(text: $response.body, isBinary: response.bodyIsBinary, contentType: contentType(response.headers), title: isGRPC ? "Message" : "Body", placeholder: isGRPC ? "{ }" : "Response body")
    }

    private func contentType(_ headers: [HeaderDraft]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    @ViewBuilder
    private func bodySection(text: Binding<String>, isBinary: Bool, contentType: String?, title: String, placeholder: String) -> some View {
        Section {
            if isBinary {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    TonePill(text: "Binary · base64", tone: .neutral, icon: "cube.box")
                    Text(String(text.wrappedValue.prefix(600)) + (text.wrappedValue.count > 600 ? "…" : ""))
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(8)
                }
                .padding(.vertical, 4)
            } else {
                CodeEditor(
                    text: text,
                    language: isGRPC ? .json : CodeLanguage.detect(contentType: contentType, text: text.wrappedValue.isEmpty ? nil : text.wrappedValue),
                    placeholder: placeholder
                )
                .frame(height: 280)
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        } header: {
            DonkSectionHeader(title)
        } footer: {
            if isBinary {
                Text("Binary bodies pass through unchanged.")
            } else if isGRPC {
                Text("JSON of the message. For streams, a JSON array holds one element per message.")
            }
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: DonkSpacing.s) {
            Button(action: continueExchange) {
                Label(executesLocally ? "Send Response" : (isEdited ? "Continue with Changes" : "Continue"), systemImage: executesLocally ? "paperplane.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canContinue)
            HStack(spacing: DonkSpacing.s) {
                if exchange.phase == .request {
                    Button {
                        DonkHaptics.selection()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if executesLocally {
                                executesLocally = false
                            } else {
                                response = ResponseEdit(localTemplate)
                                executesLocally = true
                            }
                        }
                    } label: {
                        Label(executesLocally ? "Edit Request" : "Execute Locally", systemImage: executesLocally ? "arrow.uturn.backward" : "bolt.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                Button(role: .destructive, action: abort) {
                    Label("Abort", systemImage: "xmark.octagon.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(DonkColor.error)
            }
            .disabled(!isPending)
        }
        .padding(.horizontal, DonkSpacing.l)
        .padding(.top, DonkSpacing.m)
        .padding(.bottom, DonkSpacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var localTemplate: EditableResponse {
        if isGRPC {
            return EditableResponse(statusCode: 200, headers: [], body: "", grpcStatusCode: 0, grpcStatusMessage: nil)
        }
        return EditableResponse(statusCode: 200, headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: "")
    }

    private var canContinue: Bool {
        guard isPending else { return false }
        if editsResponse { return isGRPC || response.isStatusValid }
        return isGRPC || URL(string: request.url.trimmingCharacters(in: .whitespaces)) != nil
    }

    private var isEdited: Bool {
        if executesLocally { return false }
        if let originalRequest, exchange.phase == .request { return originalRequest != request }
        if let originalResponse, exchange.phase == .response { return originalResponse != response }
        return false
    }

    private func revert() {
        if let originalRequest { request = originalRequest }
        if let originalResponse { response = originalResponse }
    }

    private func continueExchange() {
        let decision: BreakpointDecision
        if executesLocally {
            decision = .respond(response.editable(isGRPC: isGRPC))
        } else if exchange.phase == .request {
            decision = .resume(.request(isEdited ? request.editable : unchangedRequest))
        } else {
            decision = .resume(.response(isEdited ? response.editable(isGRPC: isGRPC) : unchangedResponse))
        }
        resolve(decision, message: executesLocally ? "Answered locally" : "Continued", tone: .success)
    }

    private var unchangedRequest: EditableRequest {
        if case let .request(value) = exchange.payload { return value }
        return request.editable
    }

    private var unchangedResponse: EditableResponse {
        if case let .response(value) = exchange.payload { return value }
        return response.editable(isGRPC: isGRPC)
    }

    private func abort() {
        resolve(.abort, message: "Aborted", tone: .error)
    }

    private func resolve(_ decision: BreakpointDecision, message: String, tone: DonkTone) {
        guard isPending else { return }
        isResolved = true
        BreakpointCenter.shared.resolve(exchange.id, with: decision)
        if tone == .error {
            DonkHaptics.warning()
        } else {
            DonkHaptics.success()
        }
        DonkToast.show(message, icon: tone == .error ? "xmark.octagon.fill" : "play.fill", tone: tone, duration: 1.5)
        dismiss()
    }

    static func prettified(_ text: String, binary: Bool) -> String {
        guard !binary, !text.isEmpty, text.utf8.count <= 512 * 1024 else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return text }
        return JSONFormatting.pretty(text) ?? text
    }
}

// MARK: - Countdown

private struct Countdown: View {
    let createdAt: Date
    let timeout: TimeInterval
    let isActive: Bool

    var body: some View {
        if timeout > 0, timeout.isFinite, isActive {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                let remaining = max(0, timeout - context.date.timeIntervalSince(createdAt))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                            .font(.caption.weight(.semibold))
                        Text("Auto-continues unchanged in \(Self.format(remaining))")
                            .font(.caption.weight(.medium).monospacedDigit())
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(remaining < 30 ? DonkColor.error : DonkColor.textSecondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DonkColor.fill)
                            Capsule()
                                .fill(remaining < 30 ? DonkColor.error : DonkColor.warning)
                                .frame(width: proxy.size.width * CGFloat(remaining / timeout))
                        }
                    }
                    .frame(height: 4)
                    .animation(.linear(duration: 1), value: remaining)
                }
            }
        } else if isActive {
            Label("Waiting until you decide", systemImage: "infinity")
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
