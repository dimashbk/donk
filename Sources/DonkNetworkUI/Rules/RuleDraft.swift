import DonkCore
import DonkUI
import Foundation

// MARK: - Pieces

struct HeaderDraft: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""

    init(name: String = "", value: String = "") {
        self.name = name
        self.value = value
    }

    init(_ header: HTTPHeader) {
        self.init(name: header.name, value: header.value)
    }

    static func list(_ headers: [HTTPHeader]) -> [HeaderDraft] {
        headers.map(HeaderDraft.init)
    }

    static func headers(_ drafts: [HeaderDraft]) -> [HTTPHeader] {
        drafts.compactMap { draft in
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : HTTPHeader(name: name, value: draft.value)
        }
    }
}

struct TextDraft: Identifiable, Equatable {
    var id = UUID()
    var text = ""
}

struct FindReplaceDraft: Identifiable, Equatable {
    var id = UUID()
    var find = ""
    var replace = ""
    var isRegex = false
}

enum RuleActionKind: String, CaseIterable, Hashable {
    case mapLocal = "Map Local"
    case rewrite = "Rewrite"
    case breakpoint = "Breakpoint"

    var icon: String {
        switch self {
        case .mapLocal: return "doc.badge.gearshape"
        case .rewrite: return "pencil.circle"
        case .breakpoint: return "pause.circle"
        }
    }

    var tone: DonkTone {
        switch self {
        case .mapLocal: return .accent
        case .rewrite: return .warning
        case .breakpoint: return .info
        }
    }

    var explanation: String {
        switch self {
        case .mapLocal: return "Answer matching requests locally with the response below. The server is never contacted."
        case .rewrite: return "Let the request through, but change parts of the request and/or the response on the way."
        case .breakpoint: return "Pause matching exchanges so you can inspect and edit them before they continue."
        }
    }

    init(_ action: RuleAction) {
        switch action {
        case .mapLocal: self = .mapLocal
        case .rewrite: self = .rewrite
        case .breakpoint: self = .breakpoint
        }
    }
}

enum BodyPatchMode: String, CaseIterable, Hashable {
    case keep = "Keep"
    case replace = "Replace"
    case findReplace = "Find & Replace"
}

struct BodyPatchDraft: Equatable {
    var mode: BodyPatchMode = .keep
    var replacement = ""
    var operations: [FindReplaceDraft] = []

    init() {}

    init(_ patch: BodyPatch) {
        switch patch {
        case .keep:
            mode = .keep
        case let .replace(text):
            mode = .replace
            replacement = text
        case let .findReplace(items):
            mode = .findReplace
            operations = items.map { FindReplaceDraft(find: $0.find, replace: $0.replace, isRegex: $0.isRegex) }
        }
    }

    var patch: BodyPatch {
        switch mode {
        case .keep:
            return .keep
        case .replace:
            return .replace(replacement)
        case .findReplace:
            let items = operations.filter { !$0.find.isEmpty }.map { FindReplace(find: $0.find, replace: $0.replace, isRegex: $0.isRegex) }
            return items.isEmpty ? .keep : .findReplace(items)
        }
    }

    var invalidRegex: String? {
        guard mode == .findReplace else { return nil }
        for operation in operations where operation.isRegex && !operation.find.isEmpty {
            if (try? NSRegularExpression(pattern: operation.find)) == nil { return operation.find }
        }
        return nil
    }
}

struct HeaderPatchDraft: Equatable {
    var set: [HeaderDraft] = []
    var remove: [TextDraft] = []

    init() {}

    init(_ patch: HeaderPatch) {
        set = HeaderDraft.list(patch.set)
        remove = patch.remove.map { TextDraft(text: $0) }
    }

    var patch: HeaderPatch {
        HeaderPatch(
            set: HeaderDraft.headers(set),
            remove: remove.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
    }
}

// MARK: - Draft

struct RuleDraft: Identifiable, Equatable {
    static let methods = ["", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
    static let statusPresets = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 409, 422, 429, 500, 502, 503, 504]
    static let grpcCodes = Array(0...16)

    let id: UUID
    var createdAt = Date()
    var isEnabled = true
    var name = ""
    var http = true
    var grpc = false
    var method = ""
    var pattern = ""
    var mode: URLMatcher.Mode = .contains
    var action: RuleActionKind = .mapLocal

    var mockStatus = "200"
    var mockHeaders: [HeaderDraft] = [HeaderDraft(name: "Content-Type", value: "application/json")]
    var mockBody = ""
    var mockDelay: Double = 0
    var mockGRPCStatus = 0
    var mockGRPCMessage = ""
    var mockGRPCMessages: [TextDraft] = [TextDraft(text: "{}")]

