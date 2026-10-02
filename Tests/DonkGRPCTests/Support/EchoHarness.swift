import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import NIOCore
import NIOPosix
import XCTest

struct EchoInterceptors: Donk_Echo_V1_EchoClientInterceptorFactoryProtocol {
    typealias Interceptors = [ClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>]

    let host: String
    let options: DonkGRPCOptions

    func makeGetInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeExpandInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeCollectInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
    func makeUpdateInterceptors() -> Interceptors { DonkGRPC.interceptors(host: host, options: options) }
}

final class RecordingEchoInterceptors: Donk_Echo_V1_EchoClientInterceptorFactoryProtocol {
    typealias Interceptor = DonkClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>
    typealias Interceptors = [ClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>]

    let host: String
    let options: DonkGRPCOptions
    let created = Collector<Interceptor>()

    init(host: String, options: DonkGRPCOptions) {
        self.host = host
        self.options = options
    }

    var last: Interceptor? { created.values.last }

    func makeGetInterceptors() -> Interceptors { make() }
    func makeExpandInterceptors() -> Interceptors { make() }
    func makeCollectInterceptors() -> Interceptors { make() }
    func makeUpdateInterceptors() -> Interceptors { make() }

    private func make() -> Interceptors {
        let interceptor = Interceptor(host: host, options: options)
        created.append(interceptor)
        return [interceptor]
    }
}

final class EchoHarness {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let state = EchoServerState()
    let store = NetworkStore()
    let center = BreakpointCenter(timeout: 30, hasPresenter: true)
    let ruleStore: RuleStore
    let rulesDirectory: URL
    private(set) var server: Server?
    private var connections: [ClientConnection] = []
    private(set) var port = 0

    init() throws {
        rulesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("donk-grpc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        ruleStore = RuleStore(fileName: "rules.json", directory: rulesDirectory)
        let server = try Server.insecure(group: group)
            .withServiceProviders([EchoProvider(state: state)])
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        self.server = server
        port = server.channel.localAddress?.port ?? 0
    }

    var host: String { "127.0.0.1:\(port)" }

    var url: String { "grpc://\(host)" }

    func options(_ configure: (inout DonkGRPCOptions) -> Void = { _ in }) -> DonkGRPCOptions {
        var options = DonkGRPCOptions(store: store, ruleStore: ruleStore, breakpointCenter: center, settingsStore: nil)
        options.isEnvironmentActive = { true }
        configure(&options)
        return options
    }

    func client(port: Int? = nil, fastFailure: Bool = false, options: DonkGRPCOptions? = nil) -> Donk_Echo_V1_EchoNIOClient {
        var builder = ClientConnection.insecure(group: group)
        if fastFailure {
            builder = builder
                .withCallStartBehavior(.fastFailure)
                .withConnectionBackoff(retries: .none)
                .withConnectionReestablishment(enabled: false)
        }
        let target = port ?? self.port
        let connection = builder.connect(host: "127.0.0.1", port: target)
        connections.append(connection)
        return Donk_Echo_V1_EchoNIOClient(
            channel: connection,
            defaultCallOptions: CallOptions(timeLimit: .timeout(.seconds(10))),
            interceptors: EchoInterceptors(host: "127.0.0.1:\(target)", options: options ?? self.options())
        )
    }

    func recordingClient(options: DonkGRPCOptions? = nil) -> (client: Donk_Echo_V1_EchoNIOClient, interceptors: RecordingEchoInterceptors) {
        let connection = ClientConnection.insecure(group: group).connect(host: "127.0.0.1", port: port)
        connections.append(connection)
        let interceptors = RecordingEchoInterceptors(host: host, options: options ?? self.options())
        let client = Donk_Echo_V1_EchoNIOClient(
            channel: connection,
            defaultCallOptions: CallOptions(timeLimit: .timeout(.seconds(30))),
            interceptors: interceptors
        )
        return (client, interceptors)
    }

    func addRule(_ name: String, path: String, action: RuleAction) {
        ruleStore.add(NetworkRule(name: name, match: RuleMatch(kinds: [.grpc], url: URLMatcher(pattern: path)), action: action))
    }

    func closedPort() throws -> Int {
        let probe = try Server.insecure(group: group)
            .withServiceProviders([])
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let port = probe.channel.localAddress?.port ?? 1
        try probe.close().wait()
        return port
    }

    func shutdown() {
        for connection in connections {
            try? connection.close().wait()
        }
        connections.removeAll()
        try? server?.close().wait()
        server = nil
        try? group.syncShutdownGracefully()
        try? FileManager.default.removeItem(at: rulesDirectory)
    }

    // MARK: - Waiting

    @discardableResult
    func waitForEntry(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, where predicate: (NetworkEntry) -> Bool) -> NetworkEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = store.snapshot().first(where: predicate) { return entry }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for a matching entry", file: file, line: line)
        return nil
    }

    func waitForFinishedEntry(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> NetworkEntry? {
        waitForEntry(timeout: timeout, file: file, line: line) { !$0.state.isInFlight }
    }

    func waitForPause(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> PausedExchange? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let exchange = center.pending.first { return exchange }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for a breakpoint", file: file, line: line)
        return nil
    }

    func waitUntil(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension Donk_Echo_V1_EchoRequest {
    static func make(_ text: String, configure: (inout Donk_Echo_V1_EchoRequest) -> Void = { _ in }) -> Donk_Echo_V1_EchoRequest {
        var request = Donk_Echo_V1_EchoRequest()
        request.text = text
        configure(&request)
        return request
    }
}

class EchoTestCase: XCTestCase {
    var harness: EchoHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try EchoHarness()
    }

    override func tearDown() {
        harness?.shutdown()
        harness = nil
        super.tearDown()
    }
}
