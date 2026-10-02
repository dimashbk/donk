import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class RuleTests: EchoTestCase {
    func testInactiveEnvironmentPassesCallsThroughUntouched() throws {
        harness.addRule("Mock Get", path: "/donk.echo.v1.Echo/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        let options = harness.options { $0.isEnvironmentActive = { false } }
        let client = harness.client(options: options)
        let call = client.get(.make("hello"))
        XCTAssertEqual(try call.response.wait().text, "echo: hello")
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(harness.state.totalCalls, 1)
        XCTAssertEqual(harness.store.count, 0)
        XCTAssertTrue(harness.center.pending.isEmpty)
    }

    func testDefaultOptionsFollowDonkEnvironment() {
        XCTAssertFalse(DonkEnvironment.isActive)
        XCTAssertFalse(DonkGRPCOptions().isEnvironmentActive())
    }

    func testMapLocalAnswersWithoutHittingServer() throws {
        let mock = MockResponse(
            headers: [HTTPHeader(name: "x-mock", value: "yes")],
            delay: 0.3,
            grpcMessages: [#"{"text":"mocked","index":7}"#]
        )
        harness.addRule("Mock Get", path: "/donk.echo.v1.Echo/Get", action: .mapLocal(mock))
        let client = harness.client()
        let started = Date()
        let call = client.get(.make("hello"))
        let response = try call.response.wait()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(response.text, "mocked")
        XCTAssertEqual(response.index, 7)
        XCTAssertEqual(try call.initialMetadata.wait().first(name: "x-mock"), "yes")
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertGreaterThanOrEqual(elapsed, 0.29)
        XCTAssertEqual(harness.state.totalCalls, 0)

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .mocked(rule: "Mock Get"))
        XCTAssertEqual(entry.grpc?.statusCode, 0)
        XCTAssertEqual(entry.grpc?.messages.map(\.direction), [.sent, .received])
        XCTAssertEqual(entry.grpc?.responseHeaders.first { $0.name == "x-mock" }?.value, "yes")
    }

    func testMapLocalStreamsMessagesAndCustomStatus() throws {
        let mock = MockResponse(
            grpcStatusCode: 5,
            grpcStatusMessage: "gone",
            grpcMessages: [#"{"text":"first"}"#, #"{"text":"second"}"#]
        )
        harness.addRule("Mock Expand", path: "/Expand", action: .mapLocal(mock))
        let client = harness.client()
        let texts = Collector<String>()
        let call = client.expand(.make("x")) { texts.append($0.text) }
        let status = try call.status.wait()
        XCTAssertEqual(status.code, .notFound)
        XCTAssertEqual(status.message, "gone")
        XCTAssertEqual(texts.values, ["first", "second"])
        XCTAssertEqual(harness.state.totalCalls, 0)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.receivedMessageCount, 2)
        XCTAssertEqual(entry.grpc?.statusCode, 5)
    }

    func testMapLocalWaitsForClientStreamToEnd() throws {
        harness.addRule("Mock Collect", path: "/Collect", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"collected"}"#])))
        let client = harness.client()
        let call = client.collect()
        try call.sendMessage(.make("a")).wait()
        try call.sendMessage(.make("b")).wait()
        try call.sendEnd().wait()
        XCTAssertEqual(try call.response.wait().text, "collected")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.sentMessageCount, 2)
        XCTAssertEqual(harness.state.totalCalls, 0)
    }

    func testMapLocalWithInvalidJSONFailsWithInternal() throws {
        harness.addRule("Broken", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"nope": true}"#])))
        let client = harness.client()
        let status = try client.get(.make("hello")).status.wait()
        XCTAssertEqual(status.code, .internalError)
        XCTAssertEqual(status.message, "donk: invalid mock JSON")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.statusCode, 13)
    }

    func testMapLocalWorksWhenServerIsUnreachable() throws {
        harness.addRule("Offline", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"offline"}"#])))
        let port = try harness.closedPort()
        let client = harness.client(port: port, fastFailure: true)
        XCTAssertEqual(try client.get(.make("hello")).response.wait().text, "offline")
    }

    func testCancelDuringMockDelay() throws {
        harness.addRule("Slow", path: "/Get", action: .mapLocal(MockResponse(delay: 5, grpcMessages: [#"{"text":"late"}"#])))
        let client = harness.client()
        let call = client.get(.make("hello"))
        harness.waitForEntry { _ in true }
        call.cancel(promise: nil)
        XCTAssertEqual(try call.status.wait().code, .cancelled)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.state, .cancelled)
    }

    func testDeadlineDuringMockDelay() throws {
        harness.addRule("Slow", path: "/Get", action: .mapLocal(MockResponse(delay: 5, grpcMessages: [#"{"text":"late"}"#])))
        let client = harness.client()
        let call = client.get(.make("hello"), callOptions: CallOptions(timeLimit: .timeout(.milliseconds(200))))
        XCTAssertEqual(try call.status.wait().code, .deadlineExceeded)
        XCTAssertEqual(harness.waitForFinishedEntry()?.state, .failed)
    }

    func testRewriteRequestAndResponse() throws {
        let request = RequestRewrite(
            headers: HeaderPatch(set: [HTTPHeader(name: "x-rewritten", value: "yes")], remove: ["x-drop"]),
            body: .findReplace([FindReplace(find: "hello", replace: "bonjour")])
        )
        let response = ResponseRewrite(
            headers: HeaderPatch(set: [HTTPHeader(name: "x-patched", value: "1")]),
            body: .findReplace([FindReplace(find: "echo", replace: "ECHO")])
        )
        harness.addRule("Rewrite", path: "/Get", action: .rewrite(request: request, response: response))
        let client = harness.client()
        let call = client.get(.make("hello"), callOptions: CallOptions(customMetadata: ["x-drop": "1", "x-keep": "1"]))
        XCTAssertEqual(try call.response.wait().text, "ECHO: bonjour")
        XCTAssertEqual(try call.initialMetadata.wait().first(name: "x-patched"), "1")
        XCTAssertEqual(harness.state.receivedTexts, ["bonjour"])
        XCTAssertEqual(harness.state.header("x-rewritten"), "yes")
        XCTAssertNil(harness.state.header("x-drop"))
        XCTAssertEqual(harness.state.header("x-keep"), "1")

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.origin, .rewritten(rule: "Rewrite"))
        XCTAssertTrue(entry.grpc?.requestMetadata.contains(HTTPHeader(name: "x-rewritten", value: "yes")) == true)
        XCTAssertTrue(entry.grpc?.messages.first?.json?.contains("bonjour") == true)
        XCTAssertTrue(entry.grpc?.messages.last?.json?.contains("ECHO: bonjour") == true)
    }

    func testRewriteReplacesStreamingMessages() throws {
        let response = ResponseRewrite(body: .replace(#"{"text":"replaced"}"#))
        harness.addRule("Replace", path: "/Expand", action: .rewrite(request: nil, response: response))
        let client = harness.client()
        let texts = Collector<String>()
        XCTAssertEqual(try client.expand(.make("x") { $0.repeatCount = 3 }) { texts.append($0.text) }.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["replaced", "replaced", "replaced"])
    }

    func testRewriteOverridesStatus() throws {
        let response = ResponseRewrite(grpcStatusCode: 7, grpcStatusMessage: "denied by donk")
        harness.addRule("Deny", path: "/Expand", action: .rewrite(request: nil, response: response))
        let client = harness.client()
        let status = try client.expand(.make("x") { $0.repeatCount = 1 }) { _ in }.status.wait()
        XCTAssertEqual(status.code, .permissionDenied)
        XCTAssertEqual(status.message, "denied by donk")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.statusCode, 7)
        XCTAssertEqual(entry.grpc?.statusMessage, "denied by donk")
    }

    func testRewriteProducingInvalidJSONFailsWithInternal() throws {
        let request = RequestRewrite(body: .findReplace([FindReplace(find: "\"text\"", replace: "\"unknownField\"")]))
        harness.addRule("Broken", path: "/Get", action: .rewrite(request: request, response: nil))
        let client = harness.client()
        let status = try client.get(.make("hello")).status.wait()
        XCTAssertEqual(status.code, .internalError)
        XCTAssertEqual(status.message, "donk: invalid rewritten request JSON")
        XCTAssertEqual(harness.state.totalCalls, 0)
    }

    func testRulesAreIgnoredWhenDisabledInOptions() throws {
        harness.addRule("Mock", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        let client = harness.client(options: harness.options { $0.isRulesEnabled = false })
        XCTAssertEqual(try client.get(.make("real")).response.wait().text, "echo: real")
        XCTAssertEqual(harness.waitForFinishedEntry()?.origin, .network)
    }

    func testRulesAreIgnoredWhenRuleStoreIsDisabled() throws {
        harness.addRule("Mock", path: "/Get", action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        harness.ruleStore.isEnabled = false
        let client = harness.client()
        XCTAssertEqual(try client.get(.make("real")).response.wait().text, "echo: real")
    }
}
