import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class StreamingTests: CaptureTestCase {
    func testChunksReachClientBeforeCompletion() async throws {
        StubServer.shared.route("/chunked", [
            .respond(200, ["Content-Type": "application/json", "X-Content-Type-Options": "nosniff"]),
            .text("first;"),
            .wait(0.3),
            .text("second;"),
            .wait(0.3),
            .text("third;"),
            .finish,
        ])
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/chunked")).resume()
        await delegate.waitForCompletion()

        XCTAssertNil(delegate.error)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), "first;second;third;")
        let chunks = delegate.chunks
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        let firstChunk = try XCTUnwrap(chunks.first)
        let completedAt = try XCTUnwrap(delegate.completedAt)
        XCTAssertEqual(String(decoding: firstChunk.data, as: UTF8.self), "first;")
        XCTAssertGreaterThan(completedAt.timeIntervalSince(firstChunk.date), 0.45)
        let entry = try await requireEntry(path: "/chunked")
        XCTAssertEqual(entry.response?.body?.text, "first;second;third;")
        XCTAssertEqual(entry.state, .completed)
    }

    func testServerSentEventsStreamLiveWithCoalescedUpdates() async throws {
        var steps: [StubStep] = [.respond(200, ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"])]
        for index in 0..<40 {
            steps.append(.text("id: \(index)\ndata: tick \(index)\n\n"))
            steps.append(.wait(0.025))
        }
        steps.append(.finish)
        StubServer.shared.route("/events", steps)
        let counter = EventCounter(store: store)
        let delegate = RecordingDelegate()
        let started = Date()
        makeSession(delegate: delegate).dataTask(with: url("/events")).resume()

        await waitUntil { [self] in self.entry(path: "/events")?.state == .streaming }
        let streaming = try XCTUnwrap(self.entry(path: "/events"))
        XCTAssertEqual(streaming.state, .streaming)
        await delegate.waitForCompletion()
        let duration = Date().timeIntervalSince(started)

        let entry = try await requireEntry(path: "/events")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertTrue(entry.response?.body?.text?.contains("data: tick 39") ?? false)
        XCTAssertEqual(delegate.chunks.first.map { String(decoding: $0.data, as: UTF8.self) }, "id: 0\ndata: tick 0\n\n")

        let observations = counter.observations(for: entry.id)
        let partial = observations.filter { $0.state == .streaming && ($0.response?.body?.originalSize ?? 0) > 0 }
        XCTAssertGreaterThanOrEqual(partial.count, 3)
        let sizes = partial.compactMap { $0.response?.body?.originalSize }
        XCTAssertEqual(sizes, sizes.sorted())
        let updates = counter.updates(for: entry.id)
        let allowed = Int((duration / HTTPExchange.liveUpdateInterval).rounded(.up)) + 6
        XCTAssertLessThanOrEqual(updates, allowed, "updates: \(updates) duration: \(duration)")
    }

    func testResponsePhaseRulesNeverBufferEventStreams() async throws {
        StubServer.shared.route("/live", [
            .respond(200, ["Content-Type": "text/event-stream"]),
            .text("data: 1\n\n"),
            .wait(0.4),
            .text("data: 2\n\n"),
            .finish,
        ])
        addRule("Pause responses", pattern: "/live", action: .breakpoint(request: false, response: true))
        let delegate = RecordingDelegate()
        makeSession(delegate: delegate).dataTask(with: url("/live")).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(delegate.chunks.first.map { String(decoding: $0.data, as: UTF8.self) }, "data: 1\n\n")
        let first = try XCTUnwrap(delegate.chunks.first?.date)
        let completed = try XCTUnwrap(delegate.completedAt)
        XCTAssertGreaterThan(completed.timeIntervalSince(first), 0.3)
        XCTAssertTrue(breakpoints.pending.isEmpty)
        let entry = try await requireEntry(path: "/live")
        XCTAssertEqual(entry.state, .completed)
    }

    func testNonStreamingResponsesStayPendingUntilComplete() async throws {
        StubServer.shared.route("/json-slow", [.respond(200, ["Content-Type": "application/json"]), .text("{\"a\":"), .wait(0.2), .text("1}"), .finish])
        let counter = EventCounter(store: store)
        _ = try await makeSession().data(from: url("/json-slow"))
        let entry = try await requireEntry(path: "/json-slow")
        XCTAssertFalse(counter.observations(for: entry.id).contains { $0.state == .streaming })
        XCTAssertEqual(entry.response?.body?.text, "{\"a\":1}")
    }
}
