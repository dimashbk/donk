import DonkCore
import Foundation
import GRPC
import NIOCore
import NIOHPACK
import SwiftProtobuf

public final class DonkClientInterceptor<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>:
    ClientInterceptor<Request, Response>, @unchecked Sendable {
    private typealias Context = ClientInterceptorContext<Request, Response>
    private typealias Outbound = (part: GRPCClientRequestPart<Request>, promise: EventLoopPromise<Void>?)

    private enum Mode {
        case undecided, passthrough, active
    }

    public let host: String?
    public let options: DonkGRPCOptions
    private lazy var renderer = GRPCMessageRenderer(options: options)

    private var mode = Mode.undecided
    private var context: Context?
    private var plan = GRPCCallPlan.none
    private var log: GRPCCallLog?
    private var url = ""
    private var hasSingleResponse = true
    private var streamsRequests = false
    private var answersLocallyOnFirstMessage = false
    private var isTerminated = false

    private var requestHeaders: [HTTPHeader] = []
    private var didForwardMetadata = false
    private var isHoldingRequest = false
    private var didPauseRequest = false
    private var heldRequest: [Outbound] = []
    private var hasClientMessage = false
    private var hasClientEnded = false

    private var isLocal = false
    private var localResponse: GRPCLocalResponse<Response>?
    private var didScheduleLocal = false
    private var scheduledLocal: Scheduled<Void>?
    private var allowsResponseBreakpoint = true

    private var inbound: [GRPCClientResponsePart<Response>] = []
    private var isInboundPaused = false
    private var isDraining = false
    private var responseHeaders: [HTTPHeader] = []
    private var heldResponseMetadata: HPACKHeaders?
    private var heldResponseMessages: [Response] = []

    private var pendingExchange: UUID?
    private var pauseTask: Task<Void, Never>?

    public init(host: String?, options: DonkGRPCOptions = .init()) {
        self.host = host
        self.options = options
        super.init()
    }

    var isCapturing: Bool { mode == .active }

    var renderBacklog: GRPCRenderBacklog? { log?.backlog }

    // MARK: - Outbound

    override public func send(
        _ part: GRPCClientRequestPart<Request>,
        promise: EventLoopPromise<Void>?,
        context: ClientInterceptorContext<Request, Response>
    ) {
        if mode == .undecided { decide(context) }
        guard mode == .active, !isTerminated else {
            context.send(part, promise: promise)
            return
        }
        self.context = context
        switch part {
        case let .metadata(headers):
            sendMetadata(headers, promise: promise, context: context)
        case let .message(message, metadata):
            sendMessage(message, metadata: metadata, promise: promise, context: context)
        case .end:
            sendEnd(promise: promise, context: context)
        }
    }

    override public func cancel(promise: EventLoopPromise<Void>?, context: ClientInterceptorContext<Request, Response>) {
        guard mode == .active, !isTerminated else {
            context.cancel(promise: promise)
            return
        }
        self.context = context
        let error = GRPCError.RPCCancelledByClient()
        terminate(failingHeldWith: error)
        log?.cancelled()
        guard isLocal else {
            context.cancel(promise: promise)
            return
        }
        promise?.succeed(())
        context.receive(.end(error.makeGRPCStatus(), [:]))
    }

    private func decide(_ context: Context) {
        guard options.isEnvironmentActive(),
              options.store.isCaptureEnabled,
              !HostPattern.matchesAny(GRPCCallTarget.hostWithoutPort(host), patterns: options.effectiveBypassHosts)
        else {
            mode = .passthrough
            return
        }
        mode = .active
        AnyTypeRegistry.shared.register(options.anyTypeRegistry)
        url = GRPCCallTarget.url(host: host, path: context.path)
        switch context.type {
        case .unary:
            hasSingleResponse = true
        case .clientStreaming:
            hasSingleResponse = true
            streamsRequests = true
        case .serverStreaming:
            hasSingleResponse = false
        case .bidirectionalStreaming:
            hasSingleResponse = false
            streamsRequests = true
            answersLocallyOnFirstMessage = true
        }
        guard options.isRulesEnabled else { return }
        plan = GRPCCallPlan(options.ruleStore.resolve(kind: .grpc, method: "POST", url: url))
        if !options.breakpointCenter.hasPresenter {
            plan.removeBreakpoints()
        }
    }

    private func sendMetadata(_ metadata: HPACKHeaders, promise: EventLoopPromise<Void>?, context: Context) {
        var headers = metadata.donkHeaders
        var outgoing = metadata
        if let patch = plan.requestHeaderPatch, plan.mock == nil {
            headers = patch.apply(to: headers)
            outgoing = HPACKHeaders(donkHeaders: headers, preservingPseudoHeadersOf: metadata)
        }
        requestHeaders = headers
        let log = makeLog(headers: headers, context: context)
        if let mock = plan.mock {
            log.mark(.mocked(rule: plan.transformRuleName ?? "Map Local"))
            isLocal = true
            localResponse = GRPCLocalResponse(mock: mock, renderer: renderer)
            promise?.succeed(())
            return
        }
        if plan.requestRewrite != nil || plan.responseRewrite != nil {
            log.mark(.rewritten(rule: plan.transformRuleName ?? "Rewrite"))
        }
        if plan.breaksOnRequest, !streamsRequests {
            isHoldingRequest = true
            heldRequest.append((.metadata(outgoing), promise))
            return
        }
        didForwardMetadata = true
        context.send(.metadata(outgoing), promise: promise)
    }

    private func sendMessage(
        _ message: Request,
        metadata: MessageMetadata,
        promise: EventLoopPromise<Void>?,
        context: Context
    ) {
        hasClientMessage = true
        if isLocal {
            log?.sent(message)
            promise?.succeed(())
            deliverLocalIfReady()
            return
        }
        var message = message
        if let patch = plan.requestBodyPatch {
            switch renderer.patch(message, with: patch) {
            case .unchanged:
                break
            case let .patched(patched):
                message = patched
            case .invalid:
                let status = GRPCStatus(code: .internalError, message: "donk: invalid rewritten request JSON")
                promise?.fail(status)
                finishLocally(status)
                return
            }
        }
        if plan.breaksOnRequest, streamsRequests, !didPauseRequest {
            isHoldingRequest = true
        }
        if isHoldingRequest {
            heldRequest.append((.message(message, metadata), promise))
            if !didPauseRequest {
                didPauseRequest = true
                pauseRequest(message)
            }
            return
        }
        log?.sent(message)
        context.send(.message(message, metadata), promise: promise)
    }

    private func sendEnd(promise: EventLoopPromise<Void>?, context: Context) {
        hasClientEnded = true
        if isLocal {
            promise?.succeed(())
            deliverLocalIfReady()
            return
        }
        if isHoldingRequest {
            heldRequest.append((.end, promise))
            if !didPauseRequest {
                didPauseRequest = true
                pauseRequest(nil)
            }
            return
        }
        context.send(.end, promise: promise)
    }

    private func makeLog(headers: [HTTPHeader], context: Context) -> GRPCCallLog {
        if let log { return log }
        let callType: DonkGRPCCallType
        switch context.type {
        case .unary: callType = .unary
        case .clientStreaming: callType = .clientStreaming
        case .serverStreaming: callType = .serverStreaming
        case .bidirectionalStreaming: callType = .bidirectionalStreaming
        }
        let log = GRPCCallLog(
            host: GRPCCallTarget.host(host),
            path: context.path,
            callType: callType,
            metadata: headers,
            timeout: context.options.timeLimit.donkSeconds,
            store: options.store,
            renderer: renderer,
            maxPendingRenders: options.maxRenderBacklogMessages,
            maxPendingBytes: options.maxRenderBacklogBytes
        )
        self.log = log
        return log
    }

    // MARK: - Request breakpoint

    private func pauseRequest(_ message: Request?) {
        guard let log, let context else { return }
        let id = UUID()
        pendingExchange = id
        log.paused()
        let renderer = renderer
        let center = options.breakpointCenter
        let headers = requestHeaders
        let url = url
        let ruleName = plan.breakpointRuleName ?? "Breakpoint"
        let entryID = log.entryID
        let eventLoop = context.eventLoop
        pauseTask = Task {
            let body = message.map { renderer.editable($0) } ?? .empty
            let original = EditableRequest(url: url, method: "POST", headers: headers, body: body.text, bodyIsBinary: body.isBinary)
            let exchange = PausedExchange(id: id, entryID: entryID, kind: .grpc, phase: .request, ruleName: ruleName, payload: .request(original))
            let decision = await center.pause(exchange)
            eventLoop.execute {
                self.resolveRequest(id: id, original: original, decision: decision)
            }
        }
    }

    private func resolveRequest(id: UUID, original: EditableRequest, decision: BreakpointDecision) {
        guard pendingExchange == id, !isTerminated, let log else { return }
        pendingExchange = nil
        pauseTask = nil
        log.resumed()
        switch decision {
        case let .resume(.request(edited)):
            resumeRequest(original: original, edited: edited)
        case .resume(.response):
            resumeRequest(original: original, edited: original)
        case .abort:
            completeHeldRequest(recordingMessages: true)
            finishLocally(.donkAborted, cancelled: true)
        case let .respond(response):
            respondLocally(response)
        }
    }

    private func resumeRequest(original: EditableRequest, edited: EditableRequest) {
        guard let log else { return }
        let headersChanged = !didForwardMetadata && edited.headers != original.headers
        let bodyChanged = edited.body != original.body || edited.bodyIsBinary != original.bodyIsBinary
        var replacement: Request?
        if bodyChanged {
            do {
                replacement = try renderer.decodeOne(Request.self, from: GRPCEditableBody(text: edited.body, isBinary: edited.bodyIsBinary))
            } catch {
                completeHeldRequest()
                finishLocally(GRPCStatus(code: .internalError, message: "donk: invalid breakpoint request JSON"))
                return
            }
        }
        log.mark(.breakpoint(edited: headersChanged || bodyChanged))
        if headersChanged {
            requestHeaders = edited.headers
            log.updateRequestMetadata(edited.headers)
            if let index = heldRequest.firstIndex(where: { if case .metadata = $0.part { return true }; return false }),
               case let .metadata(original) = heldRequest[index].part {
                heldRequest[index].part = .metadata(HPACKHeaders(donkHeaders: edited.headers, preservingPseudoHeadersOf: original))
            }
        }
        if let replacement {
            if let index = heldRequest.firstIndex(where: { if case .message = $0.part { return true }; return false }),
               case let .message(_, metadata) = heldRequest[index].part {
                heldRequest[index].part = .message(replacement, metadata)
            } else {
                let index = heldRequest.firstIndex(where: { if case .end = $0.part { return true }; return false }) ?? heldRequest.endIndex
                heldRequest.insert((.message(replacement, MessageMetadata(compress: false, flush: true)), nil), at: index)
            }
        }
        flushHeldRequest()
    }

    private func flushHeldRequest() {
        guard let context else { return }
        let held = heldRequest
        heldRequest = []
        isHoldingRequest = false
        for (index, next) in held.enumerated() {
            guard !isTerminated else {
                for item in held[index...] {
                    item.promise?.fail(GRPCError.AlreadyComplete())
                }
                return
            }
            switch next.part {
            case .metadata:
                didForwardMetadata = true
            case let .message(message, _):
                log?.sent(message)
            case .end:
                break
            }
            context.send(next.part, promise: next.promise)
        }
    }

    private func completeHeldRequest(recordingMessages: Bool = false) {
        let held = heldRequest
        heldRequest = []
        isHoldingRequest = false
        for item in held {
            if recordingMessages, case let .message(message, _) = item.part {
                log?.sent(message)
            }
            item.promise?.succeed(())
        }
    }

    private func respondLocally(_ response: EditableResponse) {
        log?.mark(.breakpoint(edited: true))
        completeHeldRequest(recordingMessages: true)
        isLocal = true
        localResponse = GRPCLocalResponse(editable: response, renderer: renderer)
        if didForwardMetadata {
            context?.cancel(promise: nil)
        }
        deliverLocalIfReady()
    }

    // MARK: - Local responses

    private var isLocalResponseDue: Bool {
        hasClientEnded || (answersLocallyOnFirstMessage && hasClientMessage)
    }

    private func deliverLocalIfReady() {
        guard isLocal, !isTerminated, isLocalResponseDue, !didScheduleLocal, let local = localResponse, let context else { return }
        didScheduleLocal = true
        guard local.delay > 0 else {
            deliverLocal(local)
            return
        }
        let nanoseconds = Int64(min(local.delay, 86_400) * 1_000_000_000)
        scheduledLocal = context.eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) {
            self.deliverLocal(local)
        }
    }

    private func deliverLocal(_ local: GRPCLocalResponse<Response>) {
        scheduledLocal = nil
        guard !isTerminated else { return }
        allowsResponseBreakpoint = local.allowsResponseBreakpoint
        inbound.append(contentsOf: local.parts())
        drainInbound()
    }

    // MARK: - Inbound

    override public func receive(_ part: GRPCClientResponsePart<Response>, context: ClientInterceptorContext<Request, Response>) {
        guard mode == .active, !isTerminated else {
            context.receive(part)
            return
        }
        self.context = context
        guard !isLocal else { return }
        inbound.append(part)
        drainInbound()
    }

    override public func errorCaught(_ error: Error, context: ClientInterceptorContext<Request, Response>) {
        guard mode == .active, !isTerminated else {
            context.errorCaught(error)
            return
        }
        self.context = context
        if isLocal, !error.isDonkDeadline { return }
        terminate(failingHeldWith: error)
        log?.failed(GRPCFailure(status: .donkStatus(for: error)))
        context.errorCaught(error)
    }

    private var holdsSingleResponse: Bool {
        plan.breaksOnResponse && hasSingleResponse && allowsResponseBreakpoint
    }

    private var breaksOnStreamingResponse: Bool {
        plan.breaksOnResponse && !hasSingleResponse && allowsResponseBreakpoint
    }

    private func drainInbound() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !isInboundPaused, !isTerminated, !inbound.isEmpty {
            processInbound(inbound.removeFirst())
        }
    }

    private func processInbound(_ part: GRPCClientResponsePart<Response>) {
        guard let context, let log else {
            context?.receive(part)
            return
        }
        switch part {
        case let .metadata(metadata):
            var headers = metadata.donkHeaders
            var outgoing = metadata
            if !isLocal, let patch = plan.responseHeaderPatch {
                headers = patch.apply(to: headers)
                outgoing = HPACKHeaders(donkHeaders: headers, preservingPseudoHeadersOf: metadata)
            }
            if holdsSingleResponse {
                heldResponseMetadata = outgoing
                return
            }
            responseHeaders = headers
            log.receivedHeaders(headers)
            context.receive(.metadata(outgoing))
        case let .message(message):
            var message = message
            if !isLocal, let patch = plan.responseBodyPatch {
                switch renderer.patch(message, with: patch) {
                case .unchanged:
                    break
                case let .patched(patched):
                    message = patched
                case .invalid:
                    finishLocally(GRPCStatus(code: .internalError, message: "donk: invalid rewritten response JSON"))
                    return
                }
            }
            if holdsSingleResponse {
                heldResponseMessages.append(message)
                return
            }
            if breaksOnStreamingResponse, options.breakpointCenter.hasPresenter {
                isInboundPaused = true
                pauseStreamingResponse(message)
                return
            }
            log.received(message)
            context.receive(.message(message))
        case let .end(status, trailers):
            let status = isLocal ? status : status.applying(plan.responseRewrite)
            if holdsSingleResponse {
                isInboundPaused = true
                pauseSingleResponse(status: status, trailers: trailers)
                return
            }
            deliverEnd(status, trailers: trailers)
        }
    }

    private func deliverEnd(_ status: GRPCStatus, trailers: HPACKHeaders) {
        guard let context else { return }
        isTerminated = true
        terminate(failingHeldWith: GRPCError.AlreadyComplete())
        log?.finished(code: status.code.rawValue, message: status.message, trailers: trailers.donkHeaders)
        context.receive(.end(status, trailers))
    }

    // MARK: - Response breakpoints

    private func pauseSingleResponse(status: GRPCStatus, trailers: HPACKHeaders) {
        guard let log, let context else { return }
        let id = UUID()
        pendingExchange = id
        log.paused()
        let renderer = renderer
        let center = options.breakpointCenter
        let headers = heldResponseMetadata?.donkHeaders ?? []
        let message = heldResponseMessages.first
        let ruleName = plan.breakpointRuleName ?? "Breakpoint"
        let entryID = log.entryID
        let eventLoop = context.eventLoop
        pauseTask = Task {
            let body = message.map { renderer.editable($0) } ?? .empty
            let original = EditableResponse(
                statusCode: 200,
                headers: headers,
                body: body.text,
                bodyIsBinary: body.isBinary,
                grpcStatusCode: status.code.rawValue,
                grpcStatusMessage: status.message
            )
            let exchange = PausedExchange(id: id, entryID: entryID, kind: .grpc, phase: .response, ruleName: ruleName, payload: .response(original))
            let decision = await center.pause(exchange)
            eventLoop.execute {
                self.resolveSingleResponse(id: id, original: original, status: status, trailers: trailers, decision: decision)
            }
        }
    }

    private func resolveSingleResponse(
        id: UUID,
        original: EditableResponse,
        status: GRPCStatus,
        trailers: HPACKHeaders,
        decision: BreakpointDecision
    ) {
        guard pendingExchange == id, !isTerminated, let log else { return }
        pendingExchange = nil
        pauseTask = nil
        log.resumed()
        let edited: EditableResponse
        switch decision {
        case let .resume(.response(response)), let .respond(response):
            edited = response
        case .resume(.request):
            edited = original
        case .abort:
            finishLocally(.donkAborted, cancelled: true)
            return
        }
        var metadata = heldResponseMetadata
        var messages = heldResponseMessages
        var finalStatus = status
        heldResponseMetadata = nil
        heldResponseMessages = []
        let headersChanged = edited.headers != original.headers
        let bodyChanged = edited.body != original.body || edited.bodyIsBinary != original.bodyIsBinary
        let statusChanged = edited.grpcStatusCode != original.grpcStatusCode || edited.grpcStatusMessage != original.grpcStatusMessage
        if bodyChanged {
            do {
                messages = try renderer.decodeMany(Response.self, from: GRPCEditableBody(text: edited.body, isBinary: edited.bodyIsBinary))
            } catch {
                finishLocally(GRPCStatus(code: .internalError, message: "donk: invalid breakpoint response JSON"))
                return
            }
        }
        if headersChanged {
            metadata = HPACKHeaders(donkHeaders: edited.headers, preservingPseudoHeadersOf: metadata)
        }
        if statusChanged {
            finalStatus = GRPCStatus(donkCode: edited.grpcStatusCode ?? status.code.rawValue, message: edited.grpcStatusMessage)
        }
        log.mark(.breakpoint(edited: headersChanged || bodyChanged || statusChanged))
        if metadata == nil, !messages.isEmpty {
            metadata = HPACKHeaders()
        }
        isInboundPaused = false
        guard let context else { return }
        if let metadata {
            let headers = metadata.donkHeaders
            responseHeaders = headers
            log.receivedHeaders(headers)
            context.receive(.metadata(metadata))
        }
        for message in messages where !isTerminated {
            log.received(message)
            context.receive(.message(message))
        }
        guard !isTerminated else { return }
        deliverEnd(finalStatus, trailers: trailers)
    }

    private func pauseStreamingResponse(_ message: Response) {
        guard let log, let context else { return }
        let id = UUID()
        pendingExchange = id
        log.paused()
        let renderer = renderer
        let center = options.breakpointCenter
        let headers = responseHeaders
        let ruleName = plan.breakpointRuleName ?? "Breakpoint"
        let entryID = log.entryID
        let eventLoop = context.eventLoop
        pauseTask = Task {
            let body = renderer.editable(message)
            let original = EditableResponse(statusCode: 200, headers: headers, body: body.text, bodyIsBinary: body.isBinary)
            let exchange = PausedExchange(id: id, entryID: entryID, kind: .grpc, phase: .response, ruleName: ruleName, payload: .response(original))
            let decision = await center.pause(exchange)
            eventLoop.execute {
                self.resolveStreamingResponse(id: id, message: message, original: original, decision: decision)
            }
        }
    }

    private func resolveStreamingResponse(id: UUID, message: Response, original: EditableResponse, decision: BreakpointDecision) {
        guard pendingExchange == id, !isTerminated, let log, let context else { return }
        pendingExchange = nil
        pauseTask = nil
        log.resumed()
        var messages = [message]
        switch decision {
        case let .resume(.response(edited)), let .respond(edited):
            let bodyChanged = edited.body != original.body || edited.bodyIsBinary != original.bodyIsBinary
            if bodyChanged {
                do {
                    messages = try renderer.decodeMany(Response.self, from: GRPCEditableBody(text: edited.body, isBinary: edited.bodyIsBinary))
                } catch {
                    finishLocally(GRPCStatus(code: .internalError, message: "donk: invalid breakpoint response JSON"))
                    return
                }
            }
            log.mark(.breakpoint(edited: bodyChanged))
        case .resume(.request):
            log.mark(.breakpoint(edited: false))
        case .abort:
            finishLocally(.donkAborted, cancelled: true)
            return
        }
        for message in messages where !isTerminated {
            log.received(message)
            context.receive(.message(message))
        }
        isInboundPaused = false
        drainInbound()
    }

    // MARK: - Termination

    private func finishLocally(_ status: GRPCStatus, cancelled: Bool = false) {
        guard let context, !isTerminated else { return }
        terminate(failingHeldWith: status)
        if cancelled {
            log?.cancelled()
        } else {
            log?.finished(code: status.code.rawValue, message: status.message, trailers: [])
        }
        context.receive(.end(status, [:]))
    }

    private func terminate(failingHeldWith error: Error) {
        isTerminated = true
        scheduledLocal?.cancel()
        scheduledLocal = nil
        if let id = pendingExchange {
            pendingExchange = nil
            pauseTask?.cancel()
            options.breakpointCenter.resolve(id, with: .abort)
        }
        pauseTask = nil
        let held = heldRequest
        heldRequest = []
        isHoldingRequest = false
        for item in held {
            item.promise?.fail(error)
        }
        inbound.removeAll()
        heldResponseMetadata = nil
        heldResponseMessages = []
    }
}
