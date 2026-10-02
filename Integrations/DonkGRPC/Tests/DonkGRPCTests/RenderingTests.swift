import DonkCore
@testable import DonkGRPC
import Foundation
import GRPC
import SwiftProtobuf
import XCTest

final class RenderingTests: EchoTestCase {
    func testUnregisteredAnyFallsBackToTextFormat() throws {
        let client = harness.client()
        XCTAssertEqual(try client.get(.make("any:unregistered")).response.wait().text, "echo: any:unregistered")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let received = try XCTUnwrap(entry.grpc?.messages.last)
        XCTAssertEqual(received.direction, .received)
        XCTAssertNil(received.json)
        let text = try XCTUnwrap(received.textFormat)
        XCTAssertTrue(text.contains("echo: any:unregistered"))
        XCTAssertTrue(text.contains("UnregisteredDetail"))
        XCTAssertNotNil(received.raw)
        XCTAssertEqual(entry.response?.body?.contentType, "application/x-protobuf")
    }

    func testRegisteredAnyRendersJSON() throws {
        let client = harness.client(options: harness.options { $0.anyTypeRegistry = [Donk_Echo_V1_RegisteredDetail.self] })
        XCTAssertEqual(try client.get(.make("any:registered")).response.wait().text, "echo: any:registered")
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let json = try XCTUnwrap(entry.grpc?.messages.last?.json)
        let detail = try XCTUnwrap(JSONValue.parse(json)["detail"])
        XCTAssertEqual(detail["@type"], .string("type.googleapis.com/donk.echo.v1.RegisteredDetail"))
        XCTAssertEqual(detail["note"], .string("visible"))
    }

    func testJSONEncodingOptions() throws {
        let options = harness.options {
            $0.preserveProtoFieldNames = true
            $0.alwaysPrintEnumsAsInts = true
        }
        let client = harness.client(options: options)
        _ = try client.expand(.make("x") { $0.repeatCount = 1; $0.mood = .grumpy }) { _ in }.status.wait()
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        XCTAssertEqual(entry.grpc?.messages.first?.json, #"{"text":"x","repeat_count":1,"mood":2}"#)
    }

    func testLargeMessagesSkipJSONRendering() throws {
        let options = harness.options {
            $0.maxRenderedMessageSize = 1024
            $0.maxRawMessageSize = 512
        }
        let client = harness.client(options: options)
        let payload = Data(repeating: 7, count: 4096)
        XCTAssertEqual(try client.get(.make("big") { $0.payload = payload }).response.wait().payload, payload)
        let entry = try XCTUnwrap(harness.waitForFinishedEntry())
        let sent = try XCTUnwrap(entry.grpc?.messages.first)
        XCTAssertNil(sent.json)
        XCTAssertNil(sent.raw)
        XCTAssertGreaterThan(sent.size, 4096)
        XCTAssertTrue(sent.textFormat?.contains("rendering skipped") == true)
    }

    func testRendererDecodesJSONArraysAndBinaryBodies() throws {
        let renderer = GRPCMessageRenderer(options: DonkGRPCOptions())
        let many = try renderer.decodeMany(Donk_Echo_V1_EchoResponse.self, from: GRPCEditableBody(text: #"[{"text":"a"},{"text":"b"}]"#, isBinary: false))
        XCTAssertEqual(many.map(\.text), ["a", "b"])
        XCTAssertTrue(try renderer.decodeMany(Donk_Echo_V1_EchoResponse.self, from: .empty).isEmpty)

        var original = Donk_Echo_V1_EchoResponse()
        original.text = "binary"
        let base64 = try original.serializedData().base64EncodedString()
        let decoded = try renderer.decodeOne(Donk_Echo_V1_EchoResponse.self, from: GRPCEditableBody(text: base64, isBinary: true))
        XCTAssertEqual(decoded, original)

        guard case let .patched(patched) = renderer.patch(original, with: .replace("base64:" + base64)) else {
            return XCTFail("Expected patched message")
        }
        XCTAssertEqual(patched, original)
        guard case .invalid = renderer.patch(original, with: .replace("{ broken")) else {
            return XCTFail("Expected invalid patch")
        }
    }

    func testCallTargetNormalization() {
        XCTAssertEqual(GRPCCallTarget.url(host: "https://api.example.com/", path: "pkg.Svc/Method"), "grpc://api.example.com/pkg.Svc/Method")
        XCTAssertEqual(GRPCCallTarget.url(host: nil, path: "/pkg.Svc/Method"), "grpc://grpc/pkg.Svc/Method")
        XCTAssertEqual(GRPCCallTarget.hostWithoutPort("api.example.com:443"), "api.example.com")
        XCTAssertEqual(GRPCCallTarget.hostWithoutPort("[::1]:8080"), "::1")
        XCTAssertEqual(GRPCCallTarget.hostWithoutPort("api.example.com"), "api.example.com")
    }
}
