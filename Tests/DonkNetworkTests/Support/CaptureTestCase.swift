import Combine
import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

class CaptureTestCase: XCTestCase {
    var store: NetworkStore!
    var rules: RuleStore!
    var breakpoints: BreakpointCenter!
    var settings: NetworkSettingsStore!
    var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donk-network-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = NetworkStore()
        rules = RuleStore(fileName: "rules.json", directory: directory)
        breakpoints = BreakpointCenter(timeout: 300, hasPresenter: true)
        settings = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        StubServer.shared.reset()
        CaptureEngine.shared.environment = CaptureEnvironment(store: store, rules: rules, breakpoints: breakpoints, settings: settings, isActive: { true })
        CaptureEngine.shared.innerProtocolClasses = [StubURLProtocol.self]
        DonkNetworkCapture.start(captureConfiguration())
    }

    override func tearDown() {
        breakpoints.resolveAll { _ in .abort }
        DonkNetworkCapture.stop()
        CaptureEngine.shared.innerProtocolClasses = []
        CaptureEngine.shared.environment = CaptureEnvironment()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func captureConfiguration() -> NetworkCaptureConfiguration {
        NetworkCaptureConfiguration()
    }

    // MARK: - Sessions

    func makeSession(
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil,
        stubFallback: Bool = false,
        configure: (URLSessionConfiguration) -> Void = { _ in }
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        if stubFallback {
            configuration.protocolClasses = [StubURLProtocol.self] + (configuration.protocolClasses ?? [])
        }
        configure(configuration)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    func url(_ path: String, host: String = "api.donk.test") -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    // MARK: - Store helpers

    func entries(path: String) -> [NetworkEntry] {
        store.snapshot().filter { $0.request.path == path }
    }

    func entry(path: String) -> NetworkEntry? {
        entries(path: path).first
    }

    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func finishedEntry(path: String, timeout: TimeInterval = 5) async -> NetworkEntry? {
        await waitUntil(timeout: timeout) { [self] in entry(path: path).map { !$0.state.isInFlight } ?? false }
        return entry(path: path)
    }

    func requireEntry(path: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async throws -> NetworkEntry {
        let entry = await finishedEntry(path: path, timeout: timeout)
        return try XCTUnwrap(entry, "no finished entry for \(path)", file: file, line: line)
    }

    func pendingExchange(timeout: TimeInterval = 5) async -> PausedExchange? {
        await waitUntil(timeout: timeout) { [self] in !breakpoints.pending.isEmpty }
        return breakpoints.pending.first
    }

    func addRule(_ name: String, pattern: String, method: String? = nil, action: RuleAction) {
        rules.add(NetworkRule(name: name, match: RuleMatch(kinds: [.http], method: method, url: URLMatcher(pattern: pattern)), action: action))
    }

    func addTagRule(pattern: String) {
        let rewrite = RequestRewrite(headers: HeaderPatch(set: [HTTPHeader(name: "X-Donk-Rule", value: "1")]))
        addRule("Tag", pattern: pattern, action: .rewrite(request: rewrite, response: nil))
    }

    func setEngineActive(_ isActive: Bool) {
        let flag = ActiveFlag(isActive)
        CaptureEngine.shared.environment = CaptureEnvironment(store: store, rules: rules, breakpoints: breakpoints, settings: settings, isActive: { flag.value })
    }
}

final class ActiveFlag: @unchecked Sendable {
    let value: Bool
    init(_ value: Bool) { self.value = value }
}

// MARK: - Recording delegate

final class RecordingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Chunk {
        let date: Date
        let data: Data
    }

    private let lock = NSLock()
    private var storedChunks: [Chunk] = []
    private var storedResponse: URLResponse?
    private var storedError: Error?
    private var storedCompletedAt: Date?
    private var storedRedirects: [HTTPURLResponse] = []
    private var storedChallenges: [URLAuthenticationChallenge] = []
    private var done = false

    var refusesRedirects = false
    var redirectDecisionDelay: TimeInterval = 0
    var blocksWhileDecidingRedirect = false
    var randomizesRedirectDelay = false
    var challengeDisposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
    var challengeCredential: URLCredential?

    var chunks: [Chunk] { lock.withValue { storedChunks } }
    var response: URLResponse? { lock.withValue { storedResponse } }
    var error: Error? { lock.withValue { storedError } }
    var completedAt: Date? { lock.withValue { storedCompletedAt } }
    var redirects: [HTTPURLResponse] { lock.withValue { storedRedirects } }
    var challenges: [URLAuthenticationChallenge] { lock.withValue { storedChallenges } }
    var body: Data { chunks.reduce(into: Data()) { $0.append($1.data) } }

    func waitForCompletion(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withValue({ done }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withValue { storedResponse = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withValue { storedChunks.append(Chunk(date: Date(), data: data)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.withValue { storedRedirects.append(response) }
        let decision = refusesRedirects ? nil : request
        guard redirectDecisionDelay > 0 else {
            completionHandler(decision)
            return
        }
        let delay = randomizesRedirectDelay ? Double.random(in: 0...redirectDecisionDelay) : redirectDecisionDelay
        if blocksWhileDecidingRedirect {
            Thread.sleep(forTimeInterval: delay)
            completionHandler(decision)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                completionHandler(decision)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.withValue { storedChallenges.append(challenge) }
        completionHandler(challengeDisposition, challengeCredential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withValue {
            storedError = error
            storedCompletedAt = Date()
            done = true
        }
    }
}

extension NSLock {
    func withValue<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: AnyCancellable?
    private var events: [NetworkStoreEvent] = []
    private var observations: [(Date, NetworkEntry)] = []

    init(store: NetworkStore) {
        cancellable = store.events.sink { [weak self, weak store] event in
            guard let self else { return }
            var observed: NetworkEntry?
            if case let .updated(id) = event { observed = store?.entry(id) }
            self.lock.withValue {
                self.events.append(event)
                if let observed { self.observations.append((Date(), observed)) }
            }
        }
    }

    func updates(for id: UUID) -> Int {
        lock.withValue { events.filter { $0 == .updated(id) }.count }
    }

    func observations(for id: UUID) -> [NetworkEntry] {
        lock.withValue { observations.map(\.1).filter { $0.id == id } }
    }
}