    var rewritesRequest = true
    var rewriteURL = ""
    var rewriteMethod = ""
    var rewriteRequestHeaders = HeaderPatchDraft()
    var rewriteRequestBody = BodyPatchDraft()
    var rewritesResponse = false
    var rewriteStatus = ""
    var rewriteResponseHeaders = HeaderPatchDraft()
    var rewriteResponseBody = BodyPatchDraft()
    var rewriteGRPCStatus = -1
    var rewriteGRPCMessage = ""

    var breaksOnRequest = true
    var breaksOnResponse = false

    init(id: UUID = UUID()) {
        self.id = id
    }

    init(rule: NetworkRule) {
        self.init(id: rule.id)
        createdAt = rule.createdAt
        isEnabled = rule.isEnabled
        name = rule.name
        http = rule.match.kinds.isEmpty || rule.match.kinds.contains(.http)
        grpc = rule.match.kinds.isEmpty || rule.match.kinds.contains(.grpc)
        method = rule.match.method?.uppercased() ?? ""
        pattern = rule.match.url.pattern
        mode = rule.match.url.mode
        action = RuleActionKind(rule.action)
        switch rule.action {
        case let .mapLocal(mock):
            mockStatus = String(mock.statusCode)
            mockHeaders = HeaderDraft.list(mock.headers)
            mockBody = mock.body
            mockDelay = mock.delay
            mockGRPCStatus = mock.grpcStatusCode
            mockGRPCMessage = mock.grpcStatusMessage ?? ""
            mockGRPCMessages = mock.grpcMessages.map { TextDraft(text: $0) }
        case let .rewrite(request, response):
            rewritesRequest = request != nil
            if let request {
                rewriteURL = request.url ?? ""
                rewriteMethod = request.method?.uppercased() ?? ""
                rewriteRequestHeaders = HeaderPatchDraft(request.headers)
                rewriteRequestBody = BodyPatchDraft(request.body)
            }
            rewritesResponse = response != nil
            if let response {
                rewriteStatus = response.statusCode.map(String.init) ?? ""
                rewriteResponseHeaders = HeaderPatchDraft(response.headers)
                rewriteResponseBody = BodyPatchDraft(response.body)
                rewriteGRPCStatus = response.grpcStatusCode ?? -1
                rewriteGRPCMessage = response.grpcStatusMessage ?? ""
            }
        case let .breakpoint(request, response):
            breaksOnRequest = request
            breaksOnResponse = response
        }
    }

    init(entry: NetworkEntry) {
        self.init()
        let isGRPC = entry.kind == .grpc
        http = !isGRPC
        grpc = isGRPC
        method = isGRPC ? "" : entry.request.method.uppercased()
        pattern = EntryFormat.urlWithoutQuery(entry.request.url)
        mode = .contains
        action = .mapLocal
        if isGRPC {
            name = "Mock \(entry.title)"
        } else {
            let last = entry.request.path.split(separator: "/").last.map(String.init) ?? entry.host ?? "request"
            name = "\(entry.methodLabel) \(last)"
        }
        if let response = entry.response {
            if response.statusCode >= 100 { mockStatus = String(response.statusCode) }
            let skipped: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "date", "connection", "set-cookie"]
            let headers = response.headers.filter { !skipped.contains($0.name.lowercased()) }
            if !isGRPC {
                mockHeaders = headers.isEmpty ? mockHeaders : HeaderDraft.list(headers)
            }
            mockBody = Self.editableText(response.body)
        }
        if let details = entry.grpc {
            mockGRPCStatus = details.statusCode ?? 0
            mockGRPCMessage = details.statusMessage ?? ""
            let received = details.messages
                .filter { $0.direction == .received }
                .compactMap { $0.json.map { JSONFormatting.pretty($0) ?? $0 } }
            if !received.isEmpty {
                mockGRPCMessages = received.prefix(50).map { TextDraft(text: $0) }
            } else if !mockBody.isEmpty {
                mockGRPCMessages = [TextDraft(text: mockBody)]
            }
        }
    }

    static func editableText(_ body: BodyData?) -> String {
        guard let body, !body.data.isEmpty else { return "" }
        if let pretty = body.prettyJSON { return pretty }
        if let text = body.text { return text }
        return "base64:" + body.data.base64EncodedString()
    }

    // MARK: - Derived

    var kinds: Set<NetworkKind> {
        var result = Set<NetworkKind>()
        if http { result.insert(.http) }
        if grpc { result.insert(.grpc) }
        return result
    }

