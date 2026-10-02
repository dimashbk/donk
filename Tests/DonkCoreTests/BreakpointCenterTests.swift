import XCTest
@testable import DonkCore

final class BreakpointCenterTests: XCTestCase {
    private func exchange(url: String = "https://e.com/a", phase: BreakpointPhase = .request) -> PausedExchange {
        let payload: BreakpointPayload = phase == .request
            ? .request(EditableRequest(url: url, method: "POST", body: "{}"))
            : .response(EditableResponse(statusCode: 200, body: "ok"))
        return PausedExchange(entryID: UUID(), kind: .http, phase: phase, ruleName: "Rule", payload: payload)
    }

    private func requestURL(_ decision: BreakpointDecision?) -> String? {
        guard case let .resume(.request(request))? = decision else { return nil }
        return request.url
    }

    func testResolveResumesWithDecision() async {
        let center = BreakpointCenter(hasPresenter: true)
        let paused = exchange()
        let task = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        XCTAssertEqual(center.pending.map(\.id), [paused.id])
        var edited = EditableRequest(url: "https://e.com/edited", method: "PUT")
        edited.body = "changed"
        center.resolve(paused.id, with: .resume(.request(edited)))
        let decision = await task.value
        XCTAssertEqual(requestURL(decision), "https://e.com/edited")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAbortAndRespondDecisions() async {
        let center = BreakpointCenter(hasPresenter: true)
        let first = exchange()
        let second = exchange()
        let firstTask = Task { await center.pause(first) }
        let secondTask = Task { await center.pause(second) }
        await waitForPending(center, count: 2)
        center.resolve(first.id, with: .abort)
        center.resolve(second.id, with: .respond(EditableResponse(statusCode: 418, body: "teapot")))
        let firstDecision = await firstTask.value
        let secondDecision = await secondTask.value
        guard case .abort = firstDecision else { return XCTFail("expected abort") }
        guard case let .respond(response) = secondDecision else { return XCTFail("expected respond") }
        XCTAssertEqual(response.statusCode, 418)
    }

    func testTimeoutAutoResumesWithOriginalPayload() async {
        let center = BreakpointCenter(timeout: 0.2, hasPresenter: true)
        XCTAssertEqual(center.timeout, 0.2)
        let paused = exchange(url: "https://e.com/original")
        let started = Date()
        let decision = await center.pause(paused)
        XCTAssertEqual(requestURL(decision), "https://e.com/original")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testResolveBeforeTimeoutWinsAndTimeoutIsHarmless() async throws {
        let center = BreakpointCenter(timeout: 0.3, hasPresenter: true)
        let paused = exchange()
        let task = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        center.resolve(paused.id, with: .abort)
        let decision = await task.value
        guard case .abort = decision else { return XCTFail("expected abort") }
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testResolvingUnknownOrResolvedIDIsNoOp() async {
        let center = BreakpointCenter(hasPresenter: true)
        center.resolve(UUID(), with: .abort)
        let paused = exchange()
        let task = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        center.resolve(UUID(), with: .abort)
        XCTAssertEqual(center.pending.count, 1)
        center.resolve(paused.id, with: .resume(paused.payload))
        center.resolve(paused.id, with: .abort)
        let decision = await task.value
        XCTAssertEqual(requestURL(decision), "https://e.com/a")
    }

    func testConcurrentPausesResolvedFromManyThreads() async {
        let center = BreakpointCenter(hasPresenter: true)
        let exchanges = (0..<40).map { exchange(url: "https://e.com/\($0)") }
        let tasks = exchanges.map { item in Task { await center.pause(item) } }
        await waitForPending(center, count: exchanges.count)
        XCTAssertEqual(Set(center.pending.map(\.id)), Set(exchanges.map(\.id)))
        DispatchQueue.concurrentPerform(iterations: exchanges.count * 2) { index in
            let item = exchanges[index % exchanges.count]
            var request = EditableRequest(url: item.id.uuidString)
            request.method = "PATCH"
            center.resolve(item.id, with: .resume(.request(request)))
        }
        for (item, task) in zip(exchanges, tasks) {
            let decision = await task.value
            XCTAssertEqual(requestURL(decision), item.id.uuidString)
        }
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testChangesPublisherTracksPending() async {
        let center = BreakpointCenter(hasPresenter: true)
        let events = EventRecorder(center.changes)
        let paused = exchange()
        let task = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        center.resolve(paused.id, with: .abort)
        _ = await task.value
        XCTAssertEqual(events.values.map { $0.map(\.id) }, [[], [paused.id], []])
    }

    func testCancellingTheWaitingTaskAborts() async {
        let center = BreakpointCenter(hasPresenter: true)
        let paused = exchange()
        let task = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        task.cancel()
        let decision = await task.value
        guard case .abort = decision else { return XCTFail("expected abort") }
        XCTAssertTrue(center.pending.isEmpty)
        let cancelledBeforeStart = Task { () -> BreakpointDecision in
            withUnsafeCurrentTask { $0?.cancel() }
            return await center.pause(self.exchange())
        }
        guard case .abort = await cancelledBeforeStart.value else { return XCTFail("expected abort") }
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testReusingAnIDResumesThePreviousWaiter() async {
        let center = BreakpointCenter(hasPresenter: true)
        let paused = exchange(url: "https://e.com/first")
        let first = Task { await center.pause(paused) }
        await waitForPending(center, count: 1)
        var replacement = paused
        replacement.payload = .request(EditableRequest(url: "https://e.com/second"))
        let second = Task { await center.pause(replacement) }
        let firstDecision = await first.value
        XCTAssertEqual(requestURL(firstDecision), "https://e.com/first")
        await waitForPending(center, count: 1)
        center.resolve(paused.id, with: .abort)
        guard case .abort = await second.value else { return XCTFail("expected abort") }
    }

    func testWithoutPresenterPauseResumesImmediately() async {
        let center = BreakpointCenter(timeout: 300)
        XCTAssertFalse(center.hasPresenter)
        let events = EventRecorder(center.changes)
        let paused = exchange(url: "https://e.com/unattended")
        let decision = await center.pause(paused)
        XCTAssertEqual(requestURL(decision), "https://e.com/unattended")
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(events.values.map { $0.map(\.id) }, [[]])
    }

    func testDetachingThePresenterResumesPendingExchanges() async {
        let center = BreakpointCenter(timeout: 300, hasPresenter: true)
        let first = exchange(url: "https://e.com/1")
        let second = exchange(url: "https://e.com/2")
        let firstTask = Task { await center.pause(first) }
        let secondTask = Task { await center.pause(second) }
        await waitForPending(center, count: 2)
        center.hasPresenter = false
        let firstDecision = await firstTask.value
        let secondDecision = await secondTask.value
        XCTAssertEqual(requestURL(firstDecision), "https://e.com/1")
        XCTAssertEqual(requestURL(secondDecision), "https://e.com/2")
        XCTAssertTrue(center.pending.isEmpty)
        let late = await center.pause(exchange(url: "https://e.com/late"))
        XCTAssertEqual(requestURL(late), "https://e.com/late")
    }

    func testChangesEndWithTheCurrentPendingListUnderConcurrency() async {
        let center = BreakpointCenter(timeout: 300, hasPresenter: true)
        let events = EventRecorder(center.changes)
        let exchanges = (0..<200).map { _ in exchange() }
        await withTaskGroup(of: Void.self) { group in
            for paused in exchanges {
                group.addTask { _ = await center.pause(paused) }
                group.addTask {
                    while !center.pending.contains(where: { $0.id == paused.id }) {
                        await Task.yield()
                    }
                    center.resolve(paused.id, with: .abort)
                }
            }
        }
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(events.values.last?.isEmpty, true)
        let latest = EventRecorder(center.changes)
        XCTAssertEqual(latest.values.first?.isEmpty, true)
    }

    private func waitForPending(_ center: BreakpointCenter, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while center.pending.count != count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(center.pending.count, count)
    }
}
