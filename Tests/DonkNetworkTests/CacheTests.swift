import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class CacheTests: CaptureTestCase {
    private let body = #"{"iban":"KZ000000000000000000","balance":42}"#
    private var server: LocalHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try LocalHTTPServer()
        try await server.start()
        server.route("/cacheable", LocalHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "max-age=600"], body: Data(body.utf8)))
    }

    override func tearDown() async throws {
        server.stop()
        try await super.tearDown()
    }

    private func cacheableURL() -> URL {
        server.url("/cacheable")
    }

    private func makeCache() -> URLCache {
        URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
    }

    private func cachedSession(delegate: URLSessionDelegate?, cache: URLCache, queue: OperationQueue? = nil) -> URLSession {
        makeSession(delegate: delegate, delegateQueue: queue) { configuration in
            configuration.urlCache = cache
            configuration.requestCachePolicy = .useProtocolCachePolicy
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func repeatRequest(_ session: URLSession) async throws -> String {
        let (data, _) = try await session.data(from: cacheableURL())
        return String(decoding: data, as: UTF8.self)
    }

    func testInnerRequestUsesTheSessionsOwnCookieStorage() async throws {
        server.route("/whoami", LocalHTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("ok".utf8)))
        let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "donk.tests.\(UUID().uuidString)")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "sid", .value: "session-a"]))
        cookies.setCookie(cookie)
        let withCookies = makeSession { $0.httpCookieStorage = cookies }
        _ = try await withCookies.data(from: server.url("/whoami"))
        XCTAssertTrue(server.lastRequestHead("/whoami")?.contains("sid=session-a") ?? false)
        let entry = try await requireEntry(path: "/whoami")
        XCTAssertEqual(entry.state, .completed)

        let otherStorage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "donk.tests.\(UUID().uuidString)")
        let withoutCookies = makeSession { $0.httpCookieStorage = otherStorage }
        _ = try await withoutCookies.data(from: server.url("/whoami"))
        XCTAssertFalse(server.lastRequestHead("/whoami")?.contains("sid=") ?? true)
        XCTAssertFalse(SessionInjector.context(of: withCookies) === SessionInjector.context(of: withoutCookies))
    }

    func testNativeBaselineConsultsDelegateAndCaches() async throws {
        DonkNetworkCapture.stop()
        let cache = makeCache()
        let delegate = CachingDelegate(decision: .allow)
        let session = cachedSession(delegate: delegate, cache: cache)
        XCTAssertNil(SessionInjector.context(of: session))
        session.dataTask(with: cacheableURL()).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(delegate.cacheCalls, 1)
        await settle()
        XCTAssertGreaterThan(cache.currentMemoryUsage, 0)
        let repeated = try await repeatRequest(session)
        XCTAssertEqual(repeated, body)
        XCTAssertEqual(server.hitCount("/cacheable"), 1)
    }

    func testDelegateVetoKeepsResponseOutOfURLCache() async throws {
        let cache = makeCache()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let delegate = CachingDelegate(decision: .veto, queue: queue)
        let session = cachedSession(delegate: delegate, cache: cache, queue: queue)
        let task = session.dataTask(with: cacheableURL())
        task.resume()
        await delegate.waitForCompletion()

        XCTAssertNil(delegate.error)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), body)
        XCTAssertEqual(delegate.cacheCalls, 1)
        XCTAssertTrue(delegate.cacheCallsOnDelegateQueue)
        XCTAssertTrue(delegate.cacheTasks.allSatisfy { $0 === task })
        XCTAssertEqual(delegate.proposedBodies.first.map { String(decoding: $0, as: UTF8.self) }, body)
        await settle()
        XCTAssertEqual(cache.currentMemoryUsage, 0)
        let repeated = try await repeatRequest(session)
        XCTAssertEqual(repeated, body)
        XCTAssertEqual(server.hitCount("/cacheable"), 2)
        XCTAssertEqual(cache.currentMemoryUsage, 0)
        let entry = try await requireEntry(path: "/cacheable")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.response?.body?.text, body)
    }

    func testDelegateApprovalStoresResponse() async throws {
        let cache = makeCache()
        let delegate = CachingDelegate(decision: .allow)
        let session = cachedSession(delegate: delegate, cache: cache)
        session.dataTask(with: cacheableURL()).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(delegate.cacheCalls, 1)
        await settle()
        XCTAssertGreaterThan(cache.currentMemoryUsage, 0)
        let repeated = try await repeatRequest(session)
        XCTAssertEqual(repeated, body)
        XCTAssertEqual(server.hitCount("/cacheable"), 1)
    }

    func testDelegateReplacementIsWhatGetsStored() async throws {
        let cache = makeCache()
        let delegate = CachingDelegate(decision: .replace(Data(#"{"redacted":true}"#.utf8)))
        let session = cachedSession(delegate: delegate, cache: cache)
        session.dataTask(with: cacheableURL()).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), body)
        await settle()
        let repeated = try await repeatRequest(session)
        XCTAssertEqual(repeated, #"{"redacted":true}"#)
        XCTAssertEqual(server.hitCount("/cacheable"), 1)
    }

    func testSessionWithoutCacheCallbackCachesByDefault() async throws {
        let cache = makeCache()
        let delegate = RecordingDelegate()
        let session = cachedSession(delegate: delegate, cache: cache)
        session.dataTask(with: cacheableURL()).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        await settle()
        XCTAssertGreaterThan(cache.currentMemoryUsage, 0)
        let repeated = try await repeatRequest(session)
        XCTAssertEqual(repeated, body)
        XCTAssertEqual(server.hitCount("/cacheable"), 1)
    }

    func testTaskDelegateVetoWinsOverSessionDelegate() async throws {
        let cache = makeCache()
        let sessionDelegate = CachingDelegate(decision: .allow)
        let taskDelegate = CachingDelegate(decision: .veto)
        let session = cachedSession(delegate: sessionDelegate, cache: cache)
        let (data, _) = try await session.data(for: URLRequest(url: cacheableURL()), delegate: taskDelegate)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), body)
        XCTAssertEqual(taskDelegate.cacheCalls, 1)
        XCTAssertEqual(sessionDelegate.cacheCalls, 0)
        await settle()
        XCTAssertEqual(cache.currentMemoryUsage, 0)
    }
}

