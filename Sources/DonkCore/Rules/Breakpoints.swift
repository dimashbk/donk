import Combine
import Foundation

public enum BreakpointPhase: String, Codable, Sendable {
    case request, response
}

public struct EditableRequest: Codable, Equatable, Sendable {
    public var url: String
    public var method: String
    public var headers: [HTTPHeader]
    public var body: String
    public var bodyIsBinary: Bool

    public init(url: String, method: String = "GET", headers: [HTTPHeader] = [], body: String = "", bodyIsBinary: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.bodyIsBinary = bodyIsBinary
    }

    public init(snapshot: RequestSnapshot) {
        let body = BodyEncoding.editable(snapshot.body?.data)
        self.init(url: snapshot.url, method: snapshot.method, headers: snapshot.headers, body: body.text, bodyIsBinary: body.isBinary)
    }

    public var bodyData: Data {
        bodyIsBinary ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() : Data(body.utf8)
    }
}

public struct EditableResponse: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: String
    public var bodyIsBinary: Bool
    public var grpcStatusCode: Int?
    public var grpcStatusMessage: String?

    public init(
        statusCode: Int = 200,
        headers: [HTTPHeader] = [],
        body: String = "",
        bodyIsBinary: Bool = false,
        grpcStatusCode: Int? = nil,
        grpcStatusMessage: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyIsBinary = bodyIsBinary
        self.grpcStatusCode = grpcStatusCode
        self.grpcStatusMessage = grpcStatusMessage
    }

    public init(snapshot: ResponseSnapshot) {
        let body = BodyEncoding.editable(snapshot.body?.data)
        self.init(statusCode: snapshot.statusCode, headers: snapshot.headers, body: body.text, bodyIsBinary: body.isBinary)
    }

    public var bodyData: Data {
        bodyIsBinary ? Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data() : Data(body.utf8)
    }
}

public enum BreakpointPayload: Equatable, Sendable {
    case request(EditableRequest)
    case response(EditableResponse)
}

public struct PausedExchange: Identifiable, Sendable {
    public var id: UUID
    public var entryID: UUID
    public var kind: NetworkKind
    public var phase: BreakpointPhase
    public var ruleName: String
    public var createdAt: Date
    public var payload: BreakpointPayload

    public init(
        id: UUID = UUID(),
        entryID: UUID,
        kind: NetworkKind,
        phase: BreakpointPhase,
        ruleName: String,
        createdAt: Date = Date(),
        payload: BreakpointPayload
    ) {
        self.id = id
        self.entryID = entryID
        self.kind = kind
        self.phase = phase
        self.ruleName = ruleName
        self.createdAt = createdAt
        self.payload = payload
    }
}

public enum BreakpointDecision: Sendable {
    case resume(BreakpointPayload)
    case abort
    case respond(EditableResponse)
}

public final class BreakpointCenter: @unchecked Sendable {
    public static let shared = BreakpointCenter()

    private struct Waiter {
        var exchange: PausedExchange
        var continuation: CheckedContinuation<BreakpointDecision, Never>
        var token: UInt64
        var timer: DispatchWorkItem?
    }

    private let lock = DonkLock()
    private var waiters: [UUID: Waiter] = [:]
    private var order: [UUID] = []
    private var storedTimeout: TimeInterval
    private var presenterAttached: Bool
    private var nextToken: UInt64 = 0
    private let subject: CurrentValueSubject<[PausedExchange], Never>
    private let publication: PublicationQueue<[PausedExchange]>
    private let timerQueue = DispatchQueue(label: "dev.donk.breakpoints.timeout", qos: .utility)

    public init(timeout: TimeInterval = 300, hasPresenter: Bool = false) {
        storedTimeout = timeout
        presenterAttached = hasPresenter
        let subject = CurrentValueSubject<[PausedExchange], Never>([])
        self.subject = subject
        publication = PublicationQueue(latestOnly: true) { subject.send($0) }
    }

