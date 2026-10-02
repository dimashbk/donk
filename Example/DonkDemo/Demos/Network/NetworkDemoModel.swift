import Combine
import Donk
import DonkUI
import Foundation

@MainActor
final class NetworkDemoModel: ObservableObject {
    static let mockRuleID = UUID(uuidString: "D0CC0000-0000-4000-8000-000000000001")!
    static let breakpointRuleID = UUID(uuidString: "D0CC0000-0000-4000-8000-000000000002")!

    @Published private(set) var count = 0
    @Published private(set) var entries: [NetworkEntry] = []
    @Published private(set) var paused: [PausedExchange] = []
    @Published private(set) var isRunning = false
    @Published private(set) var sampleRulesActive = false
    @Published private(set) var running: Set<NetworkDemoAction> = []
    @Published private(set) var lastResult: String?

    private var cancellables = Set<AnyCancellable>()
    private var asyncSession: URLSession?
    private var delegateSession: URLSession?
    private let sessionDelegate = DemoSessionDelegate()

    init() {
        DonkNetworkCapture.start(NetworkCaptureConfiguration())
        isRunning = DonkNetworkCapture.isRunning
        refresh()
        refreshRules()
        paused = BreakpointCenter.shared.pending
        NetworkStore.shared.events
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        BreakpointCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                guard let self else { return }
                if pending.count > self.paused.count, let newest = pending.last {
                    DonkToast.show("Paused: \(newest.ruleName)", icon: "pause.circle.fill", tone: .warning, duration: 3)
                }
                self.paused = pending
            }
            .store(in: &cancellables)
        RuleStore.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRules() }
            .store(in: &cancellables)
    }

    var recent: [NetworkEntry] { Array(entries.prefix(5)) }

    // MARK: - Capture

    func setRunning(_ isOn: Bool) {
        if isOn {
            DonkNetworkCapture.start(NetworkCaptureConfiguration())
        } else {
            DonkNetworkCapture.stop()
        }
        isRunning = DonkNetworkCapture.isRunning
        DonkHaptics.light()
    }

    func clear() {
        NetworkStore.shared.clear(keepPinned: false)
        lastResult = nil
        refresh()
        DonkHaptics.light()
    }

    private func refresh() {
        entries = NetworkStore.shared.snapshot()
        count = NetworkStore.shared.count
    }

    // MARK: - Rules

    func addSampleRules() {
        let mockBody = #"{"userId":1,"id":1,"title":"Mocked by donk — this never left the device","completed":true}"#
        RuleStore.shared.add(NetworkRule(
            id: Self.mockRuleID,
            name: "Demo · mock /todos/1",
            match: RuleMatch(kinds: [.http], method: "GET", url: URLMatcher(pattern: #"jsonplaceholder\.typicode\.com/todos/1$"#, mode: .regex)),
            action: .mapLocal(MockResponse(statusCode: 200, headers: [HTTPHeader(name: "X-Donk-Mock", value: "demo")], body: mockBody, delay: 0.4))
        ))
        RuleStore.shared.add(NetworkRule(
            id: Self.breakpointRuleID,
            name: "Demo · pause /anything",
            match: RuleMatch(kinds: [.http], url: URLMatcher(pattern: "httpbin.org/anything")),
            action: .breakpoint(request: true, response: false)
        ))
        RuleStore.shared.isEnabled = true
        DonkToast.show("Sample rules added", icon: "wand.and.stars", tone: .success)
    }

    func runMockedRequest() {
        let mockBody = #"{"userId":1,"id":1,"title":"Mocked by donk — this never left the device","completed":true}"#
        RuleStore.shared.add(NetworkRule(
            id: Self.mockRuleID,
            name: "Demo · mock /todos/1",
            match: RuleMatch(kinds: [.http], method: "GET", url: URLMatcher(pattern: #"jsonplaceholder\.typicode\.com/todos/1$"#, mode: .regex)),
            action: .mapLocal(MockResponse(statusCode: 200, headers: [HTTPHeader(name: "X-Donk-Mock", value: "demo")], body: mockBody, delay: 0.4))
        ))
        RuleStore.shared.isEnabled = true
        Task {
            let summary = await perform(.getJSON)
            let origin = NetworkStore.shared.snapshot().first { $0.request.url.hasSuffix("/todos/1") }?.origin
            lastResult = "Mocked GET JSON: \(summary)"
            print("[donk-demo] mocked-getJSON: \(summary) origin=\(origin.map { String(describing: $0) } ?? "none")")
            RuleStore.shared.remove(Self.mockRuleID)
        }
    }

    func removeSampleRules() {
        RuleStore.shared.remove(Self.mockRuleID)
        RuleStore.shared.remove(Self.breakpointRuleID)
        DonkToast.show("Sample rules removed", icon: "trash", tone: .neutral)
    }

    private func refreshRules() {
        let ids = Set(RuleStore.shared.rules.map(\.id))
        sampleRulesActive = ids.contains(Self.mockRuleID) || ids.contains(Self.breakpointRuleID)
    }

    // MARK: - Breakpoints

    func resume(_ exchange: PausedExchange) {
        BreakpointCenter.shared.resolve(exchange.id, with: .resume(exchange.payload))
    }

    func editAndResume(_ exchange: PausedExchange) {
        switch exchange.payload {
        case var .request(request):
            request.headers.append(HTTPHeader(name: "X-Donk-Edited", value: "breakpoint"))
            if !request.bodyIsBinary {
                request.body = #"{"edited":true,"by":"donk breakpoint"}"#
            }
            BreakpointCenter.shared.resolve(exchange.id, with: .resume(.request(request)))
        case var .response(response):
            response.headers.append(HTTPHeader(name: "X-Donk-Edited", value: "breakpoint"))
            BreakpointCenter.shared.resolve(exchange.id, with: .resume(.response(response)))
        }
    }

    func respondLocally(_ exchange: PausedExchange) {
        let response = EditableResponse(
            statusCode: 200,
            headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
            body: #"{"answeredBy":"donk breakpoint","server":"never contacted"}"#
        )
        BreakpointCenter.shared.resolve(exchange.id, with: .respond(response))
    }

    func abort(_ exchange: PausedExchange) {
        BreakpointCenter.shared.resolve(exchange.id, with: .abort)
    }

    // MARK: - Actions

    func run(_ action: NetworkDemoAction) {
        running.insert(action)
        Task {
            let summary = await perform(action)
            running.remove(action)
            lastResult = "\(action.title): \(summary)"
            print("[donk-demo] \(action.rawValue): \(summary)")
        }
    }

    func runAll(_ actions: [NetworkDemoAction]) {
        for action in actions {
            run(action)
        }
    }

    private func perform(_ action: NetworkDemoAction) async -> String {
        switch action {
        case .getJSON:
            return await fetch(URLRequest(url: Endpoints.todo))
        case .postJSON:
            return await fetch(jsonRequest(Endpoints.httpbin("post"), method: "POST", body: ["name": "donk", "kind": "debugger", "stars": 42]))
        case .put:
            return await fetch(jsonRequest(Endpoints.httpbin("put"), method: "PUT", body: ["id": 7, "title": "replaced"]))
        case .patch:
            return await fetch(jsonRequest(Endpoints.httpbin("patch"), method: "PATCH", body: ["title": "patched"]))
        case .delete:
            var request = URLRequest(url: Endpoints.httpbin("delete"))
            request.httpMethod = "DELETE"
            return await fetch(request)
        case .notFound:
            return await fetch(URLRequest(url: Endpoints.httpbin("status/404")))
        case .serverError:
            return await fetch(URLRequest(url: Endpoints.httpbin("status/500")))
        case .redirect:
            return await fetch(URLRequest(url: Endpoints.httpbin("redirect/2")))
        case .slow:
            return await fetch(URLRequest(url: Endpoints.httpbin("delay/3")))
        case .image:
            return await fetch(URLRequest(url: Endpoints.image))
        case .largeJSON:
            return await fetch(URLRequest(url: Endpoints.photos))
        case .gzip:
            return await fetch(URLRequest(url: Endpoints.httpbin("gzip")))
        case .chunked:
            return await streamLines(Endpoints.httpbin("stream/20"), label: "lines")
        case .sse:
            return await streamLines(Endpoints.sse, label: "events") { $0.hasPrefix("data:") }
        case .sharedCompletion:
            return await sharedCompletion()
        case .asyncAwait:
            return await fetch(URLRequest(url: Endpoints.post), session: ephemeralSession())
        case .delegateSession:
            return await viaDelegateSession()
        case .multipart:
            return await multipartUpload()
        case .startCancel:
            return await startAndCancel()
        case .dnsFailure:
            return await fetch(URLRequest(url: Endpoints.invalid, timeoutInterval: 15))
        case .burst:
            return await burst()
        case .breakpointTarget:
            return await fetch(jsonRequest(Endpoints.httpbin("anything"), method: "POST", body: ["message": "edit me in the breakpoint"]))
        }
    }

    private func fetch(_ request: URLRequest, session: URLSession = .shared) async -> String {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return "\(status) · \(DonkFormat.bytes(data.count))"
        } catch {
            return describe(error)
        }
    }

    private func streamLines(_ url: URL, label: String, counting filter: @escaping (String) -> Bool = { _ in true }) async -> String {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            var count = 0
            for try await line in bytes.lines where filter(line) {
                count += 1
                lastResult = "\(url.path): \(count) \(label) so far…"
            }
            return "\((response as? HTTPURLResponse)?.statusCode ?? 0) · \(count) \(label)"
        } catch {
            return describe(error)
        }
    }

    private func sharedCompletion() async -> String {
        await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: Endpoints.user) { data, response, error in
                let summary: String
                if let error {
                    summary = (error as NSError).localizedDescription
                } else {
                    summary = "\((response as? HTTPURLResponse)?.statusCode ?? 0) · \(data?.count ?? 0) B"
                }
                continuation.resume(returning: summary)
            }.resume()
        }
    }

    private func viaDelegateSession() async -> String {
        let session = delegateSession ?? URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        delegateSession = session
        return await withCheckedContinuation { continuation in
            sessionDelegate.load(URLRequest(url: Endpoints.httpbin("redirect-to?url=%2Fget%3Fsource%3Ddelegate-session")), in: session) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func multipartUpload() async -> String {
        let boundary = "donk-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello from donk\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\nContent-Type: text/plain\r\n\r\n")
        append(String(repeating: "donk captures uploads. ", count: 40))
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: Endpoints.httpbin("post"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let progress = UploadProgressDelegate()
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body, delegate: progress)
            return "\((response as? HTTPURLResponse)?.statusCode ?? 0) · sent \(DonkFormat.bytes(progress.bytesSent)) in \(progress.events) progress events, got \(DonkFormat.bytes(data.count))"
        } catch {
            return describe(error)
        }
    }

    private func startAndCancel() async -> String {
        await withCheckedContinuation { continuation in
            let task = URLSession.shared.dataTask(with: Endpoints.httpbin("delay/5")) { _, _, error in
                continuation.resume(returning: error.map { ($0 as NSError).code == NSURLErrorCancelled ? "cancelled" : $0.localizedDescription } ?? "finished")
            }
            task.resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { task.cancel() }
        }
    }

    private func burst() async -> String {
        let session = ephemeralSession()
        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 1...20 {
                group.addTask {
                    let url = URL(string: "https://jsonplaceholder.typicode.com/posts/\(index)")!
                    let response = try? await session.data(from: url).1
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            var result: [Int] = []
            for await status in group { result.append(status) }
            return result
        }
        return "\(statuses.filter { $0 == 200 }.count)/20 OK"
    }

    private func ephemeralSession() -> URLSession {
        if let asyncSession { return asyncSession }
        let session = URLSession(configuration: .ephemeral)
        asyncSession = session
        return session
    }

    private func jsonRequest(_ url: URL, method: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return "cancelled" }
        return "\(nsError.domain) \(nsError.code)"
    }
}