final class CachingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Decision {
        case allow
        case veto
        case replace(Data)
    }

    private let decision: Decision
    private let queue: OperationQueue?
    private let lock = NSLock()
    private var storedBody = Data()
    private var storedError: Error?
    private var storedCacheTasks: [URLSessionDataTask] = []
    private var storedProposedBodies: [Data] = []
    private var onQueue = true
    private var done = false

    init(decision: Decision, queue: OperationQueue? = nil) {
        self.decision = decision
        self.queue = queue
    }

    var body: Data { lock.withValue { storedBody } }
    var error: Error? { lock.withValue { storedError } }
    var cacheCalls: Int { lock.withValue { storedCacheTasks.count } }
    var cacheTasks: [URLSessionDataTask] { lock.withValue { storedCacheTasks } }
    var proposedBodies: [Data] { lock.withValue { storedProposedBodies } }
    var cacheCallsOnDelegateQueue: Bool { lock.withValue { onQueue } }

    func waitForCompletion(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withValue({ done }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withValue { storedBody.append(data) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Void) {
        let expectedQueue = queue
        lock.withValue {
            storedCacheTasks.append(dataTask)
            storedProposedBodies.append(proposedResponse.data)
            if let expectedQueue, OperationQueue.current !== expectedQueue {
                onQueue = false
            }
        }
        switch decision {
        case .allow:
            completionHandler(proposedResponse)
        case .veto:
            completionHandler(nil)
        case let .replace(data):
            completionHandler(CachedURLResponse(response: proposedResponse.response, data: data, userInfo: nil, storagePolicy: .allowedInMemoryOnly))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withValue {
            storedError = error
            done = true
        }
    }
}
