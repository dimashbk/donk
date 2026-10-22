import DonkCore
import Foundation
import XCTest
@testable import DonkRemote

final class RemoteProtocolTests: XCTestCase {
    // MARK: - Hello

    func testHelloCarriesIdentityAndCapabilities() throws {
        let frame = try JSONValue.parse(testIdentity.hello(hasCrashes: true, hasForegroundScene: true))
        XCTAssertEqual(frame["jsonrpc"], .string("2.0"))
        XCTAssertEqual(frame["method"], .string("hello"))
        XCTAssertNil(frame["id"])
        let params = try XCTUnwrap(frame["params"])
        XCTAssertEqual(params.keys, ["protocol", "session", "donkVersion", "app", "device", "capabilities"])
        XCTAssertEqual(params["protocol"]?.int, 1)
        XCTAssertEqual(params["session"]?.string, testSession.uuidString)
        XCTAssertEqual(params["donkVersion"]?.string, "0.2.3")
        let app = try XCTUnwrap(params["app"])
        XCTAssertEqual(app.keys, ["name", "bundleID", "version", "build", "osVersion", "deviceModel"])
        XCTAssertEqual(app["name"]?.string, "Freedom Business")
        XCTAssertEqual(app["bundleID"]?.string, "kz.globerce.fb")
        XCTAssertEqual(app["version"]?.string, "1.17.0")
        XCTAssertEqual(app["build"]?.string, "1234")
        XCTAssertEqual(app["osVersion"]?.string, "26.0")
        XCTAssertEqual(app["deviceModel"]?.string, "iPhone17,1")
        let device = try XCTUnwrap(params["device"])
        XCTAssertEqual(device["name"]?.string, "iPhone 17 Pro")
        XCTAssertEqual(device["isSimulator"]?.bool, true)
        XCTAssertEqual(device["simulatorUDID"]?.string, "39C8B439-0F4B-4F0C-93E3-EC1DE3BB265E")
        XCTAssertEqual(params["capabilities"], .array([.string("network"), .string("crashes"), .string("ui")]))
    }

    func testHelloCapabilitiesDependOnCrashesAndScene() throws {
        let bare = try JSONValue.parse(testIdentity.hello(hasCrashes: false, hasForegroundScene: false))
        XCTAssertEqual(bare["params"]?["capabilities"], .array([.string("network")]))
        let ui = try JSONValue.parse(testIdentity.hello(hasCrashes: false, hasForegroundScene: true))
        XCTAssertEqual(ui["params"]?["capabilities"], .array([.string("network"), .string("ui")]))
    }

    func testDeviceOmitsUDIDOnDevices() {
        let device = RemoteDevice.current(environment: ["SIMULATOR_DEVICE_NAME": "iPhone 17 Pro", "SIMULATOR_UDID": "ABC"])
        XCTAssertEqual(device.name, "iPhone 17 Pro")
        XCTAssertEqual(device.simulatorUDID, "ABC")
        XCTAssertTrue(device.isSimulator)
        let real = RemoteDevice(name: "Phone", isSimulator: false, simulatorUDID: nil)
        XCTAssertEqual(real.json.keys, ["name", "isSimulator"])
    }

    func testProcessLaunchDateIsInThePast() {
        XCTAssertLessThanOrEqual(ProcessLaunch.date, Date())
        XCTAssertGreaterThan(ProcessLaunch.date, Date().addingTimeInterval(-24 * 3600))
    }

    // MARK: - Parsing

