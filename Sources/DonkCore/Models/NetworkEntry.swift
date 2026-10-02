import Foundation

public struct NetworkEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: NetworkKind
    public var state: NetworkState
    public var origin: NetworkOrigin
    public var request: RequestSnapshot
    public var response: ResponseSnapshot?
    public var error: NetworkErrorInfo?
    public var timing: NetworkTiming
    public var grpc: GRPCDetails?
    public var web: WebViewDetails?
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        kind: NetworkKind = .http,
        state: NetworkState = .pending,
        origin: NetworkOrigin = .network,
        request: RequestSnapshot,
        response: ResponseSnapshot? = nil,
        error: NetworkErrorInfo? = nil,
        timing: NetworkTiming = NetworkTiming(),
        grpc: GRPCDetails? = nil,
        web: WebViewDetails? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.origin = origin
        self.request = request
        self.response = response
        self.error = error
        self.timing = timing
        self.grpc = grpc
        self.web = web
        self.isPinned = isPinned
    }

    public var host: String? { request.host }

    public var path: String {
        if kind == .grpc, let grpc, !grpc.path.isEmpty { return grpc.path }
        return request.path
    }

    public var title: String {
        if kind == .grpc, let grpc, !grpc.method.isEmpty {
            let service = grpc.service.split(separator: ".").last.map(String.init) ?? grpc.service
            return service.isEmpty ? grpc.method : "\(service)/\(grpc.method)"
        }
        return path
    }

    public var methodLabel: String {
        switch kind {
        case .grpc:
            return (grpc?.callType ?? .unary).label
        case .http, .webView:
            let method = request.method.trimmingCharacters(in: .whitespaces).uppercased()
            return method.isEmpty ? "GET" : method
        }
    }

    public var statusLabel: String {
        switch kind {
        case .grpc:
            if let name = grpc?.statusName { return name }
            if state.isInFlight { return "…" }
            if state == .cancelled { return "CANCELLED" }
            if state == .failed || error != nil { return "ERR" }
            return "…"
        case .http, .webView:
            if let code = finalStatusCode { return String(code) }
            if state.isInFlight { return "…" }
            if state == .failed || state == .cancelled || error != nil { return "ERR" }
            if let code = response?.statusCode, code > 0 { return String(code) }
            return "—"
        }
    }

    public var statusCategory: StatusCategory {
        switch kind {
        case .grpc:
            if let code = grpc?.statusCode {
                if code == 0 { return .success }
                return GRPCDetails.isClientError(code) ? .clientError : .serverError
            }
            if state.isInFlight { return .pending }
            if state == .failed || state == .cancelled || error != nil { return .failure }
            return .success
        case .http, .webView:
            if let code = finalStatusCode { return Self.category(forHTTPStatus: code) }
            if state.isInFlight { return .pending }
            if state == .failed || state == .cancelled || error != nil { return .failure }
            return .success
        }
    }

    public var requestSize: Int {
        if kind == .grpc, let grpc {
            let visible = grpc.messages.reduce(0) { $1.direction == .sent ? $0 + $1.size : $0 }
            return max(grpc.sentBytes, visible)
        }
        return request.body?.originalSize ?? 0
    }

    public var responseSize: Int {
        if kind == .grpc, let grpc {
            let visible = grpc.messages.reduce(0) { $1.direction == .received ? $0 + $1.size : $0 }
            return max(grpc.receivedBytes, visible)
        }
        return response?.body?.originalSize ?? 0
    }

    public var duration: TimeInterval? { timing.duration }

    private var finalStatusCode: Int? {
        guard let code = response?.statusCode, code >= 200 else { return nil }
        return code
    }

    static func category(forHTTPStatus code: Int) -> StatusCategory {
        switch code {
        case 200..<300: return .success
        case 300..<400: return .redirect
        case 400..<500: return .clientError
        default: return .serverError
        }
    }
}
