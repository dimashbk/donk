import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class BacklogTests: EchoTestCase {
    private func makeLog(
        store: NetworkStore,
        options: DonkGRPCOptions = DonkGRPCOptions(),
        queue: DispatchQueue
    ) -> GRPCCallLog {
        GRPCCallLog(
            host: "api.example.com",
            path: "/donk.echo.v1.Echo/Expand",
            callType: .serverStreaming,
            metadata: [],
            timeout: nil,
            store: store,
            renderer: GRPCMessageRenderer(options: options),
            maxPendingRenders: options.maxRenderBacklogMessages,
            maxPendingBytes: options.maxRenderBacklogBytes,
            queue: queue
        )
    }

    private func response(_ index: Int, payload: Int) -> Donk_Echo_V1_EchoResponse {
        var response = Donk_Echo_V1_EchoResponse()
        response.text = "message \(index)"
        response.index = Int32(index)
        response.payload = Data(repeating: UInt8(index % 251), count: payload)
        return response
    }

    private func waitForCompletion(_ store: NetworkStore, _ id: UUID) -> NetworkEntry? {
        harness.waitUntil(timeout: 30) { store.entry(id)?.state == .completed }
        return store.entry(id)
    }

    func testTenThousandQueuedMessagesStayWithinMessageBudget() throws {
        let store = NetworkStore()
        let queue = DispatchQueue(label: "donk.tests.backlog")
        queue.suspend()
        let log = makeLog(store: store, queue: queue)
        var sizes: [Int] = []
        for index in 0..<10_000 {
            let message = response(index, payload: 256)
            sizes.append(try message.serializedData().count)
            log.received(message)
        }

        let backlog = log.backlog
        XCTAssertEqual(backlog.pendingRenders, 256)
        XCTAssertEqual(backlog.peakRenders, 256)
        XCTAssertEqual(backlog.pendingBytes, sizes.prefix(256).reduce(0, +))
        XCTAssertLessThanOrEqual(backlog.peakBytes, 4 * 1024 * 1024)
        XCTAssertEqual(backlog.skippedMessages, 10_000 - 256)
        XCTAssertEqual(backlog.queuedEvents, 257)

        log.finished(code: 0, message: nil, trailers: [])
        queue.resume()
        let entry = try XCTUnwrap(waitForCompletion(store, log.entryID))
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(grpc.receivedMessageCount, 10_000)
        XCTAssertEqual(grpc.receivedBytes, sizes.reduce(0, +))
        XCTAssertEqual(grpc.messageCount, GRPCDetails.messageLimit)
        let last = try XCTUnwrap(grpc.messages.last)
        XCTAssertNil(last.json)
        XCTAssertNil(last.raw)
        XCTAssertEqual(last.size, sizes.last)
        XCTAssertTrue(last.textFormat?.hasSuffix("rendering skipped (backlog)") == true)
        let body = try JSONValue.parse(XCTUnwrap(entry.response?.body?.text))
        XCTAssertTrue(body["text"]?.compact().hasPrefix(#""message "#) == true)

        let drained = log.backlog
        XCTAssertEqual(drained.pendingRenders, 0)
        XCTAssertEqual(drained.pendingBytes, 0)
        XCTAssertEqual(drained.queuedEvents, 0)
    }

    func testByteBudgetLimitsRetainedPayloads() throws {
        let store = NetworkStore()
        let queue = DispatchQueue(label: "donk.tests.backlog.bytes")
        queue.suspend()
        let options = DonkGRPCOptions(maxRenderBacklogBytes: 1024 * 1024)
        let log = makeLog(store: store, options: options, queue: queue)
        for index in 0..<200 {
            log.received(response(index, payload: 100 * 1024))
        }
        let backlog = log.backlog
        XCTAssertEqual(backlog.pendingRenders, 10)
        XCTAssertLessThanOrEqual(backlog.peakBytes, 1024 * 1024)
        XCTAssertEqual(backlog.skippedMessages, 190)

        log.finished(code: 0, message: nil, trailers: [])
        queue.resume()
        let entry = try XCTUnwrap(waitForCompletion(store, log.entryID))
        XCTAssertEqual(entry.grpc?.receivedMessageCount, 200)
        let rendered = try XCTUnwrap(entry.grpc?.messages.first)
        XCTAssertNotNil(rendered.json)
        XCTAssertNil(rendered.raw)
    }

    func testOversizedMessagesAreNotRetainedWhileQueued() throws {
        let renderer = GRPCMessageRenderer(options: DonkGRPCOptions(maxRenderedMessageSize: 1024, maxRawMessageSize: 512))
        let large = renderer.capture(response(1, payload: 4096))
        XCTAssertEqual(large.cost, 0)
        XCTAssertGreaterThan(large.size, 4096)
        let rendered = large.render()
        XCTAssertNil(rendered.json)
        XCTAssertNil(rendered.raw)
        XCTAssertTrue(rendered.textFormat?.contains("rendering skipped (limit") == true)

        let medium = renderer.capture(response(2, payload: 700))
        XCTAssertEqual(medium.cost, medium.size)
        XCTAssertNil(medium.render().raw)
        XCTAssertNotNil(medium.render().json)

        let small = renderer.capture(response(3, payload: 16))
        XCTAssertEqual(small.cost, small.size)
        XCTAssertEqual(small.render().raw?.count, small.size)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(small.render().json))["text"], .string("message 3"))
    }

    func testTenThousandStreamedMessagesKeepAccurateCounts() throws {
        let options = harness.options { $0.maxRenderBacklogMessages = 32 }
        let (client, interceptors) = harness.recordingClient(options: options)
        let received = Collector<Int32>()
        let call = client.expand(.make("flood") { $0.repeatCount = 10_000 }) { received.append($0.index) }
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(received.values.count, 10_000)
        XCTAssertEqual(received.values.last, 9_999)

        let entry = try XCTUnwrap(harness.waitForFinishedEntry(timeout: 60))
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(grpc.sentMessageCount, 1)
        XCTAssertEqual(grpc.receivedMessageCount, 10_000)
        XCTAssertEqual(grpc.messageCount, GRPCDetails.messageLimit)
        XCTAssertEqual(grpc.statusCode, 0)

        let backlog = try XCTUnwrap(interceptors.last?.renderBacklog)
        XCTAssertLessThanOrEqual(backlog.peakRenders, 32)
        XCTAssertEqual(backlog.pendingRenders, 0)
        XCTAssertEqual(backlog.pendingBytes, 0)
        let rendered = grpc.messages.filter { $0.json != nil }.count
        let skipped = grpc.messages.filter { $0.textFormat?.hasSuffix("(backlog)") == true }.count
        XCTAssertEqual(rendered + skipped, grpc.messageCount)
    }
}
