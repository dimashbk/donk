import DonkCore
import Foundation

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

struct ScriptContext: Sendable {
    var webViewID: String
    var isMainFrame: Bool
    var mainPageURL: String?
}

struct DocumentResponse: Sendable {
    var token: UUID
    var url: String
    var isMainFrame: Bool
    var statusCode: Int
    var headers: [HTTPHeader]
    var pageURL: String?
}

enum NavigationEvent: Sendable {
    case loadingStarted(url: String?)
    case urlChanged(url: String?)
    case loadingStopped
    case response(DocumentResponse)
    case decision(token: UUID, policy: Int)
    case finished
    case failed(error: NetworkErrorInfo, failingURL: String?, isCancellation: Bool)
    case gone
}

final class WebCaptureEngine: @unchecked Sendable {
    static let shared = WebCaptureEngine()

    let store: NetworkStore
    private let settings: NetworkSettingsStore
    private let lock = DonkLock()
    private var recording = false
    private let queue = DispatchQueue(label: "dev.donk.webview.capture", qos: .utility)

    private var scripts: [String: ScriptRecord] = [:]
    private var scriptOrder: [String] = []
    private var documents: [String: DocumentState] = [:]
    private var recentDocuments: [DocumentRecord] = []
    private var tokens: [UUID: UUID] = [:]
    private var tokenOrder: [UUID] = []

    private static let scriptLimit = 4096
    private static let documentLimit = 128
    private static let tokenLimit = 256
    private static let documentMatchWindow: TimeInterval = 300

    init(store: NetworkStore = .shared, settings: NetworkSettingsStore = .shared) {
        self.store = store
        self.settings = settings
    }

