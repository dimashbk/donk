import DonkCore
import Foundation
import Network
import XCTest
@testable import DonkRemote

final class TestHub: @unchecked Sendable {
    let queue = DispatchQueue(label: "donk.remote.tests.hub")
    private let listener: NWListener
    private let lock = NSLock()
    private var storedConnections: [NWConnection] = []
    private var storedFrames: [[String]] = []
    private var storedCloses: [Int] = []
    private var storedPongs = 0
    private var isReady = false

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.locked { self.isReady = true }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        await waitUntil { self.locked { self.isReady } }
    }

    func stop() {
        listener.cancel()
        locked { storedConnections }.forEach { $0.cancel() }
    }

    var url: URL {
        URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/app")!
    }

    var connectionCount: Int { locked { storedConnections.count } }

    var pongs: Int { locked { storedPongs } }

    func frames(_ index: Int) -> [String] {
        locked { storedFrames.indices.contains(index) ? storedFrames[index] : [] }
    }

    func closes(_ index: Int) -> Int {
        locked { storedCloses.indices.contains(index) ? storedCloses[index] : 0 }
    }

    func send(_ text: String, to index: Int) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection(index).send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func ping(_ index: Int) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            guard let self, error == nil else { return }
            self.locked { self.storedPongs += 1 }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection(index).send(content: Data("ping".utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close(_ index: Int, code: NWProtocolWebSocket.CloseCode, reason: String? = nil) {
        let connection = connection(index)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: reason.map { Data($0.utf8) }, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func connection(_ index: Int) -> NWConnection {
        locked { storedConnections[index] }
    }

    private func accept(_ connection: NWConnection) {
        let index: Int = locked {
            storedConnections.append(connection)
            storedFrames.append([])
            storedCloses.append(0)
            return storedConnections.count - 1
        }
        connection.start(queue: queue)
        receive(on: connection, index: index)
    }

    private func receive(on connection: NWConnection, index: Int) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                let text = content.map { String(decoding: $0, as: UTF8.self) } ?? ""
                self.locked { self.storedFrames[index].append(text) }
            case .close?:
                self.locked { self.storedCloses[index] += 1 }
                return
            case nil:
                if content == nil { return }
            default:
                break
            }
            self.receive(on: connection, index: index)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RemoteStatus] = []

    func record(_ status: RemoteStatus) {
        lock.lock()
        if storage.last != status { storage.append(status) }
        lock.unlock()
    }

    var values: [RemoteStatus] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: RemoteStatus? { values.last }
}

func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

final class RemoteTransportTests: XCTestCase {
    private var hub: TestHub!
    private var client: RemoteClient?

    override func setUp() async throws {
        try await super.setUp()
        hub = try TestHub()
        await hub.start()
    }

    override func tearDown() async throws {
        client?.stop()
        client = nil
        hub.stop()
        hub = nil
        try await super.tearDown()
    }

    private func makeClient(backoff: RemoteBackoff = RemoteBackoff(delays: [0.05], welcomeTimeout: 5), statuses: StatusRecorder) -> RemoteClient {
        let fixture = RemoteFixture()
        fixture.store.add(makeHTTPEntry(url: "https://api.example.com/v1/accounts", headers: [HTTPHeader(name: "Authorization", value: "Bearer raw")]))
        let client = RemoteClient(
            url: hub.url,
            backoff: backoff,
            handler: fixture.handler,
            hello: { testIdentity.hello(hasCrashes: false, hasForegroundScene: true) },
            onStatus: { _, status in statuses.record(status) }
        )
        self.client = client
        return client
    }