enum Endpoints {
    static let todo = URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
    static let user = URL(string: "https://jsonplaceholder.typicode.com/users/1")!
    static let post = URL(string: "https://jsonplaceholder.typicode.com/posts/1")!
    static let photos = URL(string: "https://jsonplaceholder.typicode.com/photos")!
    static let image = URL(string: "https://picsum.photos/400")!
    static let sse = URL(string: "https://httpbun.com/sse")!
    static let invalid = URL(string: "https://nonexistent.invalid/")!

    static func httpbin(_ path: String) -> URL {
        URL(string: "https://httpbin.org/\(path)")!
    }
}

final class DemoSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var completions: [Int: (String) -> Void] = [:]
    private var redirects: [Int: Int] = [:]

    func load(_ request: URLRequest, in session: URLSession, completion: @escaping (String) -> Void) {
        let task = session.dataTask(with: request)
        lock.lock()
        buffers[task.taskIdentifier] = Data()
        completions[task.taskIdentifier] = completion
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects[task.taskIdentifier, default: 0] += 1
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        let hops = redirects.removeValue(forKey: task.taskIdentifier) ?? 0
        lock.unlock()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        completion?(error.map { ($0 as NSError).localizedDescription } ?? "\(status) · \(data.count) B via delegate after \(hops) redirect(s)")
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Int64 = 0
    private var count = 0

    var bytesSent: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var events: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        sent = totalBytesSent
        count += 1
        lock.unlock()
    }
}
