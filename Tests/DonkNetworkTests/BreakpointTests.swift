import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class BreakpointTests: CaptureTestCase {
    func testRequestBreakpointResumeWithEdits() async throws {
        addRule("Pause", pattern: "/anything", action: .breakpoint(request: true, response: false))
        var request = URLRequest(url: url("/anything"))
        request.httpMethod = "POST"
        request.httpBody = Data("original".utf8)
        let session = makeSession()
        let prepared = request
        async let result = session.data(for: prepared)

        let paused = try await XCTUnwrapAsync(await pendingExchange())
        XCTAssertEqual(paused.phase, .request)
        XCTAssertEqual(paused.kind, .http)
        XCTAssertEqual(paused.ruleName, "Pause")
        XCTAssertEqual(entry(path: "/anything")?.state, .paused)
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)
        guard case var .request(editable) = paused.payload else { return XCTFail("expected request payload") }
        XCTAssertEqual(editable.body, "original")
        editable.url = "https://api.donk.test/edited"
        editable.body = "edited body"
        editable.headers.append(HTTPHeader(name: "X-Edited", value: "yes"))
        breakpoints.resolve(paused.id, with: .resume(.request(editable)))

        let (data, _) = try await result
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"path\":\"/edited\""))
        let record = try XCTUnwrap(StubServer.shared.records(path: "/edited").first)
        XCTAssertEqual(String(decoding: record.body, as: UTF8.self), "edited body")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Edited"), "yes")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "Content-Length"), "11")
        let entry = try await requireEntry(path: "/edited")
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.request.body?.text, "edited body")
    }

    func testRequestBreakpointUneditedResume() async throws {
        addRule("Pause", pattern: "/plain-resume", action: .breakpoint(request: true, response: false))
        async let result = makeSession().data(from: url("/plain-resume"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        breakpoints.resolve(paused.id, with: .resume(paused.payload))
        _ = try await result
        let finished1 = await finishedEntry(path: "/plain-resume")
        XCTAssertEqual(finished1?.origin, .breakpoint(edited: false))
    }

    func testRequestBreakpointAbort() async throws {
        addRule("Pause", pattern: "/abort", action: .breakpoint(request: true, response: false))
        async let result = makeSession().data(from: url("/abort"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        breakpoints.resolve(paused.id, with: .abort)
        do {
            _ = try await result
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        let entry = try await requireEntry(path: "/abort")
        XCTAssertEqual(entry.state, .cancelled)
        XCTAssertEqual(entry.error?.code, NSURLErrorCancelled)
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)
    }

    func testRequestBreakpointRespondLocally() async throws {
        addRule("Pause", pattern: "/respond", action: .breakpoint(request: true, response: false))
        async let result = makeSession().data(from: url("/respond"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        breakpoints.resolve(paused.id, with: .respond(EditableResponse(statusCode: 418, headers: [], body: "teapot")))
        let (data, response) = try await result
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 418)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "teapot")
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)
        let entry = try await requireEntry(path: "/respond")
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.response?.statusCode, 418)
    }

    func testResponseBreakpointEditsResponse() async throws {
        StubServer.shared.route("/account", [.respond(200, ["Content-Type": "application/json"]), .text(#"{"balance":10}"#), .finish])
        addRule("Pause response", pattern: "/account", action: .breakpoint(request: false, response: true))
        async let result = makeSession().data(from: url("/account"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        XCTAssertEqual(paused.phase, .response)
        XCTAssertEqual(entry(path: "/account")?.state, .paused)
        XCTAssertEqual(entry(path: "/account")?.response?.body?.text, #"{"balance":10}"#)
        guard case var .response(editable) = paused.payload else { return XCTFail("expected response payload") }
        XCTAssertEqual(editable.statusCode, 200)
        XCTAssertEqual(editable.body, #"{"balance":10}"#)
        editable.statusCode = 299
        editable.body = #"{"balance":1000000}"#
        breakpoints.resolve(paused.id, with: .resume(.response(editable)))

        let (data, response) = try await result
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 299)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"balance":1000000}"#)
        let entry = try await requireEntry(path: "/account")
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.response?.statusCode, 299)
        XCTAssertEqual(entry.response?.body?.text, #"{"balance":1000000}"#)
    }

    func testBreakpointOnMockedResponse() async throws {
        addRule("Mock", pattern: "/mocked-pause", action: .mapLocal(MockResponse(body: "mock")))
        addRule("Pause", pattern: "/mocked-pause", action: .breakpoint(request: false, response: true))
        async let result = makeSession().data(from: url("/mocked-pause"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        guard case var .response(editable) = paused.payload else { return XCTFail("expected response payload") }
        XCTAssertEqual(editable.body, "mock")
        editable.body = "mock edited"
        breakpoints.resolve(paused.id, with: .resume(.response(editable)))
        let (data, _) = try await result
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "mock edited")
        let finished2 = await finishedEntry(path: "/mocked-pause")
        XCTAssertEqual(finished2?.origin, .mocked(rule: "Mock"))
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)
    }

    func testOuterCancelWhilePausedAbortsAndCleansUp() async throws {
        addRule("Pause", pattern: "/cancel-paused", action: .breakpoint(request: true, response: false))
        let delegate = RecordingDelegate()
        let task = makeSession(delegate: delegate).dataTask(with: url("/cancel-paused"))
        task.resume()
        _ = try await XCTUnwrapAsync(await pendingExchange())
        task.cancel()
        await delegate.waitForCompletion()
        XCTAssertEqual((delegate.error as? URLError)?.code, .cancelled)
        await waitUntil { [self] in breakpoints.pending.isEmpty }
        XCTAssertTrue(breakpoints.pending.isEmpty)
        let entry = try await requireEntry(path: "/cancel-paused")
        XCTAssertEqual(entry.state, .cancelled)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(StubServer.shared.allRecords.isEmpty)
    }

    func testTimeoutAutoResumesUnedited() async throws {
        breakpoints.timeout = 0.3
        addRule("Pause", pattern: "/timeout", action: .breakpoint(request: true, response: true))
        let started = Date()
        let (data, _) = try await makeSession().data(from: url("/timeout"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.55)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/timeout"))
        let entry = try await requireEntry(path: "/timeout")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.origin, .breakpoint(edited: false))
        XCTAssertTrue(breakpoints.pending.isEmpty)
    }

    func testRewriteAndBreakpointCombine() async throws {
        addRule("Rewrite", pattern: "/combo", action: .rewrite(request: RequestRewrite(headers: HeaderPatch(set: [HTTPHeader(name: "X-Rule", value: "1")])), response: nil))
        addRule("Pause", pattern: "/combo", action: .breakpoint(request: true, response: false))
        async let result = makeSession().data(from: url("/combo"))
        let paused = try await XCTUnwrapAsync(await pendingExchange())
        guard case let .request(editable) = paused.payload else { return XCTFail("expected request payload") }
        XCTAssertEqual(editable.headers.value(for: "X-Rule"), "1")
        breakpoints.resolve(paused.id, with: .resume(paused.payload))
        _ = try await result
        XCTAssertEqual(StubServer.shared.records(path: "/combo").first?.request.value(forHTTPHeaderField: "X-Rule"), "1")
        let finished3 = await finishedEntry(path: "/combo")
        XCTAssertEqual(finished3?.origin, .rewritten(rule: "Rewrite"))
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