    func testParsesRequestsNotificationsAndResponses() {
        XCTAssertEqual(
            RemoteIncoming.parse(#"{"jsonrpc":"2.0","id":"7","method":"app.info"}"#),
            .request(id: .string("7"), method: "app.info", params: nil)
        )
        XCTAssertEqual(
            RemoteIncoming.parse(#"{"jsonrpc":"2.0","id":3,"method":"network.get","params":{"id":"x"}}"#),
            .request(id: .number("3"), method: "network.get", params: .object([JSONMember(key: "id", value: .string("x"))]))
        )
        XCTAssertEqual(
            RemoteIncoming.parse(#"{"jsonrpc":"2.0","method":"welcome","params":{"protocol":1}}"#),
            .notification(method: "welcome", params: .object([JSONMember(key: "protocol", value: .number("1"))]))
        )
        XCTAssertEqual(RemoteIncoming.parse(#"{"jsonrpc":"2.0","id":"1","result":{}}"#), .response)
        XCTAssertEqual(RemoteIncoming.parse("not json"), .invalid(id: .null))
        XCTAssertEqual(RemoteIncoming.parse(#"[1,2]"#), .invalid(id: .null))
        XCTAssertEqual(RemoteIncoming.parse(#"{"id":"9","method":42}"#), .invalid(id: .string("9")))
        XCTAssertEqual(RemoteIncoming.parse(#"{"id":{"a":1},"method":"x"}"#), .invalid(id: .null))
        XCTAssertEqual(RemoteIncoming.parse(#"{"id":"5"}"#), .invalid(id: .string("5")))
        XCTAssertEqual(RemoteIncoming.parse(#"{"id":"6","method":"x","params":"oops"}"#), .invalid(id: .string("6")))
    }

    // MARK: - Dispatch errors

    func testUnknownMethodIsMethodNotFound() async {
        let error = await callError(RemoteFixture().handler, "network.delete")
        XCTAssertEqual(error?.code, -32601)
        XCTAssertEqual(error?.message.contains("network.delete"), true)
    }

    func testInvalidParamsAreRejected() async {
        let handler = RemoteFixture().handler
        let notObject = await callError(handler, "network.list", "[1]")
        XCTAssertEqual(notObject?.code, -32602)
        let wrongType = await callError(handler, "network.list", #"{"limit":"ten"}"#)
        XCTAssertEqual(wrongType?.code, -32602)
        let fraction = await callError(handler, "network.list", #"{"limit":2.5}"#)
        XCTAssertEqual(fraction?.code, -32602)
        let unknownKind = await callError(handler, "network.list", #"{"kinds":["ftp"]}"#)
        XCTAssertEqual(unknownKind?.code, -32602)
        let unknownStatus = await callError(handler, "network.list", #"{"status":["teapot"]}"#)
        XCTAssertEqual(unknownStatus?.code, -32602)
        let notArray = await callError(handler, "network.list", #"{"hosts":"api.example.com"}"#)
        XCTAssertEqual(notArray?.code, -32602)
        let missingID = await callError(handler, "network.get", "{}")
        XCTAssertEqual(missingID?.code, -32602)
        let format = await callError(handler, "ui.screenshot", #"{"format":"gif"}"#)
        XCTAssertEqual(format?.code, -32602)
        let flag = await callError(handler, "network.list", #"{"onlyPinned":"yes"}"#)
        XCTAssertEqual(flag?.code, -32602)
    }

    func testInvalidFramesGetInvalidRequestWithNullID() async throws {
        let handler = RemoteFixture().handler
        let response = await handler.handle("{oops")
        let frame = try JSONValue.parse(try XCTUnwrap(response))
        XCTAssertEqual(frame["id"], .null)
        XCTAssertEqual(frame["error"]?["code"]?.int, -32600)
        let notification = await handler.handle(#"{"jsonrpc":"2.0","method":"welcome","params":{}}"#)
        XCTAssertNil(notification)
        let reply = await handler.handle(#"{"jsonrpc":"2.0","id":"1","result":{}}"#)
        XCTAssertNil(reply)
    }

    func testNumericIDsAreEchoed() async throws {
        let response = await RemoteFixture().handler.handle(#"{"jsonrpc":"2.0","id":17,"method":"app.info"}"#)
        let frame = try JSONValue.parse(try XCTUnwrap(response))
        XCTAssertEqual(frame["id"], .number("17"))
        XCTAssertNotNil(frame["result"])
    }

    func testOversizedResultBecomesUnavailableError() async {
        var fixture = RemoteFixture()
        fixture.maxFrameBytes = 300
        for index in 0..<5 {
            fixture.store.add(makeHTTPEntry(url: "https://api.example.com/v1/items/\(index)"))
        }
        let error = await callError(fixture.handler, "network.list")
        XCTAssertEqual(error?.code, -32001)
    }

    func testUIMethodsAreUnavailableWithoutProvider() async {
        let handler = RemoteFixture().handler
        let tree = await callError(handler, "ui.tree")
        XCTAssertEqual(tree?.code, -32001)
        let screenshot = await callError(handler, "ui.screenshot")
        XCTAssertEqual(screenshot?.code, -32001)
    }

    // MARK: - app.info

    func testAppInfo() async throws {
        var fixture = RemoteFixture()
        fixture.crashes = FakeCrashProvider(reports: [sampleCrash(), sampleCrash()])
        fixture.store.add(makeHTTPEntry(responseBody: BodyData(text: "hello")))
        fixture.store.add(makeHTTPEntry())
        fixture.rules.add(NetworkRule(name: "On", match: RuleMatch(url: URLMatcher(pattern: "/a")), action: .breakpoint(request: true, response: false)))
        fixture.rules.add(NetworkRule(name: "Off", isEnabled: false, match: RuleMatch(url: URLMatcher(pattern: "/b")), action: .breakpoint(request: true, response: false)))
        let info = try await call(fixture.handler, "app.info")
        XCTAssertEqual(info.keys, ["app", "device", "donkVersion", "session", "uptimeSec", "network", "rules", "crashes"])
        XCTAssertEqual(info["app"]?["bundleID"]?.string, "kz.globerce.fb")
        XCTAssertEqual(info["device"]?["simulatorUDID"]?.string, "39C8B439-0F4B-4F0C-93E3-EC1DE3BB265E")
        XCTAssertEqual(info["session"]?.string, testSession.uuidString)
        XCTAssertEqual(info["uptimeSec"]?.double ?? 0, 812.4, accuracy: 0.05)
        XCTAssertEqual(info["network"]?["captureEnabled"]?.bool, true)
        XCTAssertEqual(info["network"]?["entries"]?.int, 2)
        XCTAssertEqual(info["network"]?["totalBytes"]?.int, fixture.store.totalBytes)
        XCTAssertEqual(info["network"]?["limit"]?.int, 1000)
        XCTAssertEqual(info["rules"]?["enabled"]?.bool, true)
        XCTAssertEqual(info["rules"]?["active"]?.int, 1)
        XCTAssertEqual(info["crashes"]?["installed"]?.bool, true)
        XCTAssertEqual(info["crashes"]?["reports"]?.int, 2)
    }

    func testAppInfoOmitsCrashesWithoutProvider() async throws {
        let info = try await call(RemoteFixture().handler, "app.info")
        XCTAssertNil(info["crashes"])
    }

    // MARK: - Values

    func testDatesAreUTCWithMilliseconds() {
        XCTAssertEqual(RemoteJSON.dateString(Date(timeIntervalSince1970: 1_792_662_065.125)), "2026-10-22T09:41:05.125Z")
        XCTAssertEqual(RemoteJSON.dateString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }

    func testNumbersAreCompact() {
        XCTAssertEqual(RemoteJSON.number(341.2), .number("341.2"))
        XCTAssertEqual(RemoteJSON.number(12), .number("12"))
        XCTAssertEqual(RemoteJSON.number(0.33333, decimals: 2), .number("0.33"))
        XCTAssertEqual(RemoteJSON.number(-0.0001, decimals: 2), .number("0"))
        XCTAssertNil(RemoteJSON.number(.infinity))
        XCTAssertNil(RemoteJSON.number(.nan))
    }

    func testPrefixCutsOnScalarBoundary() {
        let text = "a" + String(repeating: "😀", count: 10)
        let cut = RemoteJSON.prefix(text, maxBytes: 7)
        XCTAssertTrue(cut.isCut)
        XCTAssertEqual(cut.text, "a😀")
        let combining = "e\u{301}e\u{301}"
        let mark = RemoteJSON.prefix(combining, maxBytes: 2)
        XCTAssertEqual(mark.text.unicodeScalars.map(\.value), [0x65])
        XCTAssertEqual(RemoteJSON.prefix("short", maxBytes: 10).isCut, false)
    }

    func testBackoffSchedule() {
        let backoff = RemoteBackoff.standard
        XCTAssertEqual((1...9).map { backoff.delay(afterFailures: $0) }, [1, 2, 4, 8, 16, 30, 30, 30, 30])
        XCTAssertEqual(backoff.delay(afterFailures: 0), 1)
    }

    func testConfigurationDefaults() {
        let configuration = RemoteConfiguration()
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.hubURL.absoluteString, "ws://127.0.0.1:7337/app")
        XCTAssertTrue(configuration.redacts)
        XCTAssertNil(configuration.redaction)
    }

    func testDisabledConfigurationDoesNotStart() {
        let runtime = RemoteRuntime()
        runtime.start(RemoteConfiguration())
        XCTAssertEqual(runtime.status, .stopped)
    }
}
