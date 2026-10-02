import DonkCore
import Foundation
import SwiftProtobuf

typealias DonkGRPCCallType = GRPCCallType

struct GRPCRenderBacklog: Equatable, Sendable {
    var pendingRenders: Int
    var pendingBytes: Int
    var peakRenders: Int
    var peakBytes: Int
    var queuedEvents: Int
    var skippedMessages: Int
}

final class GRPCCallLog: @unchecked Sendable {
    private enum Event {
        case render(GRPCMessage.Direction, GRPCCapture)
        case skipped(GRPCMessage.Direction, typeName: String, sizes: [Int])
        case action(() -> Void)
    }

    private let recorder: GRPCCallRecorder
    private let store: NetworkStore
    private let renderer: GRPCMessageRenderer
    private let queue: DispatchQueue
    private let maxPendingRenders: Int
    private let maxPendingBytes: Int

    private let lock = NSLock()
    private var events: [Event] = []
    private var isDrainScheduled = false
    private var pendingRenders = 0
    private var pendingBytes = 0
    private var peakRenders = 0
    private var peakBytes = 0
    private var skippedMessages = 0

    private var origin: NetworkOrigin = .network
    private var stateBeforePause: NetworkState?

    init(
        host: String?,
        path: String,
        callType: DonkGRPCCallType,
        metadata: [HTTPHeader],
        timeout: TimeInterval?,
        store: NetworkStore,
        renderer: GRPCMessageRenderer,
        maxPendingRenders: Int,
        maxPendingBytes: Int,
        queue: DispatchQueue? = nil
    ) {
        recorder = GRPCCallRecorder(
            host: host,
            path: path,
            callType: callType,
            requestMetadata: metadata,
            timeout: timeout,
            store: store
        )
        self.store = store
        self.renderer = renderer
        self.maxPendingRenders = max(1, maxPendingRenders)
        self.maxPendingBytes = max(0, maxPendingBytes)
        self.queue = queue ?? DispatchQueue(label: "dev.donk.grpc.call", qos: .utility, target: .global(qos: .utility))
    }

    var entryID: UUID { recorder.entryID }

    var backlog: GRPCRenderBacklog {
        lock.lock()
        defer { lock.unlock() }
        return GRPCRenderBacklog(
            pendingRenders: pendingRenders,
            pendingBytes: pendingBytes,
            peakRenders: peakRenders,
            peakBytes: peakBytes,
            queuedEvents: events.count,
            skippedMessages: skippedMessages
        )
    }

    // MARK: - Messages

    func sent<Message: SwiftProtobuf.Message>(_ message: Message) {
        enqueue(.sent, renderer.capture(message))
    }

    func received<Message: SwiftProtobuf.Message>(_ message: Message) {
        enqueue(.received, renderer.capture(message))
    }

    // MARK: - Lifecycle

    func receivedHeaders(_ headers: [HTTPHeader]) {
        let recorder = recorder
        perform { recorder.didReceiveHeaders(headers) }
    }

    func finished(code: Int, message: String?, trailers: [HTTPHeader]) {
        let recorder = recorder
        perform { recorder.didFinish(statusCode: code, message: message, trailers: trailers) }
    }

    func failed(_ error: Error) {
        let recorder = recorder
        perform { recorder.didFail(error) }
    }

    func cancelled() {
        let recorder = recorder
        perform { recorder.didCancel() }
    }

    func mark(_ newOrigin: NetworkOrigin) {
        perform { [self] in
            guard Self.rank(newOrigin) > Self.rank(origin) else { return }
            origin = newOrigin
            recorder.setOrigin(newOrigin)
        }
    }

    func updateRequestMetadata(_ headers: [HTTPHeader]) {
        perform { [self] in
            store.update(recorder.entryID) { entry in
                entry.request.headers = headers
                entry.grpc?.requestMetadata = headers
            }
        }
    }

    func paused() {
        perform { [self] in
            var previous: NetworkState?
            store.update(recorder.entryID) { entry in
                guard entry.state.isInFlight, entry.state != .paused else { return }
                previous = entry.state
                entry.state = .paused
            }
            if let previous { stateBeforePause = previous }
        }
    }

    func resumed() {
        perform { [self] in
            let restored = stateBeforePause ?? .pending
            stateBeforePause = nil
            store.update(recorder.entryID) { entry in
                guard entry.state == .paused else { return }
                entry.state = restored
            }
        }
    }

    // MARK: - Queue

    private func enqueue(_ direction: GRPCMessage.Direction, _ capture: GRPCCapture) {
        lock.lock()
        let fitsBytes = pendingRenders == 0 || pendingBytes + capture.cost <= maxPendingBytes
        if pendingRenders < maxPendingRenders, fitsBytes {
            pendingRenders += 1
            pendingBytes += capture.cost
            peakRenders = max(peakRenders, pendingRenders)
            peakBytes = max(peakBytes, pendingBytes)
            events.append(.render(direction, capture))
        } else {
            skippedMessages += 1
            if case .skipped(direction, capture.typeName, var sizes)? = events.last {
                events.removeLast()
                sizes.append(capture.size)
                events.append(.skipped(direction, typeName: capture.typeName, sizes: sizes))
            } else {
                events.append(.skipped(direction, typeName: capture.typeName, sizes: [capture.size]))
            }
        }
        let schedules = scheduleDrainLocked()
        lock.unlock()
        if schedules { queue.async { self.drain() } }
    }

    private func perform(_ action: @escaping () -> Void) {
        lock.lock()
        events.append(.action(action))
        let schedules = scheduleDrainLocked()
        lock.unlock()
        if schedules { queue.async { self.drain() } }
    }

    private func scheduleDrainLocked() -> Bool {
        guard !isDrainScheduled else { return false }
        isDrainScheduled = true
        return true
    }

    private func drain() {
        while true {
            lock.lock()
            guard !events.isEmpty else {
                isDrainScheduled = false
                lock.unlock()
                return
            }
            var batch = events
            events = []
            lock.unlock()
            batch.reverse()
            while let event = batch.popLast() {
                process(event)
            }
        }
    }

    private func process(_ event: Event) {
        switch event {
        case let .render(direction, capture):
            record(direction, capture.render())
            lock.lock()
            pendingRenders -= 1
            pendingBytes -= capture.cost
            lock.unlock()
        case let .skipped(direction, typeName, sizes):
            for size in sizes {
                record(direction, renderer.skipped(typeName: typeName, size: size))
            }
        case let .action(action):
            action()
        }
    }

    private func record(_ direction: GRPCMessage.Direction, _ rendered: GRPCRenderedMessage) {
        switch direction {
        case .sent:
            recorder.didSend(
                typeName: rendered.typeName,
                size: rendered.size,
                json: rendered.json,
                textFormat: rendered.textFormat,
                raw: rendered.raw
            )
        case .received:
            recorder.didReceive(
                typeName: rendered.typeName,
                size: rendered.size,
                json: rendered.json,
                textFormat: rendered.textFormat,
                raw: rendered.raw
            )
        }
    }

    // MARK: - Private

    private static func rank(_ origin: NetworkOrigin) -> Int {
        switch origin {
        case .network: return 0
        case .breakpoint(edited: false): return 1
        case .rewritten: return 2
        case .breakpoint(edited: true): return 3
        case .mocked: return 4
        }
    }
}
