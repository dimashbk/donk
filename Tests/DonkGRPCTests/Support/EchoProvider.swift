import Foundation
import GRPC
import NIOConcurrencyHelpers
import NIOHPACK
import SwiftProtobuf

final class EchoServerState: @unchecked Sendable {
    private let lock = NIOLock()
    private var calls: [String: Int] = [:]
    private var metadata: [String: String] = [:]
    private var requests: [Donk_Echo_V1_EchoRequest] = []

    func record(_ method: String, headers: HPACKHeaders, request: Donk_Echo_V1_EchoRequest? = nil) {
        lock.withLock {
            calls[method, default: 0] += 1
            for (name, value, _) in headers {
                metadata[name] = value
            }
            if let request { requests.append(request) }
        }
    }

    func append(_ request: Donk_Echo_V1_EchoRequest) {
        lock.withLock { requests.append(request) }
    }

    func calls(_ method: String) -> Int {
        lock.withLock { calls[method, default: 0] }
    }

    var totalCalls: Int {
        lock.withLock { calls.values.reduce(0, +) }
    }

    func header(_ name: String) -> String? {
        lock.withLock { metadata[name] }
    }

    var receivedTexts: [String] {
        lock.withLock { requests.map(\.text) }
    }
}

final class EchoProvider: Donk_Echo_V1_EchoAsyncProvider {
    let state: EchoServerState

    init(state: EchoServerState) {
        self.state = state
    }

    func get(request: Donk_Echo_V1_EchoRequest, context: GRPCAsyncServerCallContext) async throws -> Donk_Echo_V1_EchoResponse {
        state.record("Get", headers: context.request.headers, request: request)
        try await context.response.setHeaders(["x-server": "donk-echo"])
        try await context.response.setTrailers(["x-trailer": "done"])
        if let status = Self.status(from: request.text) { throw status }
        if request.text.hasPrefix("sleep:"), let millis = UInt64(request.text.dropFirst(6)) {
            try await Task.sleep(nanoseconds: millis * 1_000_000)
        }
        var response = Donk_Echo_V1_EchoResponse()
        response.text = "echo: " + request.text
        response.mood = request.mood
        response.payload = request.payload
        switch request.text {
        case "any:registered":
            var detail = Donk_Echo_V1_RegisteredDetail()
            detail.note = "visible"
            response.detail = try Google_Protobuf_Any(message: detail)
        case "any:unregistered":
            var detail = Donk_Echo_V1_UnregisteredDetail()
            detail.secret = "hidden-value"
            response.detail = try Google_Protobuf_Any(message: detail)
        default:
            break
        }
        return response
    }

    func expand(
        request: Donk_Echo_V1_EchoRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Donk_Echo_V1_EchoResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        state.record("Expand", headers: context.request.headers, request: request)
        try await context.response.setTrailers(["x-trailer": "expanded"])
        let count = request.repeatCount > 0 ? Int(request.repeatCount) : 3
        for index in 0..<count {
            if index > 0, request.intervalMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(request.intervalMs) * 1_000_000)
            }
            var response = Donk_Echo_V1_EchoResponse()
            response.text = "\(request.text) \(index)"
            response.index = Int32(index)
            try await responseStream.send(response)
        }
        if let status = Self.status(from: request.text) { throw status }
    }

    func collect(
        requestStream: GRPCAsyncRequestStream<Donk_Echo_V1_EchoRequest>,
        context: GRPCAsyncServerCallContext
    ) async throws -> Donk_Echo_V1_EchoResponse {
        state.record("Collect", headers: context.request.headers)
        var texts: [String] = []
        for try await request in requestStream {
            state.append(request)
            texts.append(request.text)
        }
        var response = Donk_Echo_V1_EchoResponse()
        response.text = texts.joined(separator: " ")
        response.index = Int32(texts.count)
        return response
    }

    func update(
        requestStream: GRPCAsyncRequestStream<Donk_Echo_V1_EchoRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<Donk_Echo_V1_EchoResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        state.record("Update", headers: context.request.headers)
        var index: Int32 = 0
        for try await request in requestStream {
            state.append(request)
            var response = Donk_Echo_V1_EchoResponse()
            response.text = "echo: " + request.text
            response.index = index
            index += 1
            try await responseStream.send(response)
        }
    }

    private static func status(from text: String) -> GRPCStatus? {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "status", let code = Int(parts[1]), let statusCode = GRPCStatus.Code(rawValue: code) else {
            return nil
        }
        return GRPCStatus(code: statusCode, message: String(parts[2]))
    }
}
