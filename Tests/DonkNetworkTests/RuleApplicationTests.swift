import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class RuleApplicationTests: CaptureTestCase {
    func testMapLocalAnswersWithoutHittingServer() async throws {
        let mock = MockResponse(statusCode: 201, headers: [HTTPHeader(name: "X-Mock", value: "yes")], body: #"{"mocked":true}"#, delay: 0.3)
        addRule("Mock todo", pattern: "/todos/1", action: .mapLocal(mock))
        let started = Date()
        let (data, response) = try await makeSession().data(from: url("/todos/1"))
        let elapsed = Date().timeIntervalSince(started)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Mock"), "yes")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), String(data.count))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"mocked":true}"#)
        XCTAssertGreaterThanOrEqual(elapsed, 0.28)
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)

        let entry = try await requireEntry(path: "/todos/1")
        XCTAssertEqual(entry.origin, .mocked(rule: "Mock todo"))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.response?.statusCode, 201)
        XCTAssertEqual(entry.response?.body?.text, #"{"mocked":true}"#)
    }

    func testRulesAreIgnoredWhileEngineIsInactive() async throws {
        addRule("Mock", pattern: "/gated", action: .mapLocal(MockResponse(statusCode: 201, body: "mocked")))
        addRule("Pause", pattern: "/gated", action: .breakpoint(request: true, response: true))
        setEngineActive(false)
        let (data, response) = try await makeSession().data(from: url("/gated"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"path\":\"/gated\""))
        XCTAssertEqual(StubServer.shared.records(path: "/gated").count, 1)
        XCTAssertTrue(breakpoints.pending.isEmpty)
        let entry = try await requireEntry(path: "/gated")
        XCTAssertEqual(entry.origin, .network)
        XCTAssertEqual(entry.state, .completed)

        rules.removeAll()
        addRule("Mock", pattern: "/gated", action: .mapLocal(MockResponse(statusCode: 201, body: "mocked")))
        setEngineActive(true)
        let (mocked, _) = try await makeSession().data(from: url("/gated"))
        XCTAssertEqual(String(decoding: mocked, as: UTF8.self), "mocked")
    }

    func testMapLocalKeepsExplicitContentTypeAndBinaryBodies() async throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]
        addRule("Image", pattern: "/avatar.png", action: .mapLocal(MockResponse(body: "base64:" + Data(png).base64EncodedString())))
        addRule("Text", pattern: "/plain", action: .mapLocal(MockResponse(headers: [HTTPHeader(name: "content-type", value: "text/csv")], body: "a,b")))
        let session = makeSession()
        let (image, imageResponse) = try await session.data(from: url("/avatar.png"))
        XCTAssertEqual(image, Data(png))
        XCTAssertEqual((imageResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let (_, textResponse) = try await session.data(from: url("/plain"))
        XCTAssertEqual((textResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/csv")
    }

    func testMapLocalRespectsMethodMatch() async throws {
        addRule("Only POST", pattern: "/method", method: "POST", action: .mapLocal(MockResponse(body: "mocked")))
        let (data, _) = try await makeSession().data(from: url("/method"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"path\":\"/method\""))
        XCTAssertEqual(StubServer.shared.records(path: "/method").count, 1)
    }

    func testCancelDuringMapLocalDelay() async throws {
        addRule("Slow mock", pattern: "/slow-mock", action: .mapLocal(MockResponse(body: "late", delay: 2)))
        let delegate = RecordingDelegate()
        let task = makeSession(delegate: delegate).dataTask(with: url("/slow-mock"))
        task.resume()
        await waitUntil { [self] in entry(path: "/slow-mock") != nil }
        task.cancel()
        await delegate.waitForCompletion()
        XCTAssertEqual((delegate.error as? URLError)?.code, .cancelled)
        let finished1 = await finishedEntry(path: "/slow-mock")
        XCTAssertEqual(finished1?.state, .cancelled)
    }

    func testRewriteRequestBeforeSending() async throws {
        let rewrite = RequestRewrite(
            url: "https://api.donk.test/rewritten?x=1",
            method: "PUT",
            headers: HeaderPatch(set: [HTTPHeader(name: "X-Rewritten", value: "1")], remove: ["X-Remove"]),
            body: .findReplace([FindReplace(find: "world", replace: "donk")])
        )
        addRule("Rewrite", pattern: "/original", action: .rewrite(request: rewrite, response: nil))
        var request = URLRequest(url: url("/original"))
        request.httpMethod = "POST"
        request.setValue("gone", forHTTPHeaderField: "X-Remove")
        request.httpBody = Data("hello world".utf8)
        _ = try await makeSession().data(for: request)

        let record = try XCTUnwrap(StubServer.shared.records(path: "/rewritten").first)
        XCTAssertEqual(record.request.httpMethod, "PUT")
        XCTAssertEqual(record.request.url?.query, "x=1")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Rewritten"), "1")
        XCTAssertNil(record.request.value(forHTTPHeaderField: "X-Remove"))
        XCTAssertEqual(String(decoding: record.body, as: UTF8.self), "hello donk")
        XCTAssertTrue(StubServer.shared.records(path: "/original").isEmpty)

        let entry = try await requireEntry(path: "/rewritten")
        XCTAssertEqual(entry.origin, .rewritten(rule: "Rewrite"))
        XCTAssertEqual(entry.request.method, "PUT")
        XCTAssertEqual(entry.request.body?.text, "hello donk")
        XCTAssertEqual(entry.request.header("X-Rewritten"), "1")
    }

    func testRewriteResponseBuffersAndPatches() async throws {
        StubServer.shared.route("/profile", [
            .respond(200, ["Content-Type": "application/json", "X-Original": "1"]),
            .text(#"{"plan":"free","#),
            .wait(0.05),
            .text(#""seats":1}"#),
            .finish,
        ])
        let rewrite = ResponseRewrite(
            statusCode: 202,
            headers: HeaderPatch(set: [HTTPHeader(name: "X-Patched", value: "true")], remove: ["X-Original"]),
            body: .findReplace([FindReplace(find: "free", replace: "pro"), FindReplace(find: #""seats":\d+"#, replace: #""seats":50"#, isRegex: true)])
        )
        addRule("Upgrade", pattern: "/profile", action: .rewrite(request: nil, response: rewrite))
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/profile")).resume()
        await delegate.waitForCompletion()

        let http = try XCTUnwrap(delegate.response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 202)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Patched"), "true")
        XCTAssertNil(http.value(forHTTPHeaderField: "X-Original"))
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), #"{"plan":"pro","seats":50}"#)
        XCTAssertEqual(delegate.chunks.count, 1)

        let entry = try await requireEntry(path: "/profile")
        XCTAssertEqual(entry.origin, .rewritten(rule: "Upgrade"))
        XCTAssertEqual(entry.response?.statusCode, 202)
        XCTAssertEqual(entry.response?.body?.text, #"{"plan":"pro","seats":50}"#)
    }

    func testDisabledRulesHaveNoEffect() async throws {
        addRule("Mock", pattern: "/todos/2", action: .mapLocal(MockResponse(body: "mocked")))
        rules.isEnabled = false
        let (data, _) = try await makeSession().data(from: url("/todos/2"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/todos/2"))
        let finished2 = await finishedEntry(path: "/todos/2")
        XCTAssertEqual(finished2?.origin, .network)
    }
}
