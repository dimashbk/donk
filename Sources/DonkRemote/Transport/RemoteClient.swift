import Foundation
import Network

final class RemoteClient: @unchecked Sendable {
    typealias HelloProvider = @Sendable () async -> String
    typealias StatusHandler = @Sendable (RemoteClient, RemoteStatus) -> Void

    static let maximumMessageSize = 16 * 1024 * 1024
    static let rejectionCloseCode: UInt16 = 4000
    static let queue = DispatchQueue(label: "dev.donk.remote", qos: .utility)

    let url: URL
    private let backoff: RemoteBackoff
    private let handler: RemoteRequestHandler
    private let hello: HelloProvider
    private let onStatus: StatusHandler
    private let queue = RemoteClient.queue

    private var connection: NWConnection?
    private var isRunning = false
    private var isRejected = false
    private var isWelcomed = false
    private var failures = 0
    private var retry: DispatchWorkItem?
    private var welcomeTimer: DispatchWorkItem?

    init(url: URL, backoff: RemoteBackoff = .standard, handler: RemoteRequestHandler, hello: @escaping HelloProvider, onStatus: @escaping StatusHandler) {
        self.url = url
        self.backoff = backoff
        self.handler = handler
        self.hello = hello
        self.onStatus = onStatus
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            isRejected = false
            failures = 0
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            guard isRunning else { return }
            isRunning = false
            retry?.cancel()
            retry = nil
            welcomeTimer?.cancel()
            welcomeTimer = nil
            if let connection {
                self.connection = nil
                close(connection)
            }
        }
    }

    // MARK: - Connection

    private func connect() {
        guard isRunning, !isRejected else { return }
        retry = nil
        isWelcomed = false
        report(.connecting)
        let connection = NWConnection(to: .url(url), using: Self.parameters(for: url))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handle(state, of: connection)
        }
        connection.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            sendHello(on: connection)
            receive(on: connection)
        case .waiting, .failed, .cancelled:
            drop(connection)
        default:
            break
        }
    }

    private func drop(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        self.connection = nil
        welcomeTimer?.cancel()
        welcomeTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning, !isRejected else { return }
        failures += 1
        report(.connecting)
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + backoff.delay(afterFailures: failures), execute: work)
    }

    private func close(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        guard case .ready = connection.state else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "donk.close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1) {
            connection.cancel()
        }
    }

    static func parameters(for url: URL) -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = maximumMessageSize
        let parameters = url.scheme?.lowercased() == "wss" ? NWParameters.tls : NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    // MARK: - Handshake

    private func sendHello(on connection: NWConnection) {
        let hello = self.hello
        Task { [weak self] in
            let frame = await hello()
            guard let self else { return }
            self.queue.async {
                guard connection === self.connection else { return }
                self.send(frame, on: connection)
                self.armWelcomeTimer(for: connection)
            }
        }
    }

    private func armWelcomeTimer(for connection: NWConnection) {
        welcomeTimer?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, !self.isWelcomed else { return }
            self.drop(connection)
        }
        welcomeTimer = work
        queue.asyncAfter(deadline: .now() + backoff.welcomeTimeout, execute: work)
    }

    private func welcomed(_ connection: NWConnection) {
        isWelcomed = true
        failures = 0
        welcomeTimer?.cancel()
        welcomeTimer = nil
        report(.connected)
    }

    private func reject(_ reason: String, connection: NWConnection) {
        guard !isRejected else { return }
        isRejected = true
        retry?.cancel()
        retry = nil
        welcomeTimer?.cancel()
        welcomeTimer = nil
        report(.rejected(reason))
        if connection === self.connection {
            self.connection = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    // MARK: - Messages

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, connection === self.connection else { return }
            guard error == nil else {
                self.drop(connection)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard let metadata else {
                if content == nil {
                    self.drop(connection)
                } else {
                    self.receive(on: connection)
                }
                return
            }
            switch metadata.opcode {
            case .text:
                if let content, let text = String(data: content, encoding: .utf8) {
                    self.process(text, on: connection)
                }
            case .close:
                self.closed(connection, code: metadata.closeCode, reason: content)
                return
            default:
                break
            }
            if connection === self.connection {
                self.receive(on: connection)
            }
        }
    }

    private func closed(_ connection: NWConnection, code: NWProtocolWebSocket.CloseCode, reason: Data?) {
        if case let .privateCode(value) = code, value == Self.rejectionCloseCode {
            let text = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
            reject(text ?? "hub does not support protocol \(RemoteIdentity.protocolVersion)", connection: connection)
            return
        }
        drop(connection)
    }

    private func process(_ text: String, on connection: NWConnection) {
        switch RemoteIncoming.parse(text) {
        case let .notification(method, params):
            switch method {
            case "welcome":
                welcomed(connection)
            case "rejected":
                var reason = "rejected by hub"
                if case let .string(text)? = params?["reason"], !text.isEmpty {
                    reason = text
                }
                reject(reason, connection: connection)
            default:
                break
            }
        case let .request(id, method, params):
            let handler = self.handler
            Task.detached(priority: .utility) { [weak self] in
                let frame = await handler.respond(id: id, method: method, params: params)
                guard let self else { return }
                self.queue.async {
                    guard connection === self.connection else { return }
                    self.send(frame, on: connection)
                }
            }
        case let .invalid(id):
            send(RemoteFrame.error(id: id, .invalidRequest()), on: connection)
        case .response:
            break
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "donk.text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.drop(connection)
        })
    }

    private func report(_ status: RemoteStatus) {
        onStatus(self, status)
    }
}
