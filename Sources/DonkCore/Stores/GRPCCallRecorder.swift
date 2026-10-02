import Foundation

public final class GRPCCallRecorder: @unchecked Sendable {
    public static let maxMessageTextSize = 64 * 1024
    public static let responseBodyInterval: TimeInterval = 0.25

    private struct PendingBody {
        var json: String?
        var raw: Data?
    }

    private enum BodyPlan {
        case apply
        case postpone(schedule: UInt64?)
    }

    private let id = UUID()
    private let store: NetworkStore
    private let callType: GRPCCallType
    private let isActive: Bool
    private let bodyLimit: Int
    private let lock = DonkLock()
    private var isFinished = false
    private var hasSent = false
    private var nextBodyUpdate: UInt64 = 0
    private var pendingBody: PendingBody?
    private var isBodyFlushScheduled = false

    private static let bodyIntervalNanoseconds = UInt64(responseBodyInterval * 1_000_000_000)
    private static let flushQueue = DispatchQueue(label: "dev.donk.grpc.recorder", qos: .utility)

    public init(
        host: String?,
        path: String,
        callType: GRPCCallType,
        requestMetadata: [HTTPHeader],
        timeout: TimeInterval?,
        store: NetworkStore = .shared
    ) {
        self.store = store
        self.callType = callType
        isActive = store.isCaptureEnabled
        bodyLimit = store.maxBodySize
        guard isActive else { return }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let entry = NetworkEntry(
            id: id,
            kind: .grpc,
            state: .pending,
            origin: .network,
            request: RequestSnapshot(
                url: "grpc://\(Self.normalizedHost(host))\(normalizedPath)",
                method: "POST",
                headers: requestMetadata
            ),
            timing: NetworkTiming(startedAt: Date()),
            grpc: GRPCDetails(path: normalizedPath, callType: callType, requestMetadata: requestMetadata, timeout: timeout)
        )
        store.add(entry)
    }

    public var entryID: UUID { id }

    public var isRecording: Bool {
        isActive && !lock.withLock { isFinished }
    }

    // MARK: - Events

    public func didSend(typeName: String, size: Int, json: String?, textFormat: String? = nil, raw: Data? = nil) {
        guard isActive else { return }
        let isFirst: Bool? = lock.withLock {
            guard !isFinished else { return nil }
            defer { hasSent = true }
            return !hasSent
        }
        guard let isFirst else { return }
        let message = makeMessage(.sent, typeName: typeName, size: size, json: json, textFormat: textFormat, raw: raw)
        let body = isFirst ? makeBody(json: json, raw: raw) : nil
        let streams = callType != .unary
        store.update(id) { entry in
            entry.grpc?.append(message)
            if let body { entry.request.body = body }
            if streams, entry.state == .pending { entry.state = .streaming }
        }
    }

    public func didReceiveHeaders(_ headers: [HTTPHeader]) {
        guard isActive, !lock.withLock({ isFinished }) else { return }
        let now = Date()
        store.update(id) { entry in
            entry.grpc?.responseHeaders = headers
            if entry.response == nil {
                entry.response = ResponseSnapshot(statusCode: 200, headers: headers)
            } else {
                entry.response?.headers = headers
            }
            if entry.timing.responseStartedAt == nil { entry.timing.responseStartedAt = now }
        }
    }

    public func didReceive(typeName: String, size: Int, json: String?, textFormat: String? = nil, raw: Data? = nil) {
        guard isActive else { return }
        let plan: BodyPlan? = lock.withLock {
            guard !isFinished else { return nil }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= nextBodyUpdate {
                nextBodyUpdate = now &+ Self.bodyIntervalNanoseconds
                pendingBody = nil
                return .apply
            }
            pendingBody = PendingBody(json: json, raw: raw)
            guard !isBodyFlushScheduled else { return .postpone(schedule: nil) }
            isBodyFlushScheduled = true
            return .postpone(schedule: nextBodyUpdate - now)
        }
        guard let plan else { return }
        let message = makeMessage(.received, typeName: typeName, size: size, json: json, textFormat: textFormat, raw: raw)
        var body: BodyData?
        switch plan {
        case .apply:
            body = makeBody(json: json, raw: raw)
        case let .postpone(schedule):
            if let schedule { scheduleBodyFlush(after: schedule) }
        }
        let streams = callType != .unary
        store.update(id) { entry in
            entry.grpc?.append(message)
            if entry.response == nil {
                entry.response = ResponseSnapshot(statusCode: 200)
            }
            if let body { entry.response?.body = body }
            if entry.timing.responseStartedAt == nil { entry.timing.responseStartedAt = message.timestamp }
            if streams, entry.state == .pending { entry.state = .streaming }
        }
    }