    var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }

    func receiveScript(_ body: UncheckedBox<Any>, context: ScriptContext) {
        guard let dictionary = body.value as? [String: Any] else { return }
        let payload = UncheckedBox(value: dictionary)
        queue.async { [self] in
            processScript(payload.value, context: context)
        }
    }

    func cancelInFlight(date: Date = Date()) {
        queue.async { [self] in
            let message = "Capture stopped before the request finished"
            for recordKey in Array(scripts.keys) {
                if let record = forget(recordKey) {
                    finalize(record, date: date, message: message, completesStreams: false)
                }
            }
            for state in documents.values {
                if let open = state.mainEntry {
                    cancelDocument(open, date: date, message: message)
                }
            }
            for record in recentDocuments {
                cancelDocument(record.entryID, date: date, message: message)
            }
            documents.removeAll()
        }
    }

    func receiveNavigation(_ event: NavigationEvent, webViewID: String, date: Date = Date()) {
        queue.async { [self] in
            processNavigation(event, webViewID: webViewID, date: date)
        }
    }

    // MARK: - Gating

    private func canCapture(_ url: String) -> Bool {
        guard isRecording, store.isCaptureEnabled else { return false }
        let host = RequestSnapshot(url: url).host
        return !HostPattern.matchesAny(host, patterns: settings.settings.bypassHosts)
    }

    // MARK: - Script messages

    private func processScript(_ body: [String: Any], context: ScriptContext) {
        guard let kind = body.string("k") else { return }
        switch kind {
        case "start": handleStart(body, context: context)
        case "head": handleHead(body, context: context)
        case "end": handleEnd(body, context: context)
        case "fail": handleFail(body, context: context)
        case "patch": handlePatch(body, context: context)
        case "ws": handleSocket(body, context: context)
        case "es": handleEventSource(body, context: context)
        case "res": handleResources(body, context: context)
        case "nav": handleNavigationTiming(body, context: context)
        case "gone": handleGone(body, context: context)
        default: break
        }
    }

    private func handleStart(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id"), let url = body.string("u"), canCapture(url) else { return }
        let initiator = body.string("i").flatMap(WebInitiator.init(rawValue:)) ?? .fetch
        let headers = WebPayload.headers(body["h"])
        let requestBody = WebPayload.body(body["b"], contentType: headers.value(for: "Content-Type"), limit: store.maxBodySize)
        let method = (body.string("m") ?? "GET").uppercased()
        let level: CaptureLevel = (initiator == .websocket || initiator == .eventSource) ? .metadata : .full
        let entry = NetworkEntry(
            kind: .webView,
            state: .pending,
            request: RequestSnapshot(url: url, method: method, headers: headers, body: requestBody),
            timing: NetworkTiming(startedAt: body.date("t") ?? Date()),
            web: WebViewDetails(
                pageURL: body.string("p") ?? context.mainPageURL,
                initiator: initiator,
                captureLevel: level,
                webViewID: context.webViewID
            )
        )
        store.add(entry)
        remember(ScriptRecord(entryID: entry.id, initiator: initiator, webViewID: context.webViewID), for: key(context, id))
    }

    private func handleHead(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id"), let record = scripts[key(context, id)] else { return }
        let headers = WebPayload.headers(body["h"])
        let status = body.int("st") ?? 0
        let date = body.date("t") ?? Date()
        let isOpaque = body.string("ty").map { $0.hasPrefix("opaque") } ?? false
        store.update(record.entryID) { entry in
            entry.response = ResponseSnapshot(statusCode: status, headers: headers, body: entry.response?.body)
            entry.timing.responseStartedAt = date
            if isOpaque { entry.web?.captureLevel = .metadata }
        }
    }

    private func handleEnd(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id"), let record = forget(key(context, id)) else { return }
        let headers = body["h"] != nil ? WebPayload.headers(body["h"]) : nil
        let status = body.int("st")
        let date = body.date("t") ?? Date()
        let responseStart = body.date("rt")
        let isMetadataOnly = body.string("lvl") == "metadata"
        let contentType = headers?.value(for: "Content-Type") ?? store.entry(record.entryID)?.response?.header("Content-Type")
        let parsed = WebPayload.body(body["b"], contentType: contentType, limit: store.maxBodySize)
        store.update(record.entryID) { entry in
            guard entry.state.isInFlight else { return }
            if let status {
                entry.response = ResponseSnapshot(statusCode: status, headers: headers ?? entry.response?.headers ?? [], body: entry.response?.body)
            }
            if let parsed, entry.response != nil {
                entry.response?.body = parsed
            }
            if entry.timing.responseStartedAt == nil {
                entry.timing.responseStartedAt = responseStart
            }
            entry.timing.endedAt = max(date, entry.timing.startedAt)
            entry.state = .completed
            if isMetadataOnly { entry.web?.captureLevel = .metadata }
        }
    }

    private func handleFail(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id"), let record = forget(key(context, id)) else { return }
        let reason = body.string("c") ?? "network"
        let name = body.string("en")
        var message = body.string("e") ?? "Request failed"
        if let name, !name.isEmpty, name != "Error", !message.contains(name) {
            message += " (\(name))"
        }
        let error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: WebPayload.errorCode(for: reason), message: message)
        let date = body.date("t") ?? Date()
        store.update(record.entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.state = reason == "abort" ? .cancelled : .failed
            entry.error = error
            entry.timing.endedAt = max(date, entry.timing.startedAt)
        }
    }

    private func handlePatch(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id") else { return }
        let entryID = scripts[key(context, id)]?.entryID ?? recentlyFinished(key(context, id))
        guard let entryID else { return }
        let contentType = store.entry(entryID)?.request.header("Content-Type")
        guard let parsed = WebPayload.body(body["rb"], contentType: contentType, limit: store.maxBodySize) else { return }
        store.update(entryID) { entry in
            entry.request.body = parsed
        }
    }

    private func handleSocket(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id") else { return }
        let recordKey = key(context, id)
        guard var record = scripts[recordKey] else { return }
        let event = body.string("ev") ?? ""
        let date = body.date("t") ?? Date()
        record.counters.update(from: body)
        switch event {
        case "open":
            record.counters.opened = true
            scripts[recordKey] = record
            var headers = [HTTPHeader(name: "Upgrade", value: "websocket"), HTTPHeader(name: "Connection", value: "Upgrade")]
            if let value = body.string("pr"), !value.isEmpty { headers.append(HTTPHeader(name: "Sec-WebSocket-Protocol", value: value)) }
            if let value = body.string("ex"), !value.isEmpty { headers.append(HTTPHeader(name: "Sec-WebSocket-Extensions", value: value)) }
            let summary = record.counters.socketSummary
            store.update(record.entryID) { entry in
                guard entry.state.isInFlight else { return }
                entry.state = .streaming
                entry.response = ResponseSnapshot(statusCode: 101, headers: headers, body: summary)
                entry.timing.responseStartedAt = date
            }
        case "close":
            forget(recordKey)
            record.counters.closeCode = body.int("code")
            record.counters.closeReason = body.string("reason")
            let clean = body.bool("clean")
            let errored = body.bool("err")
            let counters = record.counters
            store.update(record.entryID) { entry in
                guard entry.state.isInFlight else { return }
                entry.timing.endedAt = max(date, entry.timing.startedAt)
                entry.timing.transactions = [counters.metrics]
                if entry.response != nil { entry.response?.body = counters.socketSummary }
                if !counters.opened {
                    entry.state = .failed
                    entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: counters.closeCode ?? 1006, message: "WebSocket connection failed")
                } else if errored && !clean {
                    entry.state = .failed
                    entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: counters.closeCode ?? 1006, message: "WebSocket closed with an error")
                } else {
                    entry.state = .completed
                }
            }
        default:
            scripts[recordKey] = record
            let counters = record.counters
            store.update(record.entryID) { entry in
                entry.timing.transactions = [counters.metrics]
                if entry.response != nil { entry.response?.body = counters.socketSummary }
            }
        }
    }

    private func handleEventSource(_ body: [String: Any], context: ScriptContext) {
        guard let id = body.string("id") else { return }
        let recordKey = key(context, id)
        guard var record = scripts[recordKey] else { return }
        let event = body.string("ev") ?? ""
        let date = body.date("t") ?? Date()
        record.counters.update(from: body)
        let isTerminal = event == "close" || (event == "error" && body.bool("fatal"))
        switch event {
        case "open":
            record.counters.opened = true
            record.counters.reconnecting = false
            scripts[recordKey] = record
            let summary = record.counters.eventSourceSummary
            store.update(record.entryID) { entry in
                guard entry.state.isInFlight else { return }
                entry.state = .streaming
                if entry.response == nil {
                    entry.response = ResponseSnapshot(statusCode: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/event-stream")])
                    entry.timing.responseStartedAt = date
                }
                entry.response?.body = summary
            }
        case _ where isTerminal:
            forget(recordKey)
            record.counters.reconnecting = false
            let counters = record.counters
            let isClose = event == "close"
            store.update(record.entryID) { entry in
                guard entry.state.isInFlight else { return }
                entry.timing.endedAt = max(date, entry.timing.startedAt)
                entry.timing.transactions = [counters.metrics]
                if entry.response != nil { entry.response?.body = counters.eventSourceSummary }
                if isClose {
                    entry.state = .completed
                } else {
                    entry.state = .failed
                    let message = counters.opened ? "EventSource stream closed by an error" : "EventSource connection failed"
                    entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: -1, message: message)
                }
            }
        default:
            if event == "error" { record.counters.reconnecting = true }
            scripts[recordKey] = record
            let counters = record.counters
            store.update(record.entryID) { entry in
                entry.timing.transactions = [counters.metrics]
                if entry.response != nil { entry.response?.body = counters.eventSourceSummary }
            }
        }
    }

    private func handleResources(_ body: [String: Any], context: ScriptContext) {
        guard let list = body["list"] as? [Any] else { return }
        let pageURL = body.string("p") ?? context.mainPageURL
        for item in list {
            guard let resource = item as? [String: Any], let url = resource.string("u"), canCapture(url) else { continue }
            let initiatorType = resource.string("it") ?? "other"
            if initiatorType == "iframe" || initiatorType == "frame" {
                mergeFrameResource(resource, url: url, pageURL: pageURL, context: context)
                continue
            }
            let timing = WebPayload.timing(resource)
            let status = resource.int("st")
            let sizeBody = WebPayload.sizeOnlyBody(resource, contentType: nil)
            var response: ResponseSnapshot?
            if status != nil || sizeBody != nil {
                response = ResponseSnapshot(statusCode: status ?? 0, headers: [], body: sizeBody)
            }
            let entry = NetworkEntry(
                kind: .webView,
                state: .completed,
                request: RequestSnapshot(url: url, method: "GET"),
                response: response,
                timing: timing,
                web: WebViewDetails(pageURL: pageURL, initiator: .resource, captureLevel: .observed, webViewID: context.webViewID)
            )
            store.add(entry)
        }
    }

    private func handleGone(_ body: [String: Any], context: ScriptContext) {
        guard let ids = body["ids"] as? [Any] else { return }
        let date = body.date("t") ?? Date()
        for case let id as String in ids {
            guard let record = forget(key(context, id)) else { continue }
            finalize(record, date: date, message: "Page unloaded before the request finished")
        }
    }

    // MARK: - Documents

    private func handleNavigationTiming(_ body: [String: Any], context: ScriptContext) {
        guard let url = body.string("u") else { return }
        let normalized = WebPayload.normalize(url)
        let now = Date()
        let timing = WebPayload.timing(body, startKey: "t0", endKeys: ["responseEnd", "load"])
        let status = body.int("st")
        let sizeBody = WebPayload.sizeOnlyBody(body, contentType: nil)
        if let index = recentDocuments.lastIndex(where: {
            $0.webViewID == context.webViewID && $0.isMainFrame == context.isMainFrame && !$0.hasNavigationTiming
                && $0.normalizedURL == normalized && now.timeIntervalSince($0.createdAt) < Self.documentMatchWindow
        }) {
            recentDocuments[index].hasNavigationTiming = true
            let entryID = recentDocuments[index].entryID
            let hasParentTiming = recentDocuments[index].hasParentTiming
            store.update(entryID) { entry in
                if !hasParentTiming {
                    entry.timing.startedAt = min(entry.timing.startedAt, timing.startedAt)
                    if let end = timing.endedAt {
                        entry.timing.endedAt = max(end, entry.timing.startedAt)
                    }
                    if !timing.transactions.isEmpty {
                        entry.timing.transactions = timing.transactions
                    }
                }
                if entry.response == nil, let status {
                    entry.response = ResponseSnapshot(statusCode: status)
                }
                if entry.response != nil, entry.response?.body == nil, var sizeBody {
                    sizeBody.contentType = entry.response?.header("Content-Type")
                    entry.response?.body = sizeBody
                }
                if entry.state.isInFlight {
                    entry.state = .completed
                    if entry.timing.endedAt == nil { entry.timing.endedAt = max(now, entry.timing.startedAt) }
                }
            }
            if context.isMainFrame, documents[context.webViewID]?.mainEntry == entryID {
                documents[context.webViewID]?.mainEntry = nil
            }
            return
        }
        guard canCapture(url) else { return }
        var response: ResponseSnapshot?
        if status != nil || sizeBody != nil {
            response = ResponseSnapshot(statusCode: status ?? 0, headers: [], body: sizeBody)
        }
        var finalTiming = timing
        if finalTiming.endedAt == nil { finalTiming.endedAt = max(now, finalTiming.startedAt) }
        let entry = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: url, method: "GET"),
            response: response,
            timing: finalTiming,
            web: WebViewDetails(
                pageURL: context.isMainFrame ? url : (context.mainPageURL ?? body.string("p")),
                initiator: .document,
                captureLevel: .observed,
                webViewID: context.webViewID
            )
        )
        store.add(entry)
        var record = DocumentRecord(entryID: entry.id, webViewID: context.webViewID, normalizedURL: normalized, isMainFrame: context.isMainFrame, createdAt: now)
        record.hasNavigationTiming = true
        rememberDocument(record)
    }

    private func mergeFrameResource(_ resource: [String: Any], url: String, pageURL: String?, context: ScriptContext) {
        let normalized = WebPayload.normalize(url)
        let timing = WebPayload.timing(resource)
        let now = Date()
        if let index = recentDocuments.lastIndex(where: {
            $0.webViewID == context.webViewID && !$0.isMainFrame && !$0.hasParentTiming
                && $0.normalizedURL == normalized && now.timeIntervalSince($0.createdAt) < Self.documentMatchWindow
        }) {
            recentDocuments[index].hasParentTiming = true
            store.update(recentDocuments[index].entryID) { entry in
                entry.timing.startedAt = timing.startedAt
                if let responseStart = timing.responseStartedAt { entry.timing.responseStartedAt = responseStart }
                if let end = timing.endedAt { entry.timing.endedAt = max(end, timing.startedAt) }
                if !timing.transactions.isEmpty { entry.timing.transactions = timing.transactions }
                if entry.state.isInFlight { entry.state = .completed }
            }
            return
        }
        var finalTiming = timing
        if finalTiming.endedAt == nil { finalTiming.endedAt = max(now, finalTiming.startedAt) }
        let entry = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: url, method: "GET"),
            timing: finalTiming,
            web: WebViewDetails(pageURL: pageURL, initiator: .document, captureLevel: .observed, webViewID: context.webViewID)
        )
        store.add(entry)
        var record = DocumentRecord(entryID: entry.id, webViewID: context.webViewID, normalizedURL: normalized, isMainFrame: false, createdAt: now)
        record.hasParentTiming = true
        rememberDocument(record)
    }

    private func processNavigation(_ event: NavigationEvent, webViewID: String, date: Date) {
        var state = documents[webViewID] ?? DocumentState()
        defer {
            if case .gone = event {
                documents[webViewID] = nil
            } else {
                documents[webViewID] = state
            }
        }
        switch event {
        case .loadingStarted(let url):
            if let open = state.mainEntry {
                completeDocument(open, date: date)
            }
            completeSubframeDocuments(of: webViewID, date: date)
            state.mainEntry = nil
            state.loadingSince = date
            if let url, WebPayload.isReportableDocument(url) {
                state.mainEntry = createDocument(webViewID: webViewID, url: url, isMainFrame: true, startedAt: date, pageURL: url)
            }
        case .urlChanged(let url):
            guard let since = state.loadingSince, let url, WebPayload.isReportableDocument(url) else { return }
            if let open = state.mainEntry {
                updateDocumentURL(open, url: url)
            } else {
                state.mainEntry = createDocument(webViewID: webViewID, url: url, isMainFrame: true, startedAt: since, pageURL: url)
            }
        case .response(let response):
            let entryID: UUID?
            if response.isMainFrame {
                if state.mainEntry == nil {
                    state.mainEntry = createDocument(webViewID: webViewID, url: response.url, isMainFrame: true, startedAt: state.loadingSince ?? date, pageURL: response.url)
                }
                entryID = state.mainEntry
            } else {
                entryID = createDocument(webViewID: webViewID, url: response.url, isMainFrame: false, startedAt: date, pageURL: response.pageURL)
            }
            guard let entryID else { return }
            updateDocumentURL(entryID, url: response.url)
            store.update(entryID) { entry in
                entry.request.url = response.url
                entry.response = ResponseSnapshot(statusCode: response.statusCode, headers: response.headers, body: entry.response?.body)
                entry.timing.responseStartedAt = date
                entry.web?.captureLevel = .metadata
            }
            rememberToken(response.token, entryID: entryID)
        case .decision(let token, let policy):
            guard let entryID = tokens[token], policy == 0 else { return }
            store.update(entryID) { entry in
                guard entry.state.isInFlight else { return }
                entry.state = .cancelled
                entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: NSURLErrorCancelled, message: "Navigation response cancelled by the navigation delegate")
                entry.timing.endedAt = max(date, entry.timing.startedAt)
            }
            if state.mainEntry == entryID { state.mainEntry = nil }
        case .finished:
            if let open = state.mainEntry {
                completeDocument(open, date: date)
                state.mainEntry = nil
            }
        case .loadingStopped:
            if let open = state.mainEntry {
                completeDocument(open, date: date)
                state.mainEntry = nil
            }
            state.loadingSince = nil
            completeSubframeDocuments(of: webViewID, date: date)
        case .failed(let error, let failingURL, let isCancellation):
            var target = state.mainEntry
            if target == nil, let failingURL, WebPayload.isReportableDocument(failingURL) {
                target = createDocument(webViewID: webViewID, url: failingURL, isMainFrame: true, startedAt: state.loadingSince ?? date, pageURL: failingURL)
            }
            state.mainEntry = nil
            guard let target else { return }
            store.update(target) { entry in
                guard entry.state.isInFlight else { return }
                entry.state = isCancellation ? .cancelled : .failed
                entry.error = error
                entry.timing.endedAt = max(date, entry.timing.startedAt)
            }
        case .gone:
            if let open = state.mainEntry {
                cancelDocument(open, date: date)
            }
            for index in recentDocuments.indices where recentDocuments[index].webViewID == webViewID {
                cancelDocument(recentDocuments[index].entryID, date: date)
            }
            recentDocuments.removeAll { $0.webViewID == webViewID }
            let prefix = webViewID + "|"
            for recordKey in scripts.keys where recordKey.hasPrefix(prefix) {
                if let record = forget(recordKey) {
                    finalize(record, date: date, message: "Web view was deallocated before the request finished")
                }
            }
        }
    }

    private func createDocument(webViewID: String, url: String, isMainFrame: Bool, startedAt: Date, pageURL: String?) -> UUID? {
        guard canCapture(url) else { return nil }
        let entry = NetworkEntry(
            kind: .webView,
            state: .pending,
            request: RequestSnapshot(url: url, method: "GET"),
            timing: NetworkTiming(startedAt: startedAt),
            web: WebViewDetails(pageURL: pageURL, initiator: .document, captureLevel: .observed, webViewID: webViewID)
        )
        store.add(entry)
        rememberDocument(DocumentRecord(entryID: entry.id, webViewID: webViewID, normalizedURL: WebPayload.normalize(url), isMainFrame: isMainFrame, createdAt: Date()))
        return entry.id
    }

    private func updateDocumentURL(_ entryID: UUID, url: String) {
        if let index = recentDocuments.lastIndex(where: { $0.entryID == entryID }) {
            recentDocuments[index].normalizedURL = WebPayload.normalize(url)
        }
        store.update(entryID) { entry in
            if entry.request.url != url, entry.response == nil {
                entry.request.url = url
                if entry.web?.pageURL != nil, entry.web?.initiator == .document {
                    entry.web?.pageURL = url
                }
            }
        }
    }

    private func completeDocument(_ entryID: UUID, date: Date) {
        store.update(entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.state = .completed
            if entry.timing.endedAt == nil {
                entry.timing.endedAt = max(date, entry.timing.startedAt)
            }
        }
    }

    private func cancelDocument(_ entryID: UUID, date: Date, message: String = "Web view was deallocated while loading") {
        store.update(entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.state = .cancelled
            entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: NSURLErrorCancelled, message: message)
            entry.timing.endedAt = max(date, entry.timing.startedAt)
        }
    }

    private func completeSubframeDocuments(of webViewID: String, date: Date) {
        for record in recentDocuments where record.webViewID == webViewID && !record.isMainFrame {
            completeDocument(record.entryID, date: date)
        }
    }

    private func finalize(_ record: ScriptRecord, date: Date, message: String, completesStreams: Bool = true) {
        let isStream = completesStreams && (record.initiator == .websocket || record.initiator == .eventSource)
        let counters = record.counters
        store.update(record.entryID) { entry in
            guard entry.state.isInFlight else { return }
            entry.timing.endedAt = max(date, entry.timing.startedAt)
            if isStream && entry.state == .streaming {
                entry.state = .completed
                entry.timing.transactions = [counters.metrics]
                if entry.response != nil {
                    entry.response?.body = record.initiator == .websocket ? counters.socketSummary : counters.eventSourceSummary
                }
            } else {
                entry.state = .cancelled
                entry.error = NetworkErrorInfo(domain: WebPayload.errorDomain, code: NSURLErrorCancelled, message: message)
            }
        }
    }

    // MARK: - Bookkeeping

    private func key(_ context: ScriptContext, _ id: String) -> String {
        context.webViewID + "|" + id
    }

    private func remember(_ record: ScriptRecord, for key: String) {
        if scripts.updateValue(record, forKey: key) == nil {
            scriptOrder.append(key)
        }
        if scriptOrder.count > Self.scriptLimit * 2 {
            scriptOrder.removeAll { scripts[$0] == nil }
        }
        while scripts.count > Self.scriptLimit, !scriptOrder.isEmpty {
            scripts.removeValue(forKey: scriptOrder.removeFirst())
        }
        finished.removeValue(forKey: key)
    }

    @discardableResult
    private func forget(_ key: String) -> ScriptRecord? {
        guard let record = scripts.removeValue(forKey: key) else { return nil }
        finished[key] = record.entryID
        finishedOrder.append(key)
        if finishedOrder.count > 256 {
            finished.removeValue(forKey: finishedOrder.removeFirst())
        }
        return record
    }

    private var finished: [String: UUID] = [:]
    private var finishedOrder: [String] = []

    private func recentlyFinished(_ key: String) -> UUID? {
        finished[key]
    }

    private func rememberDocument(_ record: DocumentRecord) {
        recentDocuments.append(record)
        if recentDocuments.count > Self.documentLimit {
            recentDocuments.removeFirst(recentDocuments.count - Self.documentLimit)
        }
    }

    private func rememberToken(_ token: UUID, entryID: UUID) {
        tokens[token] = entryID
        tokenOrder.append(token)
        if tokenOrder.count > Self.tokenLimit {
            tokens.removeValue(forKey: tokenOrder.removeFirst())
        }
    }
}

