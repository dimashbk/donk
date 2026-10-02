import DonkCore
import Foundation
import GRPC
import NIOCore
import NIOHPACK
import SwiftProtobuf

// MARK: - Headers

extension HPACKHeaders {
    var donkHeaders: [HTTPHeader] {
        var result: [HTTPHeader] = []
        result.reserveCapacity(count)
        for (name, value, _) in self where !name.hasPrefix(":") {
            result.append(HTTPHeader(name: name, value: value))
        }
        return result
    }

    init(donkHeaders headers: [HTTPHeader], preservingPseudoHeadersOf original: HPACKHeaders? = nil) {
        var pairs: [(String, String)] = []
        if let original {
            for (name, value, _) in original where name.hasPrefix(":") {
                pairs.append((name, value))
            }
        }
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.hasPrefix(":") else { continue }
            pairs.append((name, header.value))
        }
        self.init(pairs)
    }
}

// MARK: - Status

extension GRPCStatus {
    init(donkCode code: Int, message: String?) {
        self.init(code: GRPCStatus.Code(rawValue: code) ?? .unknown, message: message)
    }

    static func donkStatus(for error: Error) -> GRPCStatus {
        if let status = error as? GRPCStatus { return status }
        if let transformable = error as? GRPCStatusTransformable { return transformable.makeGRPCStatus() }
        return GRPCStatus(code: .unknown, message: String(describing: error))
    }

    static let donkAborted = GRPCStatus(code: .cancelled, message: "donk: aborted at breakpoint")

    func applying(_ rewrite: ResponseRewrite?) -> GRPCStatus {
        guard let rewrite else { return self }
        if let code = rewrite.grpcStatusCode {
            return GRPCStatus(donkCode: code, message: rewrite.grpcStatusMessage)
        }
        if let message = rewrite.grpcStatusMessage {
            return GRPCStatus(code: code, message: message)
        }
        return self
    }
}

struct GRPCFailure: Error, CustomNSError, LocalizedError {
    static var errorDomain: String { "gRPC" }

    var code: Int
    var message: String?

    init(status: GRPCStatus) {
        code = status.code.rawValue
        message = status.message
    }

    var errorCode: Int { code }

    var errorDescription: String? {
        let name = GRPCDetails.statusName(for: code)
        guard let message, !message.isEmpty else { return name }
        return "\(name): \(message)"
    }

    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? ""]
    }
}

extension Error {
    var isDonkDeadline: Bool {
        if self is GRPCError.RPCTimedOut { return true }
        return GRPCStatus.donkStatus(for: self).code == .deadlineExceeded
    }
}

// MARK: - Call details

extension TimeLimit {
    var donkSeconds: TimeInterval? {
        if let timeout, timeout.nanoseconds != .max {
            return Double(timeout.nanoseconds) / 1_000_000_000
        }
        if let deadline, deadline != .distantFuture {
            let now = NIODeadline.now()
            guard deadline > now else { return 0 }
            return Double((deadline - now).nanoseconds) / 1_000_000_000
        }
        return nil
    }
}

enum GRPCCallTarget {
    static func path(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }

    static func host(_ host: String?) -> String? {
        guard var host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        for scheme in ["grpc://", "grpcs://", "https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
            break
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func url(host: String?, path: String) -> String {
        "grpc://\(self.host(host) ?? "grpc")\(self.path(path))"
    }

    static func hostWithoutPort(_ host: String?) -> String? {
        guard let host = self.host(host) else { return nil }
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<end])
        }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, Int(parts[1]) != nil { return String(parts[0]) }
        return host
    }
}

// MARK: - Plan

struct GRPCCallPlan: Sendable {
    var mock: MockResponse?
    var requestRewrite: RequestRewrite?
    var responseRewrite: ResponseRewrite?
    var transformRuleName: String?
    var breakpointRuleName: String?
    var breaksOnRequest = false
    var breaksOnResponse = false

    static let none = GRPCCallPlan()

    init() {}

    init(_ resolution: RuleResolution) {
        if let rule = resolution.transform {
            switch rule.action {
            case let .mapLocal(mock):
                self.mock = mock
                transformRuleName = rule.name
            case let .rewrite(request, response):
                requestRewrite = request
                responseRewrite = response
                transformRuleName = rule.name
            case .breakpoint:
                break
            }
        }
        if let rule = resolution.breakpoint, case let .breakpoint(request, response) = rule.action {
            breakpointRuleName = rule.name
            breaksOnRequest = request
            breaksOnResponse = response
        }
    }

    mutating func removeBreakpoints() {
        breakpointRuleName = nil
        breaksOnRequest = false
        breaksOnResponse = false
    }

    var requestBodyPatch: BodyPatch? {
        guard let body = requestRewrite?.body, body != .keep else { return nil }
        return body
    }

    var responseBodyPatch: BodyPatch? {
        guard let body = responseRewrite?.body, body != .keep else { return nil }
        return body
    }

    var requestHeaderPatch: HeaderPatch? {
        guard let headers = requestRewrite?.headers, !headers.isEmpty else { return nil }
        return headers
    }

    var responseHeaderPatch: HeaderPatch? {
        guard let headers = responseRewrite?.headers, !headers.isEmpty else { return nil }
        return headers
    }
}

// MARK: - Local responses

struct GRPCLocalResponse<Response: SwiftProtobuf.Message>: Sendable {
    var headers: [HTTPHeader]
    var messages: [Response]
    var status: GRPCStatus
    var delay: TimeInterval
    var allowsResponseBreakpoint: Bool

    init(mock: MockResponse, renderer: GRPCMessageRenderer) {
        headers = mock.headers
        delay = max(0, mock.delay)
        allowsResponseBreakpoint = true
        do {
            messages = try renderer.decodeJSONList(Response.self, mock.grpcMessages)
            status = GRPCStatus(donkCode: mock.grpcStatusCode, message: mock.grpcStatusMessage)
        } catch {
            messages = []
            status = GRPCStatus(code: .internalError, message: "donk: invalid mock JSON")
        }
    }

    init(editable response: EditableResponse, renderer: GRPCMessageRenderer) {
        headers = response.headers
        delay = 0
        allowsResponseBreakpoint = false
        do {
            messages = try renderer.decodeMany(Response.self, from: GRPCEditableBody(text: response.body, isBinary: response.bodyIsBinary))
            status = GRPCStatus(donkCode: response.grpcStatusCode ?? 0, message: response.grpcStatusMessage)
        } catch {
            messages = []
            status = GRPCStatus(code: .internalError, message: "donk: invalid breakpoint response JSON")
        }
    }

    func parts() -> [GRPCClientResponsePart<Response>] {
        var parts: [GRPCClientResponsePart<Response>] = []
        if !headers.isEmpty || !messages.isEmpty {
            parts.append(.metadata(HPACKHeaders(donkHeaders: headers)))
        }
        parts.append(contentsOf: messages.map { .message($0) })
        parts.append(.end(status, [:]))
        return parts
    }
}