    func testHandshakeRequestsPingAndReconnect() async throws {
        let statuses = StatusRecorder()
        let client = makeClient(statuses: statuses)
        client.start()

        await waitUntil { self.hub.frames(0).count == 1 }
        let hello = try JSONValue.parse(hub.frames(0)[0])
        XCTAssertEqual(hello["method"]?.string, "hello")
        XCTAssertEqual(hello["params"]?["session"]?.string, testSession.uuidString)
        XCTAssertEqual(hello["params"]?["protocol"]?.int, 1)
        XCTAssertEqual(statuses.last, .connecting)

        hub.send(#"{"jsonrpc":"2.0","method":"welcome","params":{"protocol":1,"hub":"0.1.0"}}"#, to: 0)
        await waitUntil { statuses.last == .connected }

        hub.send(#"{"jsonrpc":"2.0","id":"r-1","method":"network.list","params":{"limit":5}}"#, to: 0)
        hub.send(#"{"jsonrpc":"2.0","id":"r-2","method":"no.such.method"}"#, to: 0)
        await waitUntil { self.hub.frames(0).count == 3 }
        let responses = try hub.frames(0).dropFirst().map { try JSONValue.parse($0) }
        let list = try XCTUnwrap(responses.first { $0["id"]?.string == "r-1" })
        XCTAssertEqual(list["result"]?["total"]?.int, 1)
        XCTAssertFalse(hub.frames(0)[1...].joined().contains("Bearer raw"))
        let unknown = try XCTUnwrap(responses.first { $0["id"]?.string == "r-2" })
        XCTAssertEqual(unknown["error"]?["code"]?.int, -32601)

        hub.ping(0)
        await waitUntil { self.hub.pongs == 1 }

        hub.close(0, code: .protocolCode(.goingAway))
        await waitUntil { self.hub.connectionCount == 2 && self.hub.frames(1).count == 1 }
        let second = try JSONValue.parse(hub.frames(1)[0])
        XCTAssertEqual(second["method"]?.string, "hello")
        XCTAssertEqual(second["params"]?["session"]?.string, testSession.uuidString)
        XCTAssertTrue(statuses.values.contains(.connected))
        XCTAssertEqual(statuses.last, .connecting)

        hub.send(#"{"jsonrpc":"2.0","method":"welcome","params":{"protocol":1,"hub":"0.1.0"}}"#, to: 1)
        await waitUntil { statuses.last == .connected }
        hub.send(#"{"jsonrpc":"2.0","id":"r-3","method":"app.info"}"#, to: 1)
        await waitUntil { self.hub.frames(1).count == 2 }
        XCTAssertEqual(try JSONValue.parse(hub.frames(1)[1])["result"]?["session"]?.string, testSession.uuidString)
    }

    func testRejectedStopsRetrying() async throws {
        let statuses = StatusRecorder()
        let client = makeClient(statuses: statuses)
        client.start()
        await waitUntil { self.hub.frames(0).count == 1 }
        hub.send(#"{"jsonrpc":"2.0","method":"rejected","params":{"reason":"protocol 1 is not supported"}}"#, to: 0)
        hub.close(0, code: .privateCode(4000))
        await waitUntil { statuses.last == .rejected("protocol 1 is not supported") }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(hub.connectionCount, 1)
        XCTAssertEqual(statuses.last, .rejected("protocol 1 is not supported"))
    }

    func testCloseCode4000AloneRejects() async throws {
        let statuses = StatusRecorder()
        let client = makeClient(statuses: statuses)
        client.start()
        await waitUntil { self.hub.frames(0).count == 1 }
        hub.close(0, code: .privateCode(4000), reason: "unsupported protocol")
        await waitUntil {
            if case .rejected = statuses.last { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(hub.connectionCount, 1)
    }

    func testMissingWelcomeReconnects() async throws {
        let statuses = StatusRecorder()
        let client = makeClient(backoff: RemoteBackoff(delays: [0.05], welcomeTimeout: 0.2), statuses: statuses)
        client.start()
        await waitUntil { self.hub.connectionCount >= 2 && self.hub.frames(1).count == 1 }
        XCTAssertFalse(statuses.values.contains(.connected))
    }

    func testStopClosesAndDoesNotReconnect() async throws {
        let statuses = StatusRecorder()
        let client = makeClient(statuses: statuses)
        client.start()
        await waitUntil { self.hub.frames(0).count == 1 }
        hub.send(#"{"jsonrpc":"2.0","method":"welcome","params":{"protocol":1,"hub":"0.1.0"}}"#, to: 0)
        await waitUntil { statuses.last == .connected }
        client.stop()
        await waitUntil { self.hub.closes(0) == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(hub.connectionCount, 1)
    }

    func testRetriesWhileHubIsDown() async throws {
        let statuses = StatusRecorder()
        let url = hub.url
        hub.stop()
        let client = RemoteClient(
            url: url,
            backoff: RemoteBackoff(delays: [0.05], welcomeTimeout: 5),
            handler: RemoteFixture().handler,
            hello: { testIdentity.hello(hasCrashes: false, hasForegroundScene: false) },
            onStatus: { _, status in statuses.record(status) }
        )
        self.client = client
        client.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(statuses.values, [.connecting])
    }

    func testParametersUseWebSocket() {
        let plain = RemoteClient.parameters(for: URL(string: "ws://127.0.0.1:7337/app")!)
        XCTAssertTrue(plain.defaultProtocolStack.applicationProtocols.first is NWProtocolWebSocket.Options)
        let secure = RemoteClient.parameters(for: URL(string: "wss://hub.local/app")!)
        XCTAssertTrue(secure.defaultProtocolStack.applicationProtocols.first is NWProtocolWebSocket.Options)
        XCTAssertTrue(secure.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
    }

    func testLargeResponsesTravelInOneFrame() async throws {
        let statuses = StatusRecorder()
        let fixture = RemoteFixture()
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(id: entryID, responseBody: BodyData(text: String(repeating: "z", count: 900 * 1024))))
        let client = RemoteClient(
            url: hub.url,
            backoff: RemoteBackoff(delays: [0.05], welcomeTimeout: 5),
            handler: fixture.handler,
            hello: { testIdentity.hello(hasCrashes: false, hasForegroundScene: false) },
            onStatus: { _, status in statuses.record(status) }
        )
        self.client = client
        client.start()
        await waitUntil { self.hub.frames(0).count == 1 }
        hub.send(#"{"jsonrpc":"2.0","method":"welcome","params":{"protocol":1,"hub":"0.1.0"}}"#, to: 0)
        hub.send(#"{"jsonrpc":"2.0","id":"big","method":"network.get","params":{"id":"\#(entryID.uuidString)","maxBodyBytes":1048576}}"#, to: 0)
        await waitUntil { self.hub.frames(0).count == 2 }
        let response = try JSONValue.parse(hub.frames(0)[1])
        XCTAssertEqual(response["result"]?["entry"]?["response"]?["body"]?["text"]?.string?.utf8.count, 900 * 1024)
    }
}
