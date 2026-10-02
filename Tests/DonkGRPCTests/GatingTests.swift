import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import XCTest

final class GatingTests: EchoTestCase {
    private func addInterferingRules(path: String) {
        harness.addRule("Mock", path: path, action: .mapLocal(MockResponse(grpcMessages: [#"{"text":"mocked"}"#])))
        harness.addRule("Pause", path: path, action: .breakpoint(request: true, response: true))
    }

    private func assertUntouched(
        _ interceptors: RecordingEchoInterceptors,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(harness.store.count, 0, file: file, line: line)
        XCTAssertTrue(harness.center.pending.isEmpty, file: file, line: line)
        XCTAssertFalse(interceptors.created.values.isEmpty, file: file, line: line)
        for interceptor in interceptors.created.values {
            XCTAssertFalse(interceptor.isCapturing, file: file, line: line)
            XCTAssertNil(interceptor.renderBacklog, file: file, line: line)
        }
    }

    func testInactiveEnvironmentSkipsCaptureRulesBreakpointsAndAnyRegistration() throws {
        addInterferingRules(path: "/Get")
        addInterferingRules(path: "/Update")
        let options = harness.options {
            $0.isEnvironmentActive = { false }
            $0.anyTypeRegistry = [Donk_Echo_V1_UnregisteredDetail.self]
        }
        let (client, interceptors) = harness.recordingClient(options: options)

        let call = client.get(.make("hello"))
        XCTAssertEqual(try call.response.wait().text, "echo: hello")
        XCTAssertEqual(try call.status.wait().code, .ok)

        let texts = Collector<String>()
        let chat = client.update { texts.append($0.text) }
        try chat.sendMessage(.make("one")).wait()
        harness.waitUntil { texts.values.count == 1 }
        try chat.sendEnd().wait()
        XCTAssertEqual(try chat.status.wait().code, .ok)

        XCTAssertEqual(harness.state.calls("Get"), 1)
        XCTAssertEqual(harness.state.calls("Update"), 1)
        XCTAssertEqual(texts.values, ["echo: one"])
        XCTAssertFalse(AnyTypeRegistry.shared.contains(Donk_Echo_V1_UnregisteredDetail.self))
        assertUntouched(interceptors)
    }

    func testCaptureDisabledSkipsRulesAndBreakpoints() throws {
        harness.store.isCaptureEnabled = false
        addInterferingRules(path: "/Expand")
        let (client, interceptors) = harness.recordingClient()
        let texts = Collector<String>()
        let call = client.expand(.make("tick") { $0.repeatCount = 3 }) { texts.append($0.text) }
        XCTAssertEqual(try call.status.wait().code, .ok)
        XCTAssertEqual(texts.values, ["tick 0", "tick 1", "tick 2"])
        assertUntouched(interceptors)
    }

    func testHostBypassedInSettingsSkipsRulesAndBreakpoints() throws {
        addInterferingRules(path: "/Get")
        let settings = NetworkSettingsStore(fileName: "settings.json", directory: harness.rulesDirectory)
        settings.update { $0.bypassHosts = ["127.0.0.1"] }
        let (client, interceptors) = harness.recordingClient(options: harness.options { $0.settingsStore = settings })
        XCTAssertEqual(try client.get(.make("quiet")).response.wait().text, "echo: quiet")
        XCTAssertEqual(harness.state.calls("Get"), 1)
        assertUntouched(interceptors)
    }

    func testEnvironmentIsSampledWhenEachCallStarts() throws {
        let active = Collector<Bool>()
        active.append(false)
        let (client, interceptors) = harness.recordingClient(options: harness.options { options in
            options.isEnvironmentActive = { active.values.last ?? false }
        })
        XCTAssertEqual(try client.get(.make("before")).response.wait().text, "echo: before")
        active.append(true)
        XCTAssertEqual(try client.get(.make("after")).response.wait().text, "echo: after")

        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(harness.store.count, 1)
        XCTAssertEqual(entry.grpc?.messages.first?.json, #"{"text":"after"}"#)
        XCTAssertEqual(interceptors.created.values.map(\.isCapturing), [false, true])
    }

    func testBreakpointsAreSkippedWithoutPresenter() throws {
        harness.center.hasPresenter = false
        harness.addRule("Pause Get", path: "/Get", action: .breakpoint(request: true, response: true))
        harness.addRule("Pause Update", path: "/Update", action: .breakpoint(request: true, response: true))
        let pauses = Collector<Int>()
        let subscription = harness.center.changes.sink { pauses.append($0.count) }
        defer { subscription.cancel() }
        let client = harness.client()

        XCTAssertEqual(try client.get(.make("hello")).response.wait().text, "echo: hello")
        let unary = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(unary.origin, .network)
        harness.store.clear(keepPinned: false)

        let texts = Collector<String>()
        let chat = client.update { texts.append($0.text) }
        for text in ["one", "two"] {
            try chat.sendMessage(.make(text)).wait()
        }
        harness.waitUntil { texts.values.count == 2 }
        try chat.sendEnd().wait()
        XCTAssertEqual(try chat.status.wait().code, .ok)
        let stream = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(stream.origin, .network)
        XCTAssertEqual(stream.grpc?.messages.count, 4)
        XCTAssertFalse(pauses.values.contains { $0 > 0 })
    }
}