    public func didFinish(statusCode: Int, message: String?, trailers: [HTTPHeader]) {
        guard isActive, let pending = markFinished() else { return }
        let now = Date()
        let statusMessage = message.flatMap { $0.isEmpty ? nil : $0 }
        let body = pending.flatMap { makeBody(json: $0.json, raw: $0.raw) }
        store.update(id) { entry in
            if let body { entry.response?.body = body }
            entry.grpc?.statusCode = statusCode
            entry.grpc?.statusMessage = statusMessage
            entry.grpc?.trailers = trailers
            entry.state = .completed
            entry.timing.endedAt = now
        }
    }

    public func didFail(_ error: Error) {
        guard isActive, let pending = markFinished() else { return }
        let now = Date()
        let info = NetworkErrorInfo(error)
        let body = pending.flatMap { makeBody(json: $0.json, raw: $0.raw) }
        store.update(id) { entry in
            if let body { entry.response?.body = body }
            entry.state = .failed
            entry.error = info
            entry.timing.endedAt = now
        }
    }

    public func didCancel() {
        guard isActive, let pending = markFinished() else { return }
        let now = Date()
        let body = pending.flatMap { makeBody(json: $0.json, raw: $0.raw) }
        store.update(id) { entry in
            if let body { entry.response?.body = body }
            entry.state = .cancelled
            entry.timing.endedAt = now
        }
    }

    public func setOrigin(_ origin: NetworkOrigin) {
        guard isActive else { return }
        store.update(id) { entry in
            entry.origin = origin
        }
    }

    // MARK: - Private

    private func markFinished() -> PendingBody?? {
        lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            defer { pendingBody = nil }
            return .some(pendingBody)
        }
    }

    private func scheduleBodyFlush(after nanoseconds: UInt64) {
        Self.flushQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max))))) {
            self.flushPendingBody()
        }
    }

    private func flushPendingBody() {
        let pending: PendingBody? = lock.withLock {
            isBodyFlushScheduled = false
            guard !isFinished, let pending = pendingBody else { return nil }
            pendingBody = nil
            nextBodyUpdate = DispatchTime.now().uptimeNanoseconds &+ Self.bodyIntervalNanoseconds
            return pending
        }
        guard let pending, let body = makeBody(json: pending.json, raw: pending.raw) else { return }
        store.update(id) { entry in
            entry.response?.body = body
        }
    }

    private func makeMessage(
        _ direction: GRPCMessage.Direction,
        typeName: String,
        size: Int,
        json: String?,
        textFormat: String?,
        raw: Data?
    ) -> GRPCMessage {
        let cappedRaw = raw.map { $0.count > bodyLimit ? Data($0.prefix(bodyLimit)) : $0 }
        return GRPCMessage(
            direction: direction,
            timestamp: Date(),
            typeName: typeName,
            size: size,
            json: Self.capped(json),
            textFormat: Self.capped(textFormat),
            raw: cappedRaw
        )
    }

    private func makeBody(json: String?, raw: Data?) -> BodyData? {
        if let json {
            return BodyData(data: Data(json.utf8), contentType: "application/json", limit: bodyLimit)
        }
        if let raw {
            return BodyData(data: raw, contentType: "application/x-protobuf", limit: bodyLimit)
        }
        return nil
    }

    static func capped(_ text: String?, limit: Int = maxMessageTextSize) -> String? {
        guard let text else { return nil }
        let utf8 = text.utf8
        let count = utf8.count
        guard count > limit else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: max(0, limit))
        while end > utf8.startIndex, end.samePosition(in: text.unicodeScalars) == nil {
            end = utf8.index(before: end)
        }
        return String(text.unicodeScalars[..<end]) + "… (truncated, \(count) bytes)"
    }

    static func normalizedHost(_ host: String?) -> String {
        guard var host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return "grpc" }
        for scheme in ["grpc://", "grpcs://", "https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
            break
        }
        while host.hasSuffix("/") { host.removeLast() }
        return host.isEmpty ? "grpc" : host
    }
}
