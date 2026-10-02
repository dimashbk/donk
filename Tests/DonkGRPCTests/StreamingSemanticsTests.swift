import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class StreamingSemanticsTests: EchoTestCase {
    func testBidiRequestBreakpointForwardsMetadataBeforeFirstMessage() throws {
        harness.addRule("Pause Update", path: "/Update", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update(callOptions: CallOptions(customMetadata: ["x-client": "tests"])) { texts.append($0.text) }

        harness.waitUntil { self.harness.state.calls("Update") == 1 }
        XCTAssertTrue(harness.center.pending.isEmpty)
        XCTAssertEqual(harness.state.header("x-client"), "tests")

        let send = call.sendMessage(.make("one"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case var .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        XCTAssertEqual(request.headers.first { $0.name == "x-client" }?.value, "tests")
        XCTAssertEqual(try JSONValue.parse(request.body)["text"], .string("one"))
        XCTAssertTrue(harness.state.receivedTexts.isEmpty)

        request.body = #"{"text":"uno"}"#
        request.headers.append(HTTPHeader(name: "x-late", value: "ignored"))
        harness.center.resolve(exchange.id, with: .resume(.request(request)))
        try send.wait()
        harness.waitUntil { texts.values.count == 1 }
        try call.sendEnd().wait()
        XCTAssertEqual(try call.status.wait().code, .ok)

        XCTAssertEqual(texts.values, ["echo: uno"])
        XCTAssertNil(harness.state.header("x-late"))
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertFalse(entry.grpc?.requestMetadata.contains { $0.name == "x-late" } ?? true)
    }

    func testClientStreamRequestBreakpointForwardsMetadataImmediately() throws {
        harness.addRule("Pause Collect", path: "/Collect", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.collect()

        harness.waitUntil { self.harness.state.calls("Collect") == 1 }
        XCTAssertTrue(harness.center.pending.isEmpty)

        let sends = ["a", "b"].map { call.sendMessage(.make($0)) }
        let end = call.sendEnd()
        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case let .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        XCTAssertEqual(try JSONValue.parse(request.body)["text"], .string("a"))
        harness.center.resolve(exchange.id, with: .resume(exchange.payload))
        for send in sends {
            try send.wait()
        }
        try end.wait()
        XCTAssertEqual(try call.response.wait().text, "a b")
        XCTAssertEqual(harness.waitForFinishedEntry()?.grpc?.sentMessageCount, 2)
    }

    func testStreamingRequestWithoutMessagesEndsWithoutPausing() throws {
        harness.addRule("Pause Collect", path: "/Collect", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.collect()
        try call.sendEnd().wait()
        let response = try call.response.wait()
        XCTAssertEqual(response.text, "")
        XCTAssertEqual(response.index, 0)
        XCTAssertTrue(harness.center.pending.isEmpty)
    }

    func testStreamingRequestBreakpointRespondCancelsServerStream() throws {
        harness.addRule("Pause Update", path: "/Update", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update { texts.append($0.text) }
        call.sendMessage(.make("one"), promise: nil)
        let exchange = try XCTUnwrap(harness.waitForPause())
        let local = EditableResponse(body: #"[{"text":"local a"},{"text":"local b"}]"#, grpcStatusCode: 0)
        harness.center.resolve(exchange.id, with: .respond(local))

        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["local a", "local b"])
        XCTAssertTrue(harness.state.receivedTexts.isEmpty)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.grpc?.sentMessageCount, 1)
        XCTAssertEqual(entry.grpc?.receivedMessageCount, 2)
    }

    func testStreamingRequestBreakpointAbortEndsCall() throws {
        harness.addRule("Pause Update", path: "/Update", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.update { _ in }
        call.sendMessage(.make("one"), promise: nil)
        let exchange = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(exchange.id, with: .abort)
        let status = try call.status.wait()
        XCTAssertEqual(status.code, .cancelled)
        XCTAssertEqual(status.message, "donk: aborted at breakpoint")
        XCTAssertTrue(harness.state.receivedTexts.isEmpty)
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .cancelled)
    }

    func testBidiMapLocalAnswersAfterFirstClientMessage() throws {
        harness.addRule("Mock Update", path: "/Update", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"a"}"#, #"{"text":"b"}"#])))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update { texts.append($0.text) }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(texts.values.isEmpty)

        try call.sendMessage(.make("hi")).wait()
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["a", "b"])
        XCTAssertEqual(harness.state.totalCalls, 0)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .mocked(rule: "Mock Update"))
        XCTAssertEqual(entry.grpc?.messages.map(\.direction), [.sent, .received, .received])
    }

    func testBidiMapLocalAnswersOnEndWithoutMessages() throws {
        harness.addRule("Mock Update", path: "/Update", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"only"}"#])))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update { texts.append($0.text) }
        try call.sendEnd().wait()
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["only"])
        XCTAssertEqual(harness.state.totalCalls, 0)
    }

    func testSingleRequestCallStillHoldsMetadataAtRequestBreakpoint() throws {
        harness.addRule("Pause Expand", path: "/Expand", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.expand(.make("x") { $0.repeatCount = 1 }) { _ in }
        let exchange = try XCTUnwrap(harness.waitForPause())
        XCTAssertEqual(harness.state.totalCalls, 0)
        guard case var .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        request.headers.append(HTTPHeader(name: "x-edited", value: "1"))
        harness.center.resolve(exchange.id, with: .resume(.request(request)))
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(harness.state.header("x-edited"), "1")
    }
}
