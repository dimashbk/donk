import DonkCore
import Foundation

final class HTTPExchange: @unchecked Sendable {
    private static let workQueue = DispatchQueue(label: "dev.donk.network.exchange", qos: .userInitiated, attributes: .concurrent)
    static let liveUpdateInterval: TimeInterval = 0.1
    static let redirectSafetyHold: TimeInterval = 5

    let entryID = UUID()

    private let channel: ClientChannel
    private let context: SessionContext
    private let environment: CaptureEnvironment
    private let originalRequest: URLRequest
    private let maxBodySize: Int
    private let outerPriority: Float?
    private let lock = DonkLock()

    private var urlProtocol: URLProtocol?
    private var stopped = false
    private var terminal = false
    private var entryFinalized = false
    private var redirectSignaled = false
    private var innerTask: URLSessionTask?
    private var pauseTask: Task<Void, Never>?
    private var pendingWork: DispatchWorkItem?
    private var bridges: [ChallengeBridge] = []
    private var cacheDecision: CacheDecision?
    private var spillFile: URL?
    private var resolution = RuleResolution.empty
    private var origin: NetworkOrigin = .network
    private var requestURL: URL
    private var response: URLResponse?
    private var buffersResponse = false
    private var captured = Data()
    private var receivedBytes = 0
    private var isStreaming = false
    private var transactions: [TransactionMetrics] = []
    private var sentHeaders: [HTTPHeader] = []
    private var atomicRedirect: PendingRedirect?
    private var redirectBody = Data()
    private var clientGateOpen = true
    private var heldClientCalls: [() -> Void] = []
    private var liveScheduled = false
    private var lastLiveUpdate: TimeInterval = -.greatestFiniteMagnitude

    init(urlProtocol: URLProtocol, request: URLRequest, context: SessionContext, environment: CaptureEnvironment, channel: ClientChannel) {
        self.urlProtocol = urlProtocol
        self.context = context
        self.environment = environment
        self.channel = channel
        originalRequest = request
        maxBodySize = environment.store.maxBodySize
        requestURL = request.url ?? URL(fileURLWithPath: "/")
        outerPriority = urlProtocol.task?.priority
    }

    // MARK: - Lifecycle

    func start() {
        let initialBody: RequestBody?
        if let data = originalRequest.httpBody {
            initialBody = data.isEmpty ? RequestBody.none : .data(data)
        } else if originalRequest.httpBodyStream != nil {
            initialBody = nil
        } else {
            initialBody = RequestBody.none
        }
        let parts = RequestParts(request: originalRequest, body: initialBody ?? .none)
        let entry = NetworkEntry(
            id: entryID,
            kind: .http,
            state: .pending,
            origin: .network,
            request: HTTPMessage.requestSnapshot(parts, extraHeaders: context.additionalHeaders, limit: maxBodySize),
            timing: NetworkTiming(startedAt: Date())
        )
        environment.store.add(entry)
        if let initialBody {
            prepare(initialBody)
            return
        }
        guard let stream = originalRequest.httpBodyStream else {
            prepare(.none)
            return
        }
        BodyStreamReader.read(stream, captureLimit: maxBodySize, isCancelled: { [weak self] in self?.isStopped ?? true }) { [self] result in
            switch result {
            case let .success(body):
                recordRequestBody(body)
                prepare(body)
            case let .failure(error):
                fail(error)
            }
        }
    }

