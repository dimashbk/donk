import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class RecordingTests: EchoTestCase {
    func testUnaryRecordsMessagesMetadataTrailersAndStatus() throws {
        let client = harness.client()
        let options = CallOptions(customMetadata: ["x-client": "tests"], timeLimit: .timeout(.seconds(5)))
        let call = client.get(.make("hello") { $0.mood = .happy }, callOptions: options)
        XCTAssertEqual(try call.response.wait().text, "echo: hello")
        XCTAssertEqual(try call.status.wait().code, .ok)

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(entry.kind, .grpc)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.origin, .network)
        XCTAssertEqual(entry.request.url, "\(harness.url)/donk.echo.v1.Echo/Get")
        XCTAssertEqual(entry.request.method, "POST")
        XCTAssertEqual(grpc.service, "donk.echo.v1.Echo")
        XCTAssertEqual(grpc.method, "Get")
        XCTAssertEqual(grpc.statusCode, 0)
        XCTAssertEqual(entry.statusLabel, "OK")
        XCTAssertEqual(grpc.requestMetadata.first { $0.name == "x-client" }?.value, "tests")
        XCTAssertFalse(grpc.requestMetadata.contains { $0.name.hasPrefix(":") })
        XCTAssertEqual(grpc.responseHeaders.first { $0.name == "x-server" }?.value, "donk-echo")
        XCTAssertFalse(grpc.responseHeaders.contains { $0.name.hasPrefix(":") })
        XCTAssertEqual(grpc.trailers.first { $0.name == "x-trailer" }?.value, "done")
        XCTAssertEqual(grpc.timeout ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(entry.response?.statusCode, 200)

        XCTAssertEqual(grpc.messages.map(\.direction), [.sent, .received])
        let sent = grpc.messages[0]
        XCTAssertEqual(sent.typeName, "donk.echo.v1.EchoRequest")
        XCTAssertEqual(sent.json, #"{"text":"hello","mood":"MOOD_HAPPY"}"#)
        XCTAssertNil(sent.textFormat)
        XCTAssertEqual(sent.size, try Donk_Echo_V1_EchoRequest.make("hello") { $0.mood = .happy }.serializedData().count)
        XCTAssertEqual(sent.raw?.count, sent.size)
        let received = grpc.messages[1]
        XCTAssertEqual(received.typeName, "donk.echo.v1.EchoResponse")
        XCTAssertTrue(received.json?.contains("echo: hello") == true)
        XCTAssertEqual(entry.request.body?.text, sent.json)
        XCTAssertEqual(entry.response?.body?.text, received.json)
    }

    func testServerStreamingRecordsEveryMessage() throws {
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.expand(.make("tick") { $0.repeatCount = 5 }) { texts.append($0.text) }
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, (0..<5).map { "tick \($0)" })

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(grpc.callType, .serverStreaming)
        XCTAssertEqual(entry.methodLabel, "SERVER STREAM")
        XCTAssertEqual(grpc.messages.filter { $0.direction == .sent }.count, 1)
        XCTAssertEqual(grpc.messages.filter { $0.direction == .received }.count, 5)
        XCTAssertEqual(grpc.trailers.first { $0.name == "x-trailer" }?.value, "expanded")
        XCTAssertEqual(grpc.statusCode, 0)
        XCTAssertEqual(entry.state, .completed)
    }

    func testClientStreamingRecordsEveryMessage() throws {
        let client = harness.client()
        let call = client.collect()
        for text in ["a", "b", "c"] {
            call.sendMessage(.make(text), promise: nil)
        }
        call.sendEnd(promise: nil)
        let response = try call.response.wait()
        XCTAssertEqual(response.text, "a b c")

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(grpc.callType, .clientStreaming)
        XCTAssertEqual(grpc.messages.map(\.direction), [.sent, .sent, .sent, .received])
        XCTAssertEqual(grpc.sentMessageCount, 3)
        XCTAssertEqual(grpc.receivedMessageCount, 1)
        XCTAssertEqual(entry.request.body?.text, #"{"text":"a"}"#)
        XCTAssertEqual(grpc.statusCode, 0)
    }

    func testBidirectionalStreamingRecordsEveryMessage() throws {
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update { texts.append($0.text) }
        for (index, text) in ["one", "two", "three"].enumerated() {
            try call.sendMessage(.make(text)).wait()
            harness.waitUntil { texts.values.count == index + 1 }
        }
        try call.sendEnd().wait()
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["echo: one", "echo: two", "echo: three"])

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let grpc = try XCTUnwrap(entry.grpc)
        XCTAssertEqual(grpc.callType, .bidirectionalStreaming)
        XCTAssertEqual(grpc.messages.count, 6)
        XCTAssertEqual(grpc.messages.map(\.direction), [.sent, .received, .sent, .received, .sent, .received])
        XCTAssertEqual(entry.state, .completed)
    }

    func testStreamingEntryIsMarkedStreamingWhileInFlight() throws {
        let client = harness.client()
        let call = client.expand(.make("slow") { $0.repeatCount = 3; $0.intervalMs = 300 }) { _ in }
        harness.waitForEntry { $0.state == .streaming && ($0.grpc?.receivedMessageCount ?? 0) >= 1 }
        XCTAssertEqual(try call.status.wait().code, .ok)
    }

    func testErrorStatusesAreRecorded() throws {
        let client = harness.client()
        let unavailable = client.get(.make("status:14:backend down"))
        let status = try unavailable.status.wait()
        XCTAssertEqual(status.code, .unavailable)
        XCTAssertEqual(status.message, "backend down")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.statusCode, 14)
        XCTAssertEqual(entry.grpc?.statusMessage, "backend down")
        XCTAssertEqual(entry.statusLabel, "UNAVAILABLE")
        XCTAssertEqual(entry.statusCategory, .serverError)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertNil(entry.error)

        harness.store.clear(keepPinned: false)
        let notFound = client.get(.make("status:5:no such account"))
        XCTAssertEqual(try notFound.status.wait().code, .notFound)
        let missing = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(missing.grpc?.statusCode, 5)
        XCTAssertEqual(missing.grpc?.statusMessage, "no such account")
        XCTAssertEqual(missing.statusCategory, .clientError)
    }

    func testConnectionErrorIsRecordedAsFailure() throws {
        let port = try harness.closedPort()
        let client = harness.client(port: port, fastFailure: true)
        let call = client.get(.make("hello"))
        XCTAssertEqual(try call.status.wait().code, .unavailable)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.request.url, "grpc://127.0.0.1:\(port)/donk.echo.v1.Echo/Get")
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error?.domain, "gRPC")
        XCTAssertEqual(entry.error?.code, 14)
        XCTAssertTrue(entry.error?.message.hasPrefix("UNAVAILABLE") == true)
        XCTAssertEqual(entry.statusLabel, "ERR")
        XCTAssertEqual(entry.statusCategory, .failure)
    }

    func testClientCancelIsRecorded() throws {
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.expand(.make("long") { $0.repeatCount = 50; $0.intervalMs = 100 }) { texts.append($0.text) }
        harness.waitUntil { !texts.values.isEmpty }
        call.cancel(promise: nil)
        XCTAssertEqual(try call.status.wait().code, .cancelled)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.state, .cancelled)
        XCTAssertEqual(entry.statusLabel, "CANCELLED")
        XCTAssertGreaterThanOrEqual(entry.grpc?.receivedMessageCount ?? 0, 1)
    }

    func testDeadlineExceededIsRecordedAsFailure() throws {
        let client = harness.client()
        let call = client.get(.make("sleep:2000"), callOptions: CallOptions(timeLimit: .timeout(.milliseconds(300))))
        XCTAssertEqual(try call.status.wait().code, .deadlineExceeded)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.error?.code, 4)
        XCTAssertTrue(entry.error?.message.hasPrefix("DEADLINE_EXCEEDED") == true)
        XCTAssertEqual(entry.grpc?.timeout ?? 0, 0.3, accuracy: 0.01)
    }

    func testCaptureDisabledRecordsNothingAndSkipsRules() throws {
        harness.store.isCaptureEnabled = false
        harness.addRule("Mock", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        let client = harness.client()
        XCTAssertEqual(try client.get(.make("real")).response.wait().text, "echo: real")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(harness.store.count, 0)
        XCTAssertEqual(harness.state.calls("Get"), 1)
    }

    func testBypassedHostsAreNotRecorded() throws {
        let client = harness.client(options: harness.options { $0.bypassHosts = ["127.0.0.1"] })
        XCTAssertEqual(try client.get(.make("quiet")).response.wait().text, "echo: quiet")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(harness.store.count, 0)
    }

    func testFactoryHelpersReturnDonkInterceptor() {
        let interceptors: [ClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>] = DonkGRPC.interceptors(host: "api.example.com")
        XCTAssertEqual(interceptors.count, 1)
        let interceptor = interceptors.first as? DonkClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>
        XCTAssertEqual(interceptor?.host, "api.example.com")

        let existing = ClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>()
        let appended = DonkGRPC.interceptors(host: nil, after: [existing])
        XCTAssertEqual(appended.count, 2)
        XCTAssertTrue(appended.first === existing)
        XCTAssertTrue(appended.last is DonkClientInterceptor<Donk_Echo_V1_EchoRequest, Donk_Echo_V1_EchoResponse>)
    }
}
