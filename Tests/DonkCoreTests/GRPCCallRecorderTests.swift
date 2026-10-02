import XCTest
@testable import DonkCore

final class GRPCCallRecorderTests: XCTestCase {
    private let metadata = [HTTPHeader(name: "authorization", value: "Bearer t"), HTTPHeader(name: "x-id", value: "1")]

    private func makeRecorder(
        _ store: NetworkStore,
        host: String? = "api.example.com",
        path: String = "/bank.v1.AccountService/GetAccount",
        callType: GRPCCallType = .unary,
        timeout: TimeInterval? = 5
    ) -> GRPCCallRecorder {
        GRPCCallRecorder(host: host, path: path, callType: callType, requestMetadata: metadata, timeout: timeout, store: store)
    }

    func testUnaryLifecycle() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store)
        var entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.kind, .grpc)
        XCTAssertEqual(entry.state, .pending)
        XCTAssertEqual(entry.request.url, "grpc://api.example.com/bank.v1.AccountService/GetAccount")
        XCTAssertEqual(entry.request.method, "POST")
        XCTAssertEqual(entry.request.headers, metadata)
        XCTAssertEqual(entry.grpc?.service, "bank.v1.AccountService")
        XCTAssertEqual(entry.grpc?.method, "GetAccount")
        XCTAssertEqual(entry.grpc?.callType, .unary)
        XCTAssertEqual(entry.grpc?.timeout, 5)
        XCTAssertEqual(entry.grpc?.requestMetadata, metadata)
        XCTAssertEqual(entry.statusCategory, .pending)
        XCTAssertTrue(recorder.isRecording)

        recorder.didSend(typeName: "bank.v1.GetAccountRequest", size: 12, json: #"{"id":"A1"}"#)
        entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .pending)
        XCTAssertEqual(entry.request.body?.text, #"{"id":"A1"}"#)
        XCTAssertEqual(entry.request.body?.contentType, "application/json")

        let headers = [HTTPHeader(name: "content-type", value: "application/grpc")]
        recorder.didReceiveHeaders(headers)
        entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.response?.statusCode, 200)
        XCTAssertEqual(entry.response?.headers, headers)
        XCTAssertEqual(entry.grpc?.responseHeaders, headers)
        XCTAssertNotNil(entry.timing.responseStartedAt)

        recorder.didReceive(typeName: "bank.v1.Account", size: 30, json: #"{"balance":10}"#)
        recorder.didFinish(statusCode: 0, message: "", trailers: [HTTPHeader(name: "grpc-status", value: "0")])
        entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.grpc?.statusCode, 0)
        XCTAssertNil(entry.grpc?.statusMessage)
        XCTAssertEqual(entry.grpc?.trailers, [HTTPHeader(name: "grpc-status", value: "0")])
        XCTAssertEqual(entry.response?.body?.text, #"{"balance":10}"#)
        XCTAssertEqual(entry.grpc?.messages.map(\.direction), [.sent, .received])
        XCTAssertEqual(entry.grpc?.messages.map(\.typeName), ["bank.v1.GetAccountRequest", "bank.v1.Account"])
        XCTAssertNotNil(entry.timing.endedAt)
        XCTAssertEqual(entry.statusLabel, "OK")
        XCTAssertEqual(entry.statusCategory, .success)
        XCTAssertEqual(entry.requestSize, 12)
        XCTAssertEqual(entry.responseSize, 30)
        XCTAssertFalse(recorder.isRecording)
    }

    func testServerStreamCapsMessagesAndKeepsCounts() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .serverStreaming)
        recorder.didSend(typeName: "Req", size: 5, json: #"{"from":0}"#)
        XCTAssertEqual(store.entry(recorder.entryID)?.state, .streaming)
        recorder.didReceiveHeaders([])
        for index in 0..<1_500 {
            recorder.didReceive(typeName: "Tick", size: 10, json: #"{"n":\#(index)}"#)
        }
        var entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .streaming)
        XCTAssertEqual(entry.statusCategory, .pending)
        XCTAssertEqual(entry.grpc?.messages.count, GRPCDetails.messageLimit)
        XCTAssertEqual(entry.grpc?.receivedMessageCount, 1_500)
        XCTAssertEqual(entry.grpc?.sentMessageCount, 1)
        XCTAssertEqual(entry.grpc?.droppedMessageCount, 501)
        XCTAssertEqual(entry.grpc?.messages.last?.json, #"{"n":1499}"#)
        XCTAssertEqual(entry.grpc?.messages.first?.json, #"{"n":500}"#)
        XCTAssertNotNil(entry.response?.body)
        XCTAssertEqual(entry.request.body?.text, #"{"from":0}"#)
        XCTAssertEqual(entry.responseSize, 15_000)

        recorder.didFinish(statusCode: 14, message: "server closed", trailers: [])
        entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.response?.body?.text, #"{"n":1499}"#)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.grpc?.statusCode, 14)
        XCTAssertEqual(entry.grpc?.statusMessage, "server closed")
        XCTAssertEqual(entry.statusCategory, .serverError)
        XCTAssertNil(entry.error)
    }

    func testResponseBodyIsThrottledAndFlushedLater() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .serverStreaming)
        recorder.didReceive(typeName: "Tick", size: 1, json: #"{"n":0}"#)
        XCTAssertEqual(store.entry(recorder.entryID)?.response?.body?.text, #"{"n":0}"#)
        for index in 1...50 {
            recorder.didReceive(typeName: "Tick", size: 1, json: #"{"n":\#(index)}"#)
        }
        XCTAssertEqual(store.entry(recorder.entryID)?.response?.body?.text, #"{"n":0}"#)
        XCTAssertEqual(store.entry(recorder.entryID)?.grpc?.messageCount, 51)
        let deadline = Date().addingTimeInterval(3)
        while store.entry(recorder.entryID)?.response?.body?.text != #"{"n":50}"#, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(store.entry(recorder.entryID)?.response?.body?.text, #"{"n":50}"#)
        recorder.didReceive(typeName: "Tick", size: 1, json: #"{"n":51}"#)
        recorder.didCancel()
        XCTAssertEqual(store.entry(recorder.entryID)?.response?.body?.text, #"{"n":51}"#)
        XCTAssertEqual(store.entry(recorder.entryID)?.state, .cancelled)
    }

    func testMessageTextIsCappedAt64KB() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .serverStreaming)
        let large = "{\"data\":\"" + String(repeating: "я", count: 40_000) + "\"}"
        let largeSize = large.utf8.count
        recorder.didReceive(typeName: "Big", size: largeSize, json: large, textFormat: String(repeating: "t", count: 70_000))
        let message = try XCTUnwrap(store.entry(recorder.entryID)?.grpc?.messages.first)
        let json = try XCTUnwrap(message.json)
        XCTAssertTrue(json.hasSuffix("… (truncated, \(largeSize) bytes)"))
        XCTAssertLessThanOrEqual(json.utf8.count, GRPCCallRecorder.maxMessageTextSize + 40)
        XCTAssertTrue(json.hasPrefix("{\"data\":\"яя"))
        XCTAssertTrue(message.textFormat?.hasSuffix("… (truncated, 70000 bytes)") ?? false)
        XCTAssertEqual(message.size, largeSize)
        XCTAssertEqual(store.entry(recorder.entryID)?.response?.body?.text, large)
        XCTAssertEqual(GRPCCallRecorder.capped("short"), "short")
        XCTAssertEqual(GRPCCallRecorder.capped("ab€", limit: 3), "ab… (truncated, 5 bytes)")
    }

    func testClientStreamBecomesStreamingAndKeepsFirstBody() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .clientStreaming)
        recorder.didSend(typeName: "Chunk", size: 1, json: #"{"i":1}"#)
        recorder.didSend(typeName: "Chunk", size: 1, json: #"{"i":2}"#)
        let entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .streaming)
        XCTAssertEqual(entry.request.body?.text, #"{"i":1}"#)
        XCTAssertEqual(entry.grpc?.messages.count, 2)
    }

    func testFinishIsIdempotentAndLateEventsAreIgnored() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store)
        recorder.didFinish(statusCode: 5, message: "missing", trailers: [])
        recorder.didFail(NSError(domain: "x", code: 1))
        recorder.didCancel()
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        recorder.didReceive(typeName: "Late", size: 1, json: "{}")
        recorder.didSend(typeName: "Late", size: 1, json: "{}")
        recorder.didReceiveHeaders([HTTPHeader(name: "late", value: "1")])
        let entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.grpc?.statusCode, 5)
        XCTAssertEqual(entry.statusCategory, .clientError)
        XCTAssertEqual(entry.statusLabel, "NOT_FOUND")
        XCTAssertNil(entry.error)
        XCTAssertTrue(entry.grpc?.messages.isEmpty ?? false)
        XCTAssertNil(entry.response)
    }

    func testCancel() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .bidirectionalStreaming)
        recorder.didSend(typeName: "Msg", size: 1, json: "{}")
        recorder.didCancel()
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        let entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .cancelled)
        XCTAssertNil(entry.grpc?.statusCode)
        XCTAssertEqual(entry.statusCategory, .failure)
        XCTAssertEqual(entry.statusLabel, "CANCELLED")
        XCTAssertNotNil(entry.timing.endedAt)
    }

    func testFail() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store)
        let error = NSError(domain: "NIOCore.ChannelError", code: 3, userInfo: [NSLocalizedDescriptionKey: "connection reset"])
        recorder.didFail(error)
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        let entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error, NetworkErrorInfo(domain: "NIOCore.ChannelError", code: 3, message: "connection reset"))
        XCTAssertEqual(entry.statusCategory, .failure)
        XCTAssertEqual(entry.statusLabel, "ERR")
    }

    func testCaptureDisabledMakesRecorderInert() {
        let store = NetworkStore()
        store.isCaptureEnabled = false
        let events = EventRecorder(store.events)
        let recorder = makeRecorder(store)
        store.isCaptureEnabled = true
        recorder.didSend(typeName: "Req", size: 1, json: "{}")
        recorder.didReceiveHeaders([])
        recorder.didReceive(typeName: "Res", size: 1, json: "{}")
        recorder.setOrigin(.mocked(rule: "x"))
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.entry(recorder.entryID))
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertFalse(recorder.isRecording)
    }

    func testHostAndPathNormalization() {
        let store = NetworkStore()
        let noHost = makeRecorder(store, host: nil, path: "pkg.Svc/Method")
        XCTAssertEqual(store.entry(noHost.entryID)?.request.url, "grpc://grpc/pkg.Svc/Method")
        XCTAssertEqual(store.entry(noHost.entryID)?.grpc?.path, "/pkg.Svc/Method")
        let prefixed = makeRecorder(store, host: "grpc://gw.example.com:8443", path: "/api/contents/pkg.Svc/Method")
        let entry = store.entry(prefixed.entryID)
        XCTAssertEqual(entry?.request.url, "grpc://gw.example.com:8443/api/contents/pkg.Svc/Method")
        XCTAssertEqual(entry?.grpc?.service, "pkg.Svc")
        XCTAssertEqual(entry?.grpc?.method, "Method")
        XCTAssertEqual(entry?.host, "gw.example.com")
        XCTAssertEqual(entry?.title, "Svc/Method")
    }

    func testSetOriginAndRawFallback() throws {
        let store = NetworkStore(maxBodySize: 4)
        let recorder = makeRecorder(store)
        recorder.didSend(typeName: "Bin", size: 8, json: nil, raw: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        recorder.setOrigin(.mocked(rule: "Mock gRPC"))
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        recorder.setOrigin(.breakpoint(edited: true))
        let entry = try XCTUnwrap(store.entry(recorder.entryID))
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.request.body?.data, Data([1, 2, 3, 4]))
        XCTAssertEqual(entry.request.body?.originalSize, 8)
        XCTAssertEqual(entry.grpc?.messages.first?.raw, Data([1, 2, 3, 4]))
        XCTAssertEqual(entry.grpc?.messages.first?.size, 8)
    }

    func testConcurrentReceiveFromManyThreads() throws {
        let store = NetworkStore()
        let recorder = makeRecorder(store, callType: .bidirectionalStreaming)
        DispatchQueue.concurrentPerform(iterations: 800) { index in
            if index % 2 == 0 {
                recorder.didSend(typeName: "Out", size: 1, json: "{}")
            } else {
                recorder.didReceive(typeName: "In", size: 2, json: "{}")
            }
        }
        recorder.didFinish(statusCode: 0, message: nil, trailers: [])
        let grpc = try XCTUnwrap(store.entry(recorder.entryID)?.grpc)
        XCTAssertEqual(grpc.sentMessageCount, 400)
        XCTAssertEqual(grpc.receivedMessageCount, 400)
        XCTAssertEqual(grpc.messages.count, 800)
        XCTAssertEqual(store.entry(recorder.entryID)?.requestSize, 400)
        XCTAssertEqual(store.entry(recorder.entryID)?.responseSize, 800)
    }
}