    func stop() {
        typealias Pending = (
            task: URLSessionTask?,
            pause: Task<Void, Never>?,
            work: DispatchWorkItem?,
            bridges: [ChallengeBridge],
            cache: CacheDecision?,
            terminal: Bool,
            redirected: Bool,
            outerError: Error?
        )
        let pending: Pending? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            let outerError = urlProtocol?.task?.error
            urlProtocol = nil
            let result: Pending = (innerTask, pauseTask, pendingWork, bridges, cacheDecision, terminal, redirectSignaled, outerError)
            innerTask = nil
            pauseTask = nil
            pendingWork = nil
            bridges = []
            cacheDecision = nil
            heldClientCalls = []
            return result
        }
        guard let pending else { return }
        pending.task?.cancel()
        pending.pause?.cancel()
        pending.work?.cancel()
        pending.bridges.forEach { $0.cancelIfPending() }
        pending.cache?.complete(nil)
        if pending.task == nil {
            removeSpillFile()
        }
        guard !pending.terminal else { return }
        if pending.redirected {
            finalizeEntry(state: .completed)
        } else if let error = pending.outerError, !Self.isCancellation(error) {
            finalizeEntry(state: .failed, error: error)
        } else {
            finalizeEntry(state: .cancelled, error: URLError(.cancelled))
        }
    }

    // MARK: - Request phase

    private func prepare(_ body: RequestBody) {
        guard !isStopped else {
            removeSpillFile()
            return
        }
        var parts = RequestParts(request: originalRequest, body: body)
        let resolution = environment.resolution(method: parts.method, url: parts.urlString)
        guard !resolution.isEmpty else {
            send(parts)
            return
        }
        lock.withLock { self.resolution = resolution }
        if let rule = resolution.transform, case let .rewrite(requestRewrite?, _) = rule.action {
            HTTPMessage.apply(requestRewrite, to: &parts)
            applyOrigin(.rewritten(rule: rule.name))
            recordRequest(parts)
        }
        guard let rule = resolution.breakpoint, case .breakpoint(true, _) = rule.action else {
            dispatch(parts)
            return
        }
        let original = HTTPMessage.editable(parts)
        pause(.request, payload: .request(original), rule: rule) { [self] decision in
            var parts = parts
            switch decision {
            case .abort:
                removeSpillFile()
                fail(URLError(.cancelled))
            case let .respond(response):
                removeSpillFile()
                applyOrigin(.breakpoint(edited: true))
                deliver(HTTPMessage.responseParts(response, url: parts.request.url ?? requestURL))
            case let .resume(.request(edited)):
                if edited != original {
                    HTTPMessage.apply(edited, original: original, to: &parts)
                    applyOrigin(.breakpoint(edited: true))
                    recordRequest(parts)
                } else {
                    applyOrigin(.breakpoint(edited: false))
                }
                dispatch(parts)
            case .resume(.response):
                applyOrigin(.breakpoint(edited: false))
                dispatch(parts)
            }
        }
    }

    private func dispatch(_ parts: RequestParts) {
        let transform = lock.withLock { resolution.transform }
        guard let rule = transform, case let .mapLocal(mock) = rule.action else {
            send(parts)
            return
        }
        removeSpillFile()
        applyOrigin(.mocked(rule: rule.name))
        let local = HTTPMessage.responseParts(mock, url: parts.request.url ?? requestURL)
        let work = DispatchWorkItem { [weak self] in
            self?.respond(with: local)
        }
        let scheduled: Bool = lock.withLock {
            guard !stopped else { return false }
            pendingWork = work
            return true
        }
        guard scheduled else { return }
        if mock.delay > 0, mock.delay.isFinite {
            Self.workQueue.asyncAfter(deadline: .now() + mock.delay, execute: work)
        } else {
            Self.workQueue.async(execute: work)
        }
    }

    private func send(_ parts: RequestParts) {
        let request = HTTPMessage.preparedInnerRequest(parts)
        let session = context.innerSession
        let task: URLSessionTask
        if let fileURL = parts.body.fileURL {
            task = session.uploadTask(with: request, fromFile: fileURL)
        } else {
            task = session.dataTask(with: request)
        }
        if let outerPriority {
            task.priority = outerPriority
        }
        let accepted: Bool = lock.withLock {
            guard !stopped else { return false }
            innerTask = task
            buffersResponse = Self.needsResponsePhase(resolution)
            requestURL = request.url ?? requestURL
            return true
        }
        guard accepted else {
            task.cancel()
            removeSpillFile()
            return
        }
        InnerSessionDelegate.shared.register(task, self)
        task.resume()
    }

    // MARK: - Inner session events

    func innerDidReceive(_ response: URLResponse) {
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        let streaming = HTTPMessage.isStreamingContentType(contentType)
        let buffers: Bool? = lock.withLock {
            guard !stopped, !terminal else { return nil }
            self.response = response
            if atomicRedirect != nil { return nil }
            isStreaming = streaming
            if streaming {
                buffersResponse = false
            }
            return buffersResponse
        }
        guard let buffers else { return }
        let snapshot = HTTPMessage.responseSnapshot(response, body: Data(), totalBytes: 0, limit: maxBodySize)
        let now = Date()
        environment.store.update(entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.response = snapshot
            if entry.timing.responseStartedAt == nil {
                entry.timing.responseStartedAt = now
            }
            if streaming, entry.state == .pending {
                entry.state = .streaming
            }
        }
        if !buffers {
            let outerResponse = HTTPMessage.detached(response)
            toClient { urlProtocol, client in
                client.urlProtocol(urlProtocol, didReceive: outerResponse, cacheStoragePolicy: .notAllowed)
            }
        }
    }

    func innerDidReceive(_ data: Data) {
        let state: (buffers: Bool, streaming: Bool)? = lock.withLock {
            guard !stopped, !terminal else { return nil }
            receivedBytes += data.count
            if atomicRedirect != nil {
                redirectBody.append(data)
                if captured.count < maxBodySize {
                    captured.append(data.prefix(maxBodySize - captured.count))
                }
                return nil
            }
            if buffersResponse {
                captured.append(data)
            } else if captured.count < maxBodySize {
                captured.append(data.prefix(maxBodySize - captured.count))
            }
            return (buffersResponse, isStreaming)
        }
        guard let state else { return }
        if !state.buffers {
            toClient { urlProtocol, client in
                client.urlProtocol(urlProtocol, didLoad: data)
            }
        }
        if state.streaming {
            scheduleLiveUpdate()
        }
    }

    func innerWillRedirect(response: HTTPURLResponse, newRequest: URLRequest, completion: @escaping (URLRequest?) -> Void) {
        let redirect = HTTPMessage.marked(newRequest, key: DonkURLProtocol.handledKey, value: nil)
        let outerTask: URLSessionTask?? = lock.withLock {
            guard !stopped, !terminal else { return nil }
            return .some(urlProtocol?.task)
        }
        guard let outerTask else {
            completion(nil)
            return
        }
        let atomic = OuterRedirectPolicy.asksDelegate(session: context.outerSession, task: outerTask)
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            self.response = response
            buffersResponse = false
            if atomic {
                atomicRedirect = PendingRedirect(request: redirect, response: response)
            } else {
                redirectSignaled = true
                clientGateOpen = false
            }
            return true
        }
        completion(nil)
        guard accepted else { return }
        let snapshot = HTTPMessage.responseSnapshot(response, body: Data(), totalBytes: 0, limit: maxBodySize)
        let now = Date()
        environment.store.update(entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.response = snapshot
            if entry.timing.responseStartedAt == nil {
                entry.timing.responseStartedAt = now
            }
        }
        guard !atomic else { return }
        toClient(bypassingGate: true) { urlProtocol, client in
            client.urlProtocol(urlProtocol, wasRedirectedTo: redirect, redirectResponse: response)
        }
        Self.workQueue.asyncAfter(deadline: .now() + Self.redirectSafetyHold) { [weak self] in
            self?.releaseClientCalls()
        }
    }

    func innerWillCache(_ proposed: CachedURLResponse, completion: @escaping (CachedURLResponse?) -> Void) {
        let decision = CacheDecision(completion)
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal, urlProtocol != nil else { return false }
            cacheDecision = decision
            return true
        }
        guard accepted else {
            decision.complete(nil)
            return
        }
        let outerSession = context.outerSession
        toClient(otherwise: { decision.complete(nil) }) { urlProtocol, _ in
            guard let target = OuterCacheDelegate.target(session: outerSession, task: urlProtocol.task) else {
                decision.complete(proposed)
                return
            }
            target.ask(proposed) { decision.complete($0) }
        }
    }

    func innerDidReceive(_ challenge: URLAuthenticationChallenge, completion: @escaping ChallengeBridge.Completion) {
        let bridge = ChallengeBridge(completion: completion)
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            bridges.removeAll { !$0.isPending }
            bridges.append(bridge)
            return true
        }
        guard accepted else {
            bridge.cancelIfPending()
            return
        }
        let forwarded = URLAuthenticationChallenge(authenticationChallenge: challenge, sender: bridge)
        toClient(otherwise: { bridge.cancelIfPending() }) { urlProtocol, client in
            client.urlProtocol(urlProtocol, didReceive: forwarded)
        }
    }

    func innerDidFinishCollecting(_ metrics: URLSessionTaskMetrics) {
        let mapped = MetricsMapper.map(metrics)
        let headers = MetricsMapper.sentHeaders(metrics)
        let finalized: Bool = lock.withLock {
            transactions = mapped
            sentHeaders = headers
            return entryFinalized
        }
        guard finalized, !mapped.isEmpty || !headers.isEmpty else { return }
        environment.store.update(entryID) { entry in
            if !mapped.isEmpty {
                entry.timing.transactions = mapped
            }
            entry.request.headers = HTTPMessage.mergedHeaders(entry.request.headers, extra: headers)
        }
    }

    func innerDidComplete(_ error: Error?) {
        removeSpillFile()
        let state: (buffers: Bool, response: URLResponse?, body: Data, redirect: PendingRedirect?, redirectBody: Data)? = lock.withLock {
            innerTask = nil
            guard !stopped, !terminal else { return nil }
            return (buffersResponse, response, captured, atomicRedirect, redirectBody)
        }
        guard let state else { return }
        if let redirect = state.redirect {
            deliverRedirect(redirect, response: state.response, body: state.redirectBody, error: error)
            return
        }
        if let error {
            fail(error)
            return
        }
        if state.buffers, let http = state.response as? HTTPURLResponse {
            respond(with: ResponseParts(response: http, body: state.body, fallbackURL: requestURL))
            return
        }
        finish()
    }

    // MARK: - Response phase

    private func respond(with local: ResponseParts) {
        guard !isStopped else { return }
        var parts = local
        let resolution = environment.isActive() ? lock.withLock { self.resolution } : .empty
        if let rule = resolution.transform, case let .rewrite(_, responseRewrite?) = rule.action {
            HTTPMessage.apply(responseRewrite, to: &parts)
            applyOrigin(.rewritten(rule: rule.name))
        }
        guard let rule = resolution.breakpoint, case .breakpoint(_, true) = rule.action else {
            deliver(parts)
            return
        }
        let original = HTTPMessage.editable(parts)
        recordResponse(parts)
        pause(.response, payload: .response(original), rule: rule) { [self] decision in
            var parts = parts
            switch decision {
            case .abort:
                fail(URLError(.cancelled))
            case let .respond(response):
                applyOrigin(.breakpoint(edited: true))
                deliver(HTTPMessage.responseParts(response, url: parts.url))
            case let .resume(.response(edited)):
                if edited != original {
                    HTTPMessage.apply(edited, original: original, to: &parts)
                    applyOrigin(.breakpoint(edited: true))
                } else {
                    applyOrigin(.breakpoint(edited: false))
                }
                deliver(parts)
            case .resume(.request):
                applyOrigin(.breakpoint(edited: false))
                deliver(parts)
            }
        }
    }

    private func deliver(_ parts: ResponseParts) {
        let response = HTTPMessage.makeResponse(parts)
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            terminal = true
            self.response = response
            return true
        }
        guard accepted else { return }
        removeSpillFile()
        finalizeEntry(state: .completed, response: HTTPMessage.responseSnapshot(parts, limit: maxBodySize))
        let body = parts.body
        toClient { urlProtocol, client in
            client.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client.urlProtocol(urlProtocol, didLoad: body)
            }
            client.urlProtocolDidFinishLoading(urlProtocol)
        }
    }

    private func deliverRedirect(_ redirect: PendingRedirect, response: URLResponse?, body: Data, error: Error?) {
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            terminal = true
            redirectSignaled = true
            return true
        }
        guard accepted else { return }
        if let error {
            finalizeEntry(state: .failed, error: error)
        } else {
            finalizeEntry(state: .completed)
        }
        let final = HTTPMessage.detached(response ?? redirect.response)
        toClient { urlProtocol, client in
            client.urlProtocol(urlProtocol, wasRedirectedTo: redirect.request, redirectResponse: redirect.response)
            if let error {
                client.urlProtocol(urlProtocol, didFailWithError: error)
                return
            }
            client.urlProtocol(urlProtocol, didReceive: final, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client.urlProtocol(urlProtocol, didLoad: body)
            }
            client.urlProtocolDidFinishLoading(urlProtocol)
        }
    }

    private func finish() {
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            terminal = true
            return true
        }
        guard accepted else { return }
        finalizeEntry(state: .completed)
        toClient { urlProtocol, client in
            client.urlProtocolDidFinishLoading(urlProtocol)
        }
    }

    private func fail(_ error: Error) {
        let accepted: Bool = lock.withLock {
            guard !stopped, !terminal else { return false }
            terminal = true
            return true
        }
        guard accepted else { return }
        removeSpillFile()
        finalizeEntry(state: Self.isCancellation(error) ? .cancelled : .failed, error: error)
        toClient { urlProtocol, client in
            client.urlProtocol(urlProtocol, didFailWithError: error)
        }
    }

    // MARK: - Breakpoints

    private func pause(_ phase: BreakpointPhase, payload: BreakpointPayload, rule: NetworkRule, completion: @escaping (BreakpointDecision) -> Void) {
        let exchange = PausedExchange(entryID: entryID, kind: .http, phase: phase, ruleName: rule.name, payload: payload)
        let center = environment.breakpoints
        environment.store.update(entryID) { entry in
            if entry.state.isInFlight {
                entry.state = .paused
            }
        }
        let task = Task { [self] in
            let decision = await center.pause(exchange)
            resume(after: decision, completion: completion)
        }
        let cancelNow: Bool = lock.withLock {
            if stopped { return true }
            pauseTask = task
            return false
        }
        if cancelNow {
            task.cancel()
        }
    }

    private func resume(after decision: BreakpointDecision, completion: (BreakpointDecision) -> Void) {
        let streaming: Bool? = lock.withLock {
            pauseTask = nil
            guard !stopped, !terminal else { return nil }
            return isStreaming
        }
        guard let streaming else { return }
        environment.store.update(entryID) { entry in
            if entry.state == .paused {
                entry.state = streaming ? .streaming : .pending
            }
        }
        completion(decision)
    }

    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func needsResponsePhase(_ resolution: RuleResolution) -> Bool {
        if let rule = resolution.transform, case .rewrite(_, .some) = rule.action { return true }
        if let rule = resolution.breakpoint, case .breakpoint(_, true) = rule.action { return true }
        return false
    }

    // MARK: - Store

    private func recordRequestBody(_ body: RequestBody) {
        lock.withLock { spillFile = body.fileURL }
        let limit = maxBodySize
        environment.store.update(entryID) { entry in
            entry.request.body = HTTPMessage.bodyData(body, contentType: entry.request.header("Content-Type"), limit: limit)
        }
    }

    private func recordRequest(_ parts: RequestParts) {
        let snapshot = HTTPMessage.requestSnapshot(parts, extraHeaders: context.additionalHeaders, limit: maxBodySize)
        environment.store.update(entryID) { $0.request = snapshot }
    }

    private func recordResponse(_ parts: ResponseParts) {
        let snapshot = HTTPMessage.responseSnapshot(parts, limit: maxBodySize)
        let now = Date()
        environment.store.update(entryID) { entry in
            entry.response = snapshot
            if entry.timing.responseStartedAt == nil {
                entry.timing.responseStartedAt = now
            }
        }
    }

    private func applyOrigin(_ candidate: NetworkOrigin) {
        let updated: NetworkOrigin? = lock.withLock {
            guard Self.rank(candidate) > Self.rank(origin) else { return nil }
            origin = candidate
            return candidate
        }
        guard let updated else { return }
        environment.store.update(entryID) { $0.origin = updated }
    }

    static func rank(_ origin: NetworkOrigin) -> Int {
        switch origin {
        case .network: return 0
        case let .breakpoint(edited): return edited ? 2 : 1
        case .rewritten: return 3
        case .mocked: return 4
        }
    }

    private func finalizeEntry(state: NetworkState, error: Error? = nil, response override: ResponseSnapshot? = nil) {
        let values: (response: ResponseSnapshot?, transactions: [TransactionMetrics], headers: [HTTPHeader])? = lock.withLock {
            guard !entryFinalized else { return nil }
            entryFinalized = true
            let snapshot = override ?? HTTPMessage.responseSnapshot(response, body: captured, totalBytes: receivedBytes, limit: maxBodySize)
            return (snapshot, transactions, sentHeaders)
        }
        guard let values else { return }
        let now = Date()
        let info = error.map { NetworkErrorInfo($0) }
        environment.store.update(entryID) { entry in
            entry.state = state
            if let snapshot = values.response {
                entry.response = snapshot
                if entry.timing.responseStartedAt == nil {
                    entry.timing.responseStartedAt = now
                }
            }
            if let info {
                entry.error = info
            }
            entry.timing.endedAt = now
            if !values.transactions.isEmpty {
                entry.timing.transactions = values.transactions
            }
            if !values.headers.isEmpty {
                entry.request.headers = HTTPMessage.mergedHeaders(entry.request.headers, extra: values.headers)
            }
        }
    }

    private func scheduleLiveUpdate() {
        let delay: TimeInterval? = lock.withLock {
            guard !liveScheduled, !entryFinalized else { return nil }
            liveScheduled = true
            let now = ProcessInfo.processInfo.systemUptime
            return max(0, lastLiveUpdate + Self.liveUpdateInterval - now)
        }
        guard let delay else { return }
        Self.workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushLiveUpdate()
        }
    }

    private func flushLiveUpdate() {
        let snapshot: ResponseSnapshot? = lock.withLock {
            liveScheduled = false
            guard !entryFinalized else { return nil }
            lastLiveUpdate = ProcessInfo.processInfo.systemUptime
            return HTTPMessage.responseSnapshot(response, body: captured, totalBytes: receivedBytes, limit: maxBodySize)
        }
        guard let snapshot else { return }
        environment.store.update(entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.response = snapshot
        }
    }

    // MARK: - Helpers

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func removeSpillFile() {
        let file: URL? = lock.withLock {
            defer { spillFile = nil }
            return spillFile
        }
        if let file {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func toClient(
        bypassingGate: Bool = false,
        otherwise fallback: (() -> Void)? = nil,
        _ body: @escaping (URLProtocol, URLProtocolClient) -> Void
    ) {
        let call = { [self] in
            let target: (URLProtocol, URLProtocolClient)? = lock.withLock {
                guard !stopped, let urlProtocol, let client = urlProtocol.client else { return nil }
                return (urlProtocol, client)
            }
            guard let target else {
                fallback?()
                return
            }
            body(target.0, target.1)
        }
        let held: Bool = lock.withLock {
            guard !bypassingGate, !clientGateOpen else { return false }
            heldClientCalls.append(call)
            return true
        }
        if !held {
            channel.perform(call)
        }
    }

    private func releaseClientCalls() {
        lock.withLock {
            clientGateOpen = true
            let calls = heldClientCalls
            heldClientCalls = []
            guard !calls.isEmpty else { return }
            channel.perform { calls.forEach { $0() } }
        }
    }
}

private struct PendingRedirect {
    let request: URLRequest
    let response: HTTPURLResponse
}
