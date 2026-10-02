import DonkGRPC
import Foundation
import GRPC
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftProtobuf

typealias EchoRequest = Donk_Echo_V1_EchoRequest
typealias EchoResponse = Donk_Echo_V1_EchoResponse

struct DemoEchoInterceptors: Donk_Echo_V1_EchoClientInterceptorFactoryProtocol {
    typealias Interceptors = [ClientInterceptor<EchoRequest, EchoResponse>]

    let host: String
    let options: DonkGRPCOptions

    func makeGetInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeExpandInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeCollectInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeUpdateInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
}

struct DemoHelloInterceptors: Hello_HelloServiceClientInterceptorFactoryProtocol {
    typealias Interceptors = [ClientInterceptor<Hello_HelloRequest, Hello_HelloResponse>]

    let host: String
    let options: DonkGRPCOptions

    func makeSayHelloInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeLotsOfRepliesInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeLotsOfGreetingsInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeBidiHelloInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
}

final class GRPCDemoBackend: @unchecked Sendable {
    static let shared = GRPCDemoBackend()
    static let publicHost = "grpcb.in"
    static let publicPort = 9000

    let options = DonkGRPCOptions(anyTypeRegistry: [Donk_Echo_V1_RegisteredDetail.self])

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let lock = NIOLock()
    private var startup: EventLoopFuture<Int>?
    private var server: Server?
    private var echoClient: Donk_Echo_V1_EchoNIOClient?
    private var helloClient: Hello_HelloServiceNIOClient?

    func start() -> EventLoopFuture<Int> {
        lock.withLock {
            if let startup { return startup }
            let future = Server.insecure(group: group)
                .withServiceProviders([DemoEchoProvider()])
                .bind(host: "127.0.0.1", port: 0)
                .flatMapThrowing { [self] server -> Int in
                    guard let port = server.channel.localAddress?.port else {
                        throw GRPCStatus(code: .unavailable, message: "Echo server has no port")
                    }
                    lock.withLock {
                        self.server = server
                        let connection = ClientConnection.insecure(group: group).connect(host: "127.0.0.1", port: port)
                        echoClient = Donk_Echo_V1_EchoNIOClient(
                            channel: connection,
                            defaultCallOptions: CallOptions(timeLimit: .timeout(.minutes(5))),
                            interceptors: DemoEchoInterceptors(host: "127.0.0.1:\(port)", options: options)
                        )
                    }
                    return port
                }
            future.whenFailure { [self] _ in
                lock.withLock { startup = nil }
            }
            startup = future
            return future
        }
    }

    var echo: Donk_Echo_V1_EchoNIOClient? {
        lock.withLock { echoClient }
    }

    var hello: Hello_HelloServiceNIOClient {
        lock.withLock {
            if let helloClient { return helloClient }
            let connection = ClientConnection.insecure(group: group)
                .withConnectionBackoff(retries: .upTo(1))
                .connect(host: Self.publicHost, port: Self.publicPort)
            let client = Hello_HelloServiceNIOClient(
                channel: connection,
                defaultCallOptions: CallOptions(timeLimit: .timeout(.seconds(10))),
                interceptors: DemoHelloInterceptors(host: "\(Self.publicHost):\(Self.publicPort)", options: options)
            )
            helloClient = client
            return client
        }
    }
}

final class DemoEchoProvider: Donk_Echo_V1_EchoAsyncProvider {
    func get(request: EchoRequest, context: GRPCAsyncServerCallContext) async throws -> EchoResponse {
        try await context.response.setHeaders(["x-server": "donk-demo-echo"])
        try await context.response.setTrailers(["x-served-at": ISO8601DateFormatter().string(from: Date())])
        if let status = Self.status(from: request.text) { throw status }
        if request.text.hasPrefix("sleep:"), let millis = UInt64(request.text.dropFirst(6)) {
            try await Task.sleep(nanoseconds: millis * 1_000_000)
        }
        var response = EchoResponse()
        response.text = "echo: " + request.text
        response.mood = request.mood == .unspecified ? .happy : request.mood
        var detail = Donk_Echo_V1_RegisteredDetail()
        detail.note = "Served by the in-app echo server"
        response.detail = try Google_Protobuf_Any(message: detail)
        return response
    }

    func expand(
        request: EchoRequest,
        responseStream: GRPCAsyncResponseStreamWriter<EchoResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        try await context.response.setTrailers(["x-stream-length": "\(max(1, request.repeatCount))"])
        let count = max(1, Int(request.repeatCount))
        for index in 0..<count {
            if index > 0, request.intervalMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(request.intervalMs) * 1_000_000)
            }
            var response = EchoResponse()
            response.text = "\(request.text) #\(index + 1)"
            response.index = Int32(index)
            response.mood = index.isMultiple(of: 2) ? .happy : .grumpy
            try await responseStream.send(response)
        }
    }

    func collect(
        requestStream: GRPCAsyncRequestStream<EchoRequest>,
        context: GRPCAsyncServerCallContext
    ) async throws -> EchoResponse {
        var texts: [String] = []
        for try await request in requestStream {
            texts.append(request.text)
        }
        var response = EchoResponse()
        response.text = texts.joined(separator: " ")
        response.index = Int32(texts.count)
        return response
    }

    func update(
        requestStream: GRPCAsyncRequestStream<EchoRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<EchoResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        var index: Int32 = 0
        for try await request in requestStream {
            var response = EchoResponse()
            response.text = Self.reply(to: request.text)
            response.index = index
            index += 1
            try await responseStream.send(response)
        }
    }

    private static func reply(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("hi") || trimmed.lowercased().hasPrefix("hello") {
            return "Hey! I'm the echo server. Everything you send shows up in donk."
        }
        return "You said “\(trimmed)” (\(trimmed.count) chars)"
    }

    private static func status(from text: String) -> GRPCStatus? {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "status", let code = Int(parts[1]), let statusCode = GRPCStatus.Code(rawValue: code) else {
            return nil
        }
        return GRPCStatus(code: statusCode, message: String(parts[2]))
    }
}
