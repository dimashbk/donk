import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class CaptureTests: CaptureTestCase {
    func testCapturesGETWithHeadersStatusAndBody() async throws {
        StubServer.shared.route("/users/1", [
            .respond(200, ["Content-Type": "application/json", "X-Server": "stub"]),
            .text(#"{"id":1,"name":"Ada"}"#),
            .finish,
        ])
        var request = URLRequest(url: url("/users/1?expand=true"))
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await makeSession().data(for: request)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":1,"name":"Ada"}"#)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let entry = try await requireEntry(path: "/users/1")
        XCTAssertEqual(entry.kind, .http)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.origin, .network)
        XCTAssertEqual(entry.request.method, "GET")
        XCTAssertEqual(entry.request.url, "https://api.donk.test/users/1?expand=true")
        XCTAssertEqual(entry.request.header("authorization"), "Bearer token")
        XCTAssertEqual(entry.response?.statusCode, 200)
        XCTAssertEqual(entry.response?.header("X-Server"), "stub")
        XCTAssertEqual(entry.response?.body?.text, #"{"id":1,"name":"Ada"}"#)
        XCTAssertEqual(entry.response?.body?.contentType, "application/json")
        XCTAssertNil(entry.error)
        XCTAssertNotNil(entry.timing.endedAt)
        XCTAssertNotNil(entry.timing.responseStartedAt)
        XCTAssertEqual(StubServer.shared.records(path: "/users/1").count, 1)
        XCTAssertTrue(StubServer.shared.records(path: "/users/1")[0].isHandled)
    }

    func testCapturesPOSTWithHTTPBody() async throws {
        var request = URLRequest(url: url("/posts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"title":"hello"}"#.utf8)
        let (_, response) = try await makeSession().data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let entry = try await requireEntry(path: "/posts")
        XCTAssertEqual(entry.request.method, "POST")
        XCTAssertEqual(entry.request.body?.text, #"{"title":"hello"}"#)
        XCTAssertEqual(entry.request.body?.contentType, "application/json")
        XCTAssertEqual(entry.request.body?.originalSize, 17)
        let record = try XCTUnwrap(StubServer.shared.records(path: "/posts").first)
        XCTAssertEqual(String(decoding: record.body, as: UTF8.self), #"{"title":"hello"}"#)
        XCTAssertEqual(record.request.httpMethod, "POST")
    }

    func testBodyStreamRequestPassesThroughWithoutRule() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        var request = URLRequest(url: url("/stream-upload"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBodyStream = InputStream(data: payload)
        XCTAssertFalse(DonkURLProtocol.canInit(with: request))
        _ = try await makeSession(stubFallback: true).data(for: request)

        let record = try XCTUnwrap(StubServer.shared.records(path: "/stream-upload").first)
        XCTAssertEqual(record.body, payload)
        XCTAssertFalse(record.isHandled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(entry(path: "/stream-upload"))
    }

    func testBodyStreamRequestIsCapturedWhenRuleTargetsIt() async throws {
        addTagRule(pattern: "/stream-upload")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        var request = URLRequest(url: url("/stream-upload"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBodyStream = InputStream(data: payload)
        _ = try await makeSession().data(for: request)

        let entry = try await requireEntry(path: "/stream-upload")
        XCTAssertEqual(entry.request.body?.originalSize, payload.count)
        XCTAssertEqual(entry.request.body?.data, payload)
        let record = try XCTUnwrap(StubServer.shared.records(path: "/stream-upload").first)
        XCTAssertEqual(record.body, payload)
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Donk-Rule"), "1")
    }

    func testUploadTasksPassThroughWithoutRule() async throws {
        var request = URLRequest(url: url("/upload"))
        request.httpMethod = "PUT"
        let session = makeSession(stubFallback: true)
        let uploadTask: URLSessionTask = session.uploadTask(with: request, from: Data("probe".utf8))
        XCTAssertTrue(uploadTask is URLSessionUploadTask)
        XCTAssertFalse(DonkURLProtocol.canInit(with: uploadTask))
        _ = try await session.upload(for: request, from: Data("from-data".utf8))
        let file = directory.appendingPathComponent("upload.txt")
        try Data("from-file".utf8).write(to: file)
        _ = try await session.upload(for: request, fromFile: file)

        let records = StubServer.shared.records(path: "/upload")
        XCTAssertEqual(Set(records.map { String(decoding: $0.body, as: UTF8.self) }), ["from-data", "from-file"])
        XCTAssertTrue(records.allSatisfy { !$0.isHandled })
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(entries(path: "/upload").isEmpty)
    }

    func testUploadTasksAreCapturedWhenRuleTargetsThem() async throws {
        addTagRule(pattern: "/upload")
        var request = URLRequest(url: url("/upload"))
        request.httpMethod = "PUT"
        let session = makeSession()
        _ = try await session.upload(for: request, from: Data("from-data".utf8))
        let file = directory.appendingPathComponent("upload.txt")
        try Data("from-file".utf8).write(to: file)
        _ = try await session.upload(for: request, fromFile: file)

        await waitUntil { [self] in entries(path: "/upload").filter { $0.state == .completed }.count == 2 }
        let bodies = Set(entries(path: "/upload").compactMap { $0.request.body?.text })
        XCTAssertEqual(bodies, ["from-data", "from-file"])
        XCTAssertEqual(Set(StubServer.shared.records(path: "/upload").map { String(decoding: $0.body, as: UTF8.self) }), ["from-data", "from-file"])
        XCTAssertTrue(entries(path: "/upload").allSatisfy { $0.request.method == "PUT" && $0.origin == .rewritten(rule: "Tag") })
    }

    func testUploadsPassThroughWhenEngineInactiveEvenWithRule() async throws {
        addTagRule(pattern: "/upload")
        setEngineActive(false)
        var request = URLRequest(url: url("/upload"))
        request.httpMethod = "PUT"
        _ = try await makeSession(stubFallback: true).upload(for: request, from: Data("inactive".utf8))
        let record = try XCTUnwrap(StubServer.shared.records(path: "/upload").first)
        XCTAssertFalse(record.isHandled)
        XCTAssertNil(record.request.value(forHTTPHeaderField: "X-Donk-Rule"))
        XCTAssertTrue(entries(path: "/upload").isEmpty)
    }

    func testStreamedUploadTaskBodyComesFromDelegate() async throws {
        addTagRule(pattern: "/streamed")
        let delegate = StreamingBodyDelegate(payload: Data("streamed-from-delegate".utf8))
        var request = URLRequest(url: url("/streamed"))
        request.httpMethod = "POST"
        makeSession(delegate: delegate).uploadTask(withStreamedRequest: request).resume()
        await delegate.waitForCompletion()

        XCTAssertNil(delegate.error)
        XCTAssertEqual(String(decoding: StubServer.shared.records(path: "/streamed").first?.body ?? Data(), as: UTF8.self), "streamed-from-delegate")
        let entry = try await requireEntry(path: "/streamed")
        XCTAssertEqual(entry.request.body?.text, "streamed-from-delegate")
    }

    func testDownloadTaskIsCaptured() async throws {
        StubServer.shared.route("/file.bin", [.respond(200, ["Content-Type": "application/octet-stream"]), .data(Data(repeating: 7, count: 4096)), .finish])
        let (location, response) = try await makeSession().download(for: URLRequest(url: url("/file.bin")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: location), Data(repeating: 7, count: 4096))
        let entry = try await requireEntry(path: "/file.bin")
        XCTAssertEqual(entry.response?.body?.originalSize, 4096)
        XCTAssertEqual(entry.state, .completed)
    }

    func testDecodedBodyLongerThanContentLengthIsDeliveredIntact() async throws {
        let decoded = String(repeating: "decoded-", count: 64)
        StubServer.shared.route("/compressed", [
            .respond(200, ["Content-Type": "application/json", "Content-Encoding": "gzip", "Content-Length": "40"]),
            .text(decoded),
            .finish,
        ])
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/compressed")).resume()
        await delegate.waitForCompletion()
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), decoded)
        let entry = try await requireEntry(path: "/compressed")
        XCTAssertEqual(entry.response?.body?.text, decoded)
        XCTAssertEqual(entry.response?.header("Content-Encoding"), "gzip")
    }

    func testHTTPErrorStatusIsCaptured() async throws {
        StubServer.shared.route("/missing", [.respond(404, ["Content-Type": "text/plain"]), .text("not found"), .finish])
        let (data, response) = try await makeSession().data(from: url("/missing"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "not found")
        let entry = try await requireEntry(path: "/missing")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.statusCategory, .clientError)
        XCTAssertEqual(entry.response?.body?.text, "not found")
    }

    func testTransportErrorIsMapped() async throws {
        StubServer.shared.route("/offline", [.fail(.notConnectedToInternet)])
        do {
            _ = try await makeSession().data(from: url("/offline"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let entry = try await requireEntry(path: "/offline")
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error?.domain, NSURLErrorDomain)
        XCTAssertEqual(entry.error?.code, NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(entry.statusLabel, "ERR")
    }

    func testCancellationMarksEntryCancelled() async throws {
        StubServer.shared.route("/slow", [.respond(200, ["Content-Type": "application/json", "X-Content-Type-Options": "nosniff"]), .wait(5), .text("late"), .finish])
        let delegate = RecordingDelegate()
        let task = makeSession(delegate: delegate).dataTask(with: url("/slow"))
        task.resume()
        await waitUntil { !StubServer.shared.records(path: "/slow").isEmpty }
        await waitUntil { [self] in self.entry(path: "/slow")?.response != nil }
        task.cancel()
        await delegate.waitForCompletion()

        XCTAssertEqual((delegate.error as? URLError)?.code, .cancelled)
        let entry = try await requireEntry(path: "/slow")
        XCTAssertEqual(entry.state, .cancelled)
        XCTAssertEqual(entry.error?.code, NSURLErrorCancelled)
        await waitUntil { StubServer.shared.stoppedPaths.contains("/slow") }
        XCTAssertTrue(StubServer.shared.stoppedPaths.contains("/slow"))
    }

    func testRequestTimeoutIsRecordedAsFailure() async throws {
        StubServer.shared.route("/hang", [.respond(200, ["Content-Type": "application/json", "X-Content-Type-Options": "nosniff"]), .wait(10), .finish])
        do {
            _ = try await makeSession().data(for: URLRequest(url: url("/hang"), timeoutInterval: 0.4))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let entry = try await requireEntry(path: "/hang")
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error?.code, NSURLErrorTimedOut)
        XCTAssertEqual(entry.response?.statusCode, 200)
    }

    func testResourceTimeoutOnSessionIsRecordedAsFailure() async throws {
        StubServer.shared.route("/never", [.wait(10), .finish])
        let session = makeSession { $0.timeoutIntervalForResource = 0.4 }
        do {
            _ = try await session.data(from: url("/never"))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let entry = try await requireEntry(path: "/never")
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error?.code, NSURLErrorTimedOut)
    }

    func testSharedSessionCompletionHandlerIsCaptured() async throws {
        let done = expectation(description: "completion")
        var status = 0
        URLSession.shared.dataTask(with: url("/shared")) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            done.fulfill()
        }.resume()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(status, 200)
        let entry = try await requireEntry(path: "/shared")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.response?.header("X-Stub"), "1")
    }

    func testSharedSessionAsyncIsCaptured() async throws {
        let (_, response) = try await URLSession.shared.data(from: url("/shared-async"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let finished1 = await finishedEntry(path: "/shared-async")
        XCTAssertEqual(finished1?.state, .completed)
    }

    func testAsyncAwaitBytesAPI() async throws {
        StubServer.shared.route("/lines", [
            .respond(200, ["Content-Type": "text/plain"]),
            .text("one\n"),
            .wait(0.05),
            .text("two\n"),
            .wait(0.05),
            .text("three\n"),
            .finish,
        ])
        let (bytes, _) = try await makeSession().bytes(for: URLRequest(url: url("/lines")))
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["one", "two", "three"])
        let finished2 = await finishedEntry(path: "/lines")
        XCTAssertEqual(finished2?.response?.body?.text, "one\ntwo\nthree\n")
    }

    func testDelegateSessionReceivesAllCallbacks() async throws {
        StubServer.shared.route("/delegate", [.respond(201, ["Content-Type": "text/plain"]), .text("a"), .text("b"), .finish])
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/delegate")).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), "ab")
        let finished3 = await finishedEntry(path: "/delegate")
        XCTAssertEqual(finished3?.response?.statusCode, 201)
    }

    func testNilDelegateSessionCompletionHandler() async throws {
        let session = makeSession()
        let done = expectation(description: "completion")
        var body = ""
        session.dataTask(with: url("/nil-delegate")) { data, _, _ in
            body = String(decoding: data ?? Data(), as: UTF8.self)
            done.fulfill()
        }.resume()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(body.contains("/nil-delegate"))
        let finished4 = await finishedEntry(path: "/nil-delegate")
        XCTAssertEqual(finished4?.state, .completed)
    }

    func testBodyIsTruncatedToStoreLimitButClientGetsEverything() async throws {
        store.maxBodySize = 10
        let payload = String(repeating: "x", count: 100)
        StubServer.shared.route("/big", [.respond(200, ["Content-Type": "text/plain"]), .text(payload), .finish])
        var request = URLRequest(url: url("/big"))
        request.httpMethod = "POST"
        request.httpBody = Data(String(repeating: "y", count: 50).utf8)
        let (data, _) = try await makeSession().data(for: request)
        XCTAssertEqual(data.count, 100)
        let entry = try await requireEntry(path: "/big")
        XCTAssertEqual(entry.response?.body?.data.count, 10)
        XCTAssertEqual(entry.response?.body?.originalSize, 100)
        XCTAssertEqual(entry.response?.body?.isTruncated, true)
        XCTAssertEqual(entry.request.body?.data.count, 10)
        XCTAssertEqual(entry.request.body?.originalSize, 50)
        XCTAssertEqual(StubServer.shared.records(path: "/big").first?.body.count, 50)
    }

    func testBurstOfParallelRequests() async throws {
        let session = makeSession()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let (_, response) = try await session.data(from: self.url("/burst/\(index)"))
                    return (response as? HTTPURLResponse)?.statusCode ?? 0
                }
            }
            for try await status in group {
                XCTAssertEqual(status, 200)
            }
        }
        await waitUntil { [self] in store.snapshot().filter { $0.request.path.hasPrefix("/burst/") && $0.state == .completed }.count == 20 }
        let paths = Set(store.snapshot().map(\.request.path).filter { $0.hasPrefix("/burst/") })
        XCTAssertEqual(paths.count, 20)
    }

    func testRequestPropertiesArePreserved() async throws {
        var request = URLRequest(url: url("/fidelity"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 33)
        request.networkServiceType = .responsiveData
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = false
        request.allowsExpensiveNetworkAccess = false
        request.allowsConstrainedNetworkAccess = false
        _ = try await makeSession().data(for: request)

        let record = try XCTUnwrap(StubServer.shared.records(path: "/fidelity").first)
        XCTAssertEqual(record.request.timeoutInterval, 33)
        XCTAssertEqual(record.request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(record.request.networkServiceType, .responsiveData)
        XCTAssertFalse(record.request.httpShouldHandleCookies)
        XCTAssertFalse(record.request.allowsCellularAccess)
        XCTAssertFalse(record.request.allowsExpensiveNetworkAccess)
        XCTAssertFalse(record.request.allowsConstrainedNetworkAccess)
    }

    func testSessionHeadersCookiesAndProtocolsAreMirrored() async throws {
        let cookies = HTTPCookieStorage()
        let session = makeSession(stubFallback: true) { configuration in
            configuration.httpAdditionalHeaders = ["X-Session": "mirror", "User-Agent": "DonkTests/1"]
            configuration.httpCookieStorage = cookies
            configuration.timeoutIntervalForRequest = 17
        }
        _ = try await session.data(from: url("/mirror"))

        let record = try XCTUnwrap(StubServer.shared.records(path: "/mirror").first)
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Session"), "mirror")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "User-Agent"), "DonkTests/1")
        let entry = try await requireEntry(path: "/mirror")
        XCTAssertEqual(entry.request.header("X-Session"), "mirror")

        let context = try XCTUnwrap(SessionInjector.context(of: session))
        let inner = context.innerConfiguration
        XCTAssertTrue(inner.httpCookieStorage === session.configuration.httpCookieStorage)
        XCTAssertEqual(inner.timeoutIntervalForRequest, 17)
        XCTAssertFalse(inner.protocolClasses?.contains { SessionInjector.isDonkClass($0) } ?? true)
        XCTAssertTrue(inner.protocolClasses?.contains { $0 == StubURLProtocol.self } ?? false)
    }

    func testMetricsAreRecorded() async throws {
        _ = try await makeSession().data(from: url("/metrics"))
        await waitUntil { [self] in self.entry(path: "/metrics")?.timing.transactions.isEmpty == false }
        let entry = try XCTUnwrap(self.entry(path: "/metrics"))
        XCTAssertFalse(entry.timing.transactions.isEmpty)
        XCTAssertNotNil(entry.timing.transactions.last?.fetchStart)
    }
}


final class StreamingBodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let payload: Data
    private let lock = NSLock()
    private var done = false
    private var storedError: Error?

    init(payload: Data) {
        self.payload = payload
    }

    var error: Error? { lock.withValue { storedError } }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(InputStream(data: payload))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withValue {
            storedError = error
            done = true
        }
    }

    func waitForCompletion(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withValue({ done }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