// MARK: - Records

private struct ScriptRecord {
    let entryID: UUID
    let initiator: WebInitiator
    let webViewID: String
    var counters = StreamCounters()
}

private struct DocumentState {
    var loadingSince: Date?
    var mainEntry: UUID?
}

private struct DocumentRecord {
    let entryID: UUID
    let webViewID: String
    var normalizedURL: String
    let isMainFrame: Bool
    let createdAt: Date
    var hasNavigationTiming = false
    var hasParentTiming = false
}

struct StreamCounters: Equatable {
    var sent = 0
    var sentBytes = 0
    var received = 0
    var receivedBytes = 0
    var reconnects = 0
    var opened = false
    var reconnecting = false
    var closeCode: Int?
    var closeReason: String?

    mutating func update(from body: [String: Any]) {
        if let value = body.int("tx") { sent = value }
        if let value = body.int("txb") { sentBytes = value }
        if let value = body.int("rx") { received = value }
        if let value = body.int("rxb") { receivedBytes = value }
        if let value = body.int("re") { reconnects = value }
    }

    var metrics: TransactionMetrics {
        TransactionMetrics(requestBodyBytes: Int64(sentBytes), responseBodyBytes: Int64(receivedBytes))
    }

    var socketSummary: BodyData {
        var lines = [
            "Messages sent: \(sent) (\(WebPayload.bytes(sentBytes)))",
            "Messages received: \(received) (\(WebPayload.bytes(receivedBytes)))",
        ]
        if let closeCode {
            lines.append("Close code: \(closeCode)\(WebPayload.closeCodeName(closeCode).map { " (\($0))" } ?? "")")
        }
        if let closeReason, !closeReason.isEmpty {
            lines.append("Close reason: \(closeReason)")
        }
        lines.append("Message payloads are not recorded.")
        return BodyData(text: lines.joined(separator: "\n"))
    }

    var eventSourceSummary: BodyData {
        var lines = ["Messages received: \(received) (\(WebPayload.bytes(receivedBytes)))"]
        if reconnects > 0 { lines.append("Reconnects: \(reconnects)") }
        if reconnecting { lines.append("Connection lost, reconnecting") }
        lines.append("Only default \"message\" events are counted; payloads are not recorded.")
        return BodyData(text: lines.joined(separator: "\n"))
    }
}
