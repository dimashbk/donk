import Combine
import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class BreakpointTests: EchoTestCase {
    func testRequestBreakpointResumesWithEditedMetadataAndBody() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"), callOptions: CallOptions(customMetadata: ["x-client": "tests"]))

        let exchange = try XCTUnwrap(harness.waitForPause())
        XCTAssertEqual(exchange.kind, .grpc)
        XCTAssertEqual(exchange.phase, .request)
        XCTAssertEqual(exchange.ruleName, "Pause Get")
        guard case var .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        XCTAssertEqual(request.url, "\(harness.url)/donk.echo.v1.Echo/Get")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers.first { $0.name == "x-client" }?.value, "tests")
        XCTAssertEqual(try JSONValue.parse(request.body)["text"], .string("hello"))
        XCTAssertFalse(request.bodyIsBinary)
        harness.waitForEntry { $0.id == exchange.entryID && $0.state == .paused }
        XCTAssertEqual(harness.state.totalCalls, 0)

        request.body = #"{"text":"edited"}"#
        request.headers.append(HTTPHeader(name: "x-edited", value: "1"))
        harness.center.resolve(exchange.id, with: .resume(.request(request)))

        XCTAssertEqual(try call.response.wait().text, "echo: edited")
        XCTAssertEqual(harness.state.receivedTexts, ["edited"])
        XCTAssertEqual(harness.state.header("x-edited"), "1")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.state, .completed)
        XCTAssertTrue(entry.grpc?.requestMetadata.contains(HTTPHeader(name: "x-edited", value: "1")) == true)
        XCTAssertEqual(entry.grpc?.messages.first?.json, #"{"text":"edited"}"#)
    }

    func testRequestBreakpointResumeUneditedKeepsOrigin() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("plain"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(exchange.id, with: .resume(exchange.payload))
        XCTAssertEqual(try call.response.wait().text, "echo: plain")
        XCTAssertEqual(harness.waitForFinishedEntry()?.origin, .breakpoint(edited: false))
    }

    func testRequestBreakpointAbortCancelsLocally() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(exchange.id, with: .abort)
        let status = try call.status.wait()
        XCTAssertEqual(status.code, .cancelled)
        XCTAssertEqual(status.message, "donk: aborted at breakpoint")
        XCTAssertEqual(harness.state.totalCalls, 0)
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .cancelled)
    }

    func testRequestBreakpointRespondsLocally() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        let response = EditableResponse(headers: [HTTPHeader(name: "x-local", value: "1")], body: #"{"text":"local answer"}"#, grpcStatusCode: 0)
        harness.center.resolve(exchange.id, with: .respond(response))
        XCTAssertEqual(try call.response.wait().text, "local answer")
        XCTAssertEqual(try call.initialMetadata.wait().first(name: "x-local"), "1")
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(harness.state.totalCalls, 0)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.grpc?.messages.map(\.direction), [.sent, .received])
    }

    func testRequestBreakpointInvalidJSONFailsWithInternal() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case var .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        request.body = "{ not json"
        harness.center.resolve(exchange.id, with: .resume(.request(request)))
        let status = try call.status.wait()
        XCTAssertEqual(status.code, .internalError)
        XCTAssertEqual(status.message, "donk: invalid breakpoint request JSON")
    }

    func testClientCancelWhilePausedClearsBreakpoint() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"))
        _ = try XCTUnwrap(harness.waitForPause())
        call.cancel(promise: nil)
        XCTAssertEqual(try call.status.wait().code, .cancelled)
        harness.waitUntil { self.harness.center.pending.isEmpty }
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .cancelled)
    }

    func testDeadlineWhilePausedFailsCall() throws {
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: false))
        let client = harness.client()
        let call = client.get(.make("hello"), callOptions: CallOptions(timeLimit: .timeout(.milliseconds(300))))
        XCTAssertEqual(try call.status.wait().code, .deadlineExceeded)
        harness.waitUntil { self.harness.center.pending.isEmpty }
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .failed)
    }

    func testResponseBreakpointEditsUnaryResponse() throws {
        harness.addRule("Pause Response", path: "/Get", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        XCTAssertEqual(exchange.phase, .response)
        guard case var .response(response) = exchange.payload else { return XCTFail("Expected response payload") }
        XCTAssertEqual(try JSONValue.parse(response.body)["text"], .string("echo: hello"))
        XCTAssertEqual(response.grpcStatusCode, 0)
        XCTAssertEqual(response.headers.first { $0.name == "x-server" }?.value, "donk-echo")
        XCTAssertEqual(harness.state.calls("Get"), 1)

        response.body = #"{"text":"patched"}"#
        response.headers.append(HTTPHeader(name: "x-edited", value: "1"))
        harness.center.resolve(exchange.id, with: .resume(.response(response)))
        XCTAssertEqual(try call.response.wait().text, "patched")
        XCTAssertEqual(try call.initialMetadata.wait().first(name: "x-edited"), "1")
        XCTAssertEqual(try call.trailingMetadata.wait().first(name: "x-trailer"), "done")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.grpc?.messages.last?.json, #"{"text":"patched"}"#)
    }

    func testResponseBreakpointCanTurnSuccessIntoError() throws {
        harness.addRule("Pause Response", path: "/Get", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case var .response(response) = exchange.payload else { return XCTFail("Expected response payload") }
        response.body = ""
        response.grpcStatusCode = 9
        response.grpcStatusMessage = "edited failure"
        harness.center.resolve(exchange.id, with: .resume(.response(response)))
        let status = try call.status.wait()
        XCTAssertEqual(status.code, .failedPrecondition)
        XCTAssertEqual(status.message, "edited failure")
        XCTAssertEqual(harness.waitForFinishedEntry()?.grpc?.statusCode, 9)
    }

    func testResponseBreakpointCanRescueErrorStatus() throws {
        harness.addRule("Pause Response", path: "/Get", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let call = client.get(.make("status:14:down"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case var .response(response) = exchange.payload else { return XCTFail("Expected response payload") }
        XCTAssertEqual(response.grpcStatusCode, 14)
        XCTAssertEqual(response.body, "")
        response.body = #"{"text":"rescued"}"#
        response.grpcStatusCode = 0
        response.grpcStatusMessage = nil
        harness.center.resolve(exchange.id, with: .resume(.response(response)))
        XCTAssertEqual(try call.response.wait().text, "rescued")
        XCTAssertEqual(try call.status.wait().code, .ok)
    }

    func testResponseBreakpointAbort() throws {
        harness.addRule("Pause Response", path: "/Get", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(exchange.id, with: .abort)
        XCTAssertEqual(try call.status.wait().code, .cancelled)
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .cancelled)
    }

    func testStreamingRequestBreakpointPausesOnFirstMessageOnly() throws {
        harness.addRule("Pause Update", path: "/Update", action: .breakpoint(request: true, response: false))
        let pauses = Collector<UUID>()
        let subscription = harness.center.changes.sink { exchanges in
            for exchange in exchanges where !pauses.values.contains(exchange.id) {
                pauses.append(exchange.id)
            }
        }
        defer { subscription.cancel() }
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.update { texts.append($0.text) }
        let sends = ["one", "two", "three"].map { call.sendMessage(.make($0)) }

        let exchange = try XCTUnwrap(harness.waitForPause())
        guard case var .request(request) = exchange.payload else { return XCTFail("Expected request payload") }
        XCTAssertEqual(try JSONValue.parse(request.body)["text"], .string("one"))
        request.body = #"{"text":"uno"}"#
        harness.center.resolve(exchange.id, with: .resume(.request(request)))
        for send in sends {
            try send.wait()
        }
        harness.waitUntil { texts.values.count == 3 }
        call.sendMessage(.make("four"), promise: nil)
        harness.waitUntil { texts.values.count == 4 }
        try call.sendEnd().wait()
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["echo: uno", "echo: two", "echo: three", "echo: four"])
        XCTAssertEqual(pauses.values.count, 1)
        XCTAssertEqual(harness.waitForFinishedEntry()?.grpc?.messages.count, 8)
    }

    func testStreamingResponseBreakpointPausesEachMessage() throws {
        harness.addRule("Pause Expand", path: "/Expand", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.expand(.make("item") { $0.repeatCount = 3 }) { texts.append($0.text) }

        var seen: [String] = []
        for index in 0..<3 {
            let exchange = try XCTUnwrap(harness.waitForPause())
            XCTAssertEqual(exchange.phase, .response)
            guard case var .response(response) = exchange.payload else { return XCTFail("Expected response payload") }
            seen.append(try XCTUnwrap(JSONValue.parse(response.body)["text"]).compact())
            XCTAssertNil(response.grpcStatusCode)
            if index == 1 {
                response.body = #"[{"text":"two a"},{"text":"two b"}]"#
            }
            harness.center.resolve(exchange.id, with: .resume(.response(response)))
            harness.waitUntil { self.harness.center.pending.first?.id != exchange.id }
        }
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(seen, [#""item 0""#, #""item 1""#, #""item 2""#])
        XCTAssertEqual(texts.values, ["item 0", "two a", "two b", "item 2"])
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .breakpoint(edited: true))
        XCTAssertEqual(entry.grpc?.receivedMessageCount, 4)
    }

    func testStreamingResponseBreakpointAbortStopsStream() throws {
        harness.addRule("Pause Expand", path: "/Expand", action: .breakpoint(request: false, response: true))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.expand(.make("item") { $0.repeatCount = 3 }) { texts.append($0.text) }
        let first = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(first.id, with: .resume(first.payload))
        harness.waitUntil { texts.values.count == 1 }
        let second = try XCTUnwrap(harness.waitForPause())
        harness.center.resolve(second.id, with: .abort)
        XCTAssertEqual(try call.status.wait().code, .cancelled)
        XCTAssertEqual(texts.values, ["item 0"])
    }

    func testMockedResponseCanBePausedAtResponseBreakpoint() throws {
        harness.addRule("Mock", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        harness.addRule("Pause", path: "/Get", action: .breakpoint(request: true, response: true))
        let client = harness.client()
        let call = client.get(.make("hello"))
        let exchange = try XCTUnwrap(harness.waitForPause())
        XCTAssertEqual(exchange.phase, .response)
        harness.center.resolve(exchange.id, with: .resume(exchange.payload))
        XCTAssertEqual(try call.response.wait().text, "mocked")
        XCTAssertEqual(harness.waitForFinishedEntry()?.origin, .mocked(rule: "Mock"))
        XCTAssertEqual(harness.state.totalCalls, 0)
    }
}