    var matcher: URLMatcher {
        URLMatcher(pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
    }

    var match: RuleMatch {
        RuleMatch(kinds: kinds, method: method.isEmpty ? nil : method, url: matcher)
    }

    var patternIssue: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a URL pattern" }
        if mode == .regex, !matcher.isValid { return "Invalid regular expression" }
        return nil
    }

    var actionIssue: String? {
        switch action {
        case .mapLocal:
            if http {
                guard let code = Int(mockStatus.trimmingCharacters(in: .whitespaces)), (100...599).contains(code) else {
                    return "Status must be a number from 100 to 599"
                }
            }
            return nil
        case .rewrite:
            if !rewritesRequest && !rewritesResponse { return "Turn on request or response rewriting" }
            if rewritesResponse {
                let status = rewriteStatus.trimmingCharacters(in: .whitespaces)
                if !status.isEmpty, Int(status).map({ (100...599).contains($0) }) != true {
                    return "Status override must be from 100 to 599"
                }
            }
            if let bad = rewriteRequestBody.invalidRegex ?? rewriteResponseBody.invalidRegex {
                return "Invalid regular expression: \(bad)"
            }
            return nil
        case .breakpoint:
            return breaksOnRequest || breaksOnResponse ? nil : "Pause the request, the response or both"
        }
    }

    var issue: String? {
        if !http && !grpc { return "Choose HTTP, gRPC or both" }
        return patternIssue ?? actionIssue
    }

    var isValid: Bool { issue == nil }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let base = pattern.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Untitled rule" : "\(action.rawValue) \(base)"
    }

    // MARK: - Build

    func makeRule() -> NetworkRule {
        NetworkRule(id: id, name: displayName, isEnabled: isEnabled, match: match, action: makeAction(), createdAt: createdAt)
    }

    private func makeAction() -> RuleAction {
        switch action {
        case .mapLocal:
            let mock = MockResponse(
                statusCode: Int(mockStatus.trimmingCharacters(in: .whitespaces)) ?? 200,
                headers: HeaderDraft.headers(mockHeaders),
                body: mockBody,
                delay: mockDelay,
                grpcStatusCode: mockGRPCStatus,
                grpcStatusMessage: mockGRPCMessage.isEmpty ? nil : mockGRPCMessage,
                grpcMessages: mockGRPCMessages.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            )
            return .mapLocal(mock)
        case .rewrite:
            let request: RequestRewrite? = rewritesRequest ? RequestRewrite(
                url: nilIfEmpty(rewriteURL),
                method: nilIfEmpty(rewriteMethod),
                headers: rewriteRequestHeaders.patch,
                body: rewriteRequestBody.patch
            ) : nil
            let response: ResponseRewrite? = rewritesResponse ? ResponseRewrite(
                statusCode: Int(rewriteStatus.trimmingCharacters(in: .whitespaces)),
                headers: rewriteResponseHeaders.patch,
                body: rewriteResponseBody.patch,
                grpcStatusCode: rewriteGRPCStatus >= 0 ? rewriteGRPCStatus : nil,
                grpcStatusMessage: rewriteGRPCStatus >= 0 ? nilIfEmpty(rewriteGRPCMessage) : nil
            ) : nil
            return .rewrite(request: request, response: response)
        case .breakpoint:
            return .breakpoint(request: breaksOnRequest, response: breaksOnResponse)
        }
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Rule summary

enum RuleSummary {
    static func actionKind(_ rule: NetworkRule) -> RuleActionKind {
        RuleActionKind(rule.action)
    }

    static func detail(_ rule: NetworkRule) -> String {
        switch rule.action {
        case let .mapLocal(mock):
            var parts: [String] = []
            if rule.match.kinds.contains(.http) || rule.match.kinds.isEmpty { parts.append("\(mock.statusCode)") }
            if rule.match.kinds.contains(.grpc) { parts.append(GRPCDetails.statusName(for: mock.grpcStatusCode)) }
            if mock.delay > 0 { parts.append("delay \(String(format: "%.1f", mock.delay)) s") }
            return parts.joined(separator: " · ")
        case let .rewrite(request, response):
            var parts: [String] = []
            if request != nil { parts.append("request") }
            if response != nil { parts.append("response") }
            return "Rewrites " + parts.joined(separator: " + ")
        case let .breakpoint(request, response):
            switch (request, response) {
            case (true, true): return "Pauses request + response"
            case (true, false): return "Pauses request"
            case (false, true): return "Pauses response"
            case (false, false): return "Does nothing"
            }
        }
    }
}
