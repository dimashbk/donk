import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class RedirectTests: CaptureTestCase {
    override func setUp() {
        super.setUp()
        StubServer.shared.route("/hop1", [.redirect(302, "/hop2")])
        StubServer.shared.route("/hop2", [.redirect(301, "https://cdn.donk.test/final")])
        StubServer.shared.route("/final", [.respond(200, ["Content-Type": "text/plain"]), .text("arrived"), .finish])
        StubServer.shared.route("/slow-hop", [.redirectWithBody(302, "/slow-final", "<html>moved</html>")])
        StubServer.shared.route("/slow-final", [.respond(200, ["Content-Type": "application/json"]), .text(#"{"ok":true}"#), .finish])
    }

    private func serialQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private func runSlowRedirect(queue: OperationQueue, delay: TimeInterval, blocking: Bool, refuses: Bool) async -> RecordingDelegate {
        let delegate = RecordingDelegate()
        delegate.refusesRedirects = refuses
        delegate.redirectDecisionDelay = delay
        delegate.blocksWhileDecidingRedirect = blocking
        makeSession(delegate: delegate, delegateQueue: queue).dataTask(with: url("/slow-hop")).resume()
        await delegate.waitForCompletion()
        return delegate
    }

    private func assertAcceptedSlowRedirects(queue: OperationQueue, file: StaticString = #filePath, line: UInt = #line) async {
        var runs = 0
        for delay in [0.2, 0.5] {
            for blocking in [false, true] {
                let delegate = await runSlowRedirect(queue: queue, delay: delay, blocking: blocking, refuses: false)
                runs += 1
                let label = "delay \(delay) blocking \(blocking)"
                XCTAssertNil(delegate.error, label, file: file, line: line)
                XCTAssertEqual(delegate.redirects.map(\.statusCode), [302], label, file: file, line: line)
                XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 200, label, file: file, line: line)
                XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), #"{"ok":true}"#, label, file: file, line: line)
            }
        }
        await waitUntil { [self] in entries(path: "/slow-final").filter { $0.state == .completed }.count == runs && entries(path: "/slow-hop").allSatisfy { !$0.state.isInFlight } }
        XCTAssertEqual(entries(path: "/slow-hop").count, runs, file: file, line: line)
        XCTAssertTrue(entries(path: "/slow-hop").allSatisfy { $0.state == .completed && $0.response?.statusCode == 302 }, file: file, line: line)
        XCTAssertTrue(entries(path: "/slow-final").allSatisfy { $0.response?.body?.text == #"{"ok":true}"# }, file: file, line: line)
        XCTAssertEqual(StubServer.shared.records(path: "/slow-final").count, runs, file: file, line: line)
    }

    private func assertRefusedSlowRedirects(queue: OperationQueue, file: StaticString = #filePath, line: UInt = #line) async {
        var runs = 0
        for delay in [0.2, 0.5] {
            for blocking in [false, true] {
                let delegate = await runSlowRedirect(queue: queue, delay: delay, blocking: blocking, refuses: true)
                runs += 1
                let label = "delay \(delay) blocking \(blocking)"
                XCTAssertNil(delegate.error, label, file: file, line: line)
                XCTAssertEqual(delegate.redirects.map(\.statusCode), [302], label, file: file, line: line)
                XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 302, label, file: file, line: line)
                XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), "<html>moved</html>", label, file: file, line: line)
            }
        }
        await waitUntil { [self] in entries(path: "/slow-hop").filter { $0.state == .completed }.count == runs }
        XCTAssertTrue(entries(path: "/slow-hop").allSatisfy { $0.state == .completed && $0.response?.statusCode == 302 }, file: file, line: line)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(entries(path: "/slow-final").isEmpty, file: file, line: line)
        XCTAssertTrue(StubServer.shared.records(path: "/slow-final").isEmpty, file: file, line: line)
    }

    func testRedirectsWithoutDelegateAlwaysReachFinalResponse() async throws {
        let session = makeSession()
        for _ in 0..<40 {
            let (data, response) = try await session.data(from: url("/slow-hop"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
        }
        for _ in 0..<40 {
            let result: (Int, String) = await withCheckedContinuation { continuation in
                session.dataTask(with: url("/slow-hop")) { data, response, _ in
                    continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self)))
                }.resume()
            }
            XCTAssertEqual(result.0, 200)
            XCTAssertEqual(result.1, #"{"ok":true}"#)
        }
        await waitUntil { [self] in entries(path: "/slow-hop").filter { $0.state == .completed }.count == 80 }
        XCTAssertTrue(entries(path: "/slow-hop").allSatisfy { $0.state == .completed && $0.response?.statusCode == 302 })
    }

    func testJitteredDelegateDecisionsNeverCorruptRedirects() async {
        for refuses in [false, true] {
            for _ in 0..<30 {
                let delegate = RecordingDelegate()
                delegate.refusesRedirects = refuses
                delegate.redirectDecisionDelay = 0.06
                delegate.randomizesRedirectDelay = true
                makeSession(delegate: delegate).dataTask(with: url("/slow-hop")).resume()
                await delegate.waitForCompletion()
                XCTAssertNil(delegate.error)
                XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, refuses ? 302 : 200)
                XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), refuses ? "<html>moved</html>" : #"{"ok":true}"#)
            }
        }
    }

    func testRefusedRedirectIsNotDelayed() async {
        let delegate = RecordingDelegate()
        delegate.refusesRedirects = true
        let started = Date()
        makeSession(delegate: delegate).dataTask(with: url("/slow-hop")).resume()
        await delegate.waitForCompletion()
        XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSlowAcceptOnMainQueueNeverLeaksRedirectResponse() async {
        await assertAcceptedSlowRedirects(queue: .main)
    }

    func testSlowAcceptOnSerialQueueNeverLeaksRedirectResponse() async {
        await assertAcceptedSlowRedirects(queue: serialQueue())
    }

    func testSlowRefusalOnMainQueueDeliversRedirectResponse() async {
        await assertRefusedSlowRedirects(queue: .main)
    }

    func testSlowRefusalOnSerialQueueDeliversRedirectResponse() async {
        await assertRefusedSlowRedirects(queue: serialQueue())
    }

    func testRedirectChainIsCapturedOncePerHop() async throws {
        let (data, response) = try await makeSession().data(from: url("/hop1"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "arrived")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.url?.absoluteString, "https://cdn.donk.test/final")

        await waitUntil { [self] in entry(path: "/final")?.state == .completed && entry(path: "/hop1")?.state == .completed && entry(path: "/hop2")?.state == .completed }
        XCTAssertEqual(entries(path: "/hop1").count, 1)
        XCTAssertEqual(entries(path: "/hop2").count, 1)
        XCTAssertEqual(entries(path: "/final").count, 1)
        XCTAssertEqual(entry(path: "/hop1")?.response?.statusCode, 302)
        XCTAssertEqual(entry(path: "/hop1")?.response?.header("Location"), "https://api.donk.test/hop2")
        XCTAssertEqual(entry(path: "/hop1")?.state, .completed)
        XCTAssertEqual(entry(path: "/hop2")?.response?.statusCode, 301)
        XCTAssertEqual(entry(path: "/final")?.response?.statusCode, 200)
        XCTAssertEqual(entry(path: "/final")?.request.host, "cdn.donk.test")
        XCTAssertEqual(entry(path: "/final")?.response?.body?.text, "arrived")
        XCTAssertEqual(StubServer.shared.records(path: "/hop1").count, 1)
        XCTAssertEqual(StubServer.shared.records(path: "/final").count, 1)
    }

    func testRepeatedRedirectsAlwaysReachFinalResponse() async throws {
        let session = makeSession()
        for _ in 0..<25 {
            let (data, response) = try await session.data(from: url("/hop1"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "arrived")
        }
        await waitUntil { [self] in entries(path: "/final").filter { $0.state == .completed }.count == 25 }
        XCTAssertEqual(entries(path: "/hop1").count, 25)
        XCTAssertTrue(entries(path: "/hop1").allSatisfy { $0.state == .completed && $0.response?.statusCode == 302 })
    }

    func testDelegateSeesEachRedirect() async throws {
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/hop1")).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(delegate.redirects.map(\.statusCode), [302, 301])
        XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), "arrived")
    }

    func testRefusedRedirectDeliversRedirectResponse() async throws {
        let delegate = RecordingDelegate()
        delegate.refusesRedirects = true
        makeSession(delegate: delegate).dataTask(with: url("/hop1")).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual((delegate.response as? HTTPURLResponse)?.statusCode, 302)
        let finished1 = await finishedEntry(path: "/hop1")
        XCTAssertEqual(finished1?.response?.statusCode, 302)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(entries(path: "/hop2").isEmpty)
        XCTAssertTrue(StubServer.shared.records(path: "/hop2").isEmpty)
    }
}