    public var timeout: TimeInterval {
        get { lock.withLock { storedTimeout } }
        set { lock.withLock { storedTimeout = newValue } }
    }

    public var hasPresenter: Bool {
        get { lock.withLock { presenterAttached } }
        set {
            let released: [Waiter] = lock.withLock {
                presenterAttached = newValue
                guard !newValue, !order.isEmpty else { return [] }
                let released = order.compactMap { waiters[$0] }
                waiters.removeAll()
                order.removeAll()
                publication.enqueue([])
                return released
            }
            publication.flush()
            for waiter in released {
                waiter.timer?.cancel()
                waiter.continuation.resume(returning: .resume(waiter.exchange.payload))
            }
        }
    }

    public var pending: [PausedExchange] {
        lock.withLock { pendingLocked() }
    }

    public var changes: AnyPublisher<[PausedExchange], Never> {
        subject.eraseToAnyPublisher()
    }

    public func pause(_ exchange: PausedExchange) async -> BreakpointDecision {
        guard hasPresenter else { return .resume(exchange.payload) }
        let id = exchange.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BreakpointDecision, Never>) in
                register(exchange, continuation: continuation)
            }
        } onCancel: {
            self.resolve(id, with: .abort)
        }
    }

    public func resolve(_ id: UUID, with decision: BreakpointDecision) {
        finish(id, token: nil, decision: decision)
    }

    public func resolveAll(with decisionFor: (PausedExchange) -> BreakpointDecision) {
        for exchange in pending {
            resolve(exchange.id, with: decisionFor(exchange))
        }
    }

    // MARK: - Private

    private enum Registration {
        case registered(displaced: Waiter?, token: UInt64, timeout: TimeInterval)
        case unattended
    }

    private func register(_ exchange: PausedExchange, continuation: CheckedContinuation<BreakpointDecision, Never>) {
        if Task.isCancelled {
            continuation.resume(returning: .abort)
            return
        }
        let id = exchange.id
        let registration: Registration = lock.withLock {
            guard presenterAttached else { return .unattended }
            nextToken &+= 1
            let token = nextToken
            let displaced = waiters.removeValue(forKey: id)
            if displaced != nil {
                order.removeAll { $0 == id }
            }
            waiters[id] = Waiter(exchange: exchange, continuation: continuation, token: token, timer: nil)
            order.append(id)
            publication.enqueue(pendingLocked())
            return .registered(displaced: displaced, token: token, timeout: storedTimeout)
        }
        guard case let .registered(displaced, token, timeout) = registration else {
            continuation.resume(returning: .resume(exchange.payload))
            return
        }
        if let displaced {
            displaced.timer?.cancel()
            displaced.continuation.resume(returning: .resume(displaced.exchange.payload))
        }
        if timeout > 0, timeout.isFinite {
            let payload = exchange.payload
            let item = DispatchWorkItem { [weak self] in
                self?.finish(id, token: token, decision: .resume(payload))
            }
            let attached: Bool = lock.withLock {
                guard waiters[id]?.token == token else { return false }
                waiters[id]?.timer = item
                return true
            }
            if attached {
                timerQueue.asyncAfter(deadline: .now() + timeout, execute: item)
            }
        }
        publication.flush()
        if Task.isCancelled {
            finish(id, token: token, decision: .abort)
        }
    }

    private func finish(_ id: UUID, token: UInt64?, decision: BreakpointDecision) {
        let waiter: Waiter? = lock.withLock {
            guard let waiter = waiters[id], token == nil || waiter.token == token else { return nil }
            waiters[id] = nil
            order.removeAll { $0 == id }
            publication.enqueue(pendingLocked())
            return waiter
        }
        guard let waiter else { return }
        waiter.timer?.cancel()
        publication.flush()
        waiter.continuation.resume(returning: decision)
    }

    private func pendingLocked() -> [PausedExchange] {
        order.compactMap { waiters[$0]?.exchange }
    }
}
