import XCTest
@testable import DonkCore

final class RedactionPolicyTests: XCTestCase {
    private let policy = RedactionPolicy.default

    func testDefaults() {
        XCTAssertEqual(policy.replacement, "••••")
        XCTAssertTrue(policy.redactsHeader("AUTHORIZATION"))
        XCTAssertTrue(policy.redactsHeader("Set-Cookie"))
        XCTAssertFalse(policy.redactsHeader("Content-Type"))
        XCTAssertTrue(policy.redactsKey("ACCESSTOKEN"))
        XCTAssertTrue(policy.redactsKey("card_number"))
        XCTAssertFalse(policy.redactsKey("login"))
    }

    func testHeadersAreRedactedCaseInsensitively() {
        let headers = policy.redact(headers: [
            HTTPHeader(name: "authorization", value: "Bearer x"),
            HTTPHeader(name: "X-API-Key", value: "k"),
            HTTPHeader(name: "Accept", value: "*/*"),
        ])
        XCTAssertEqual(headers, [
            HTTPHeader(name: "authorization", value: "••••"),
            HTTPHeader(name: "X-API-Key", value: "••••"),
            HTTPHeader(name: "Accept", value: "*/*"),
        ])
    }

    func testQueryItemsAndFragment() {
        XCTAssertEqual(
            policy.redact(url: "https://e.com/p?Token=abc&lang=en&pin&card%5Fnumber=4111#access_token=zzz&state=1"),
            "https://e.com/p?Token=••••&lang=en&pin&card%5Fnumber=••••#access_token=••••&state=1"
        )
        XCTAssertEqual(policy.redact(url: "https://e.com/p"), "https://e.com/p")
        XCTAssertEqual(policy.redact(url: "https://e.com/p#section"), "https://e.com/p#section")
        XCTAssertEqual(policy.redact(url: "https://e.com/p?user[password]=x&a=1"), "https://e.com/p?user[password]=••••&a=1")
    }

    func testJSONBodiesAreRedactedRecursivelyPreservingOrder() throws {
        let json = #"{"user":{"login":"bob","Password":"p","cards":[{"pan":"4111","cvv":123,"holder":"BOB"}]},"secret":{"a":1},"z":true}"#
        let redacted = policy.redact(json: json)
        XCTAssertEqual(
            redacted,
            #"{"user":{"login":"bob","Password":"••••","cards":[{"pan":"••••","cvv":"••••","holder":"BOB"}]},"secret":"••••","z":true}"#
        )
        let pretty = "{\n  \"token\": \"t\",\n  \"keep\": 1\n}"
        XCTAssertEqual(policy.redact(json: pretty), "{\n  \"token\": \"••••\",\n  \"keep\": 1\n}")
        XCTAssertEqual(policy.redact(json: #"{"keep":1}"#), #"{"keep":1}"#)
    }

    func testTruncatedJSONFallsBackToScanning() {
        let truncated = #"{"login":"bob","password" : "hun\"ter2","nested":{"token":{"deep":[1,2"#
        XCTAssertEqual(policy.redact(json: truncated), #"{"login":"bob","password" : "••••","nested":{"token":"••••""#)
        XCTAssertEqual(policy.redact(json: #"{"otp":12345,"x":"pass"#), #"{"otp":"••••","x":"pass"#)
        XCTAssertEqual(policy.redact(json: #"{"pass":"x","y":1"#), #"{"pass":"••••","y":1"#)
    }

    func testBodiesByContentType() throws {
        let form = BodyData(text: "username=bob&password=s3cr3t&remember=1", contentType: "application/x-www-form-urlencoded")
        XCTAssertEqual(policy.redact(body: form).text, "username=bob&password=••••&remember=1")
        XCTAssertEqual(policy.redact(body: form).originalSize, form.originalSize)

        let sniffed = BodyData(text: #"  {"pin":"0000"}"#, contentType: "text/plain")
        XCTAssertEqual(policy.redact(body: sniffed).text, #"{"pin":"••••"}"#)

        let plain = BodyData(text: "password=not-form", contentType: "text/plain")
        XCTAssertEqual(policy.redact(body: plain), plain)

        let binary = BodyData(data: Data([0xFF, 0x00, 0x01]), contentType: "application/octet-stream", limit: .max)
        XCTAssertEqual(policy.redact(body: binary), binary)

        let truncated = BodyData(data: Data(#"{"token":"abcdef","more":"#.utf8), contentType: "application/json", limit: 18)
        XCTAssertTrue(truncated.isTruncated)
        let redactedTruncated = policy.redact(body: truncated)
        XCTAssertTrue(redactedTruncated.isTruncated)
        XCTAssertFalse(redactedTruncated.text?.contains("abc") ?? true)
    }

    func testEntryCoversHTTPAndGRPCParts() throws {
        let http = httpEntry(
            url: "https://api.bank.test/v1/login?otp=111",
            headers: [HTTPHeader(name: "Cookie", value: "a=b")],
            body: BodyData(text: #"{"password":"p"}"#, contentType: "application/json"),
            responseHeaders: [HTTPHeader(name: "Set-Cookie", value: "sid=1")],
            responseBody: BodyData(text: #"{"refresh_token":"r","ok":true}"#, contentType: "application/json")
        )
        let redactedHTTP = policy.redact(http)
        XCTAssertEqual(redactedHTTP.request.url, "https://api.bank.test/v1/login?otp=••••")
        XCTAssertEqual(redactedHTTP.request.headers.first?.value, "••••")
        XCTAssertEqual(redactedHTTP.request.body?.text, #"{"password":"••••"}"#)
        XCTAssertEqual(redactedHTTP.response?.headers.first?.value, "••••")
        XCTAssertEqual(redactedHTTP.response?.body?.text, #"{"refresh_token":"••••","ok":true}"#)
        XCTAssertEqual(redactedHTTP.id, http.id)
        XCTAssertEqual(http.request.body?.text, #"{"password":"p"}"#)

        var grpc = grpcEntry(
            metadata: [HTTPHeader(name: "authorization", value: "Bearer g"), HTTPHeader(name: "x-trace", value: "1")],
            messages: [
                GRPCMessage(direction: .sent, typeName: "Login", size: 10, json: #"{"cardNumber":"4111","amount":"5"}"#),
                GRPCMessage(direction: .received, typeName: "Token", size: 10, textFormat: "access_token: \"abc\"\nuser {\n  name: \"A\"\n}"),
            ]
        )
        grpc.grpc?.trailers = [HTTPHeader(name: "x-auth-token", value: "t")]
        grpc.grpc?.responseHeaders = [HTTPHeader(name: "set-cookie", value: "c")]
        let redactedGRPC = policy.redact(grpc)
        let details = try XCTUnwrap(redactedGRPC.grpc)
        XCTAssertEqual(details.requestMetadata, [HTTPHeader(name: "authorization", value: "••••"), HTTPHeader(name: "x-trace", value: "1")])
        XCTAssertEqual(details.trailers.first?.value, "••••")
        XCTAssertEqual(details.responseHeaders.first?.value, "••••")
        XCTAssertEqual(details.messages[0].json, #"{"cardNumber":"••••","amount":"5"}"#)
        XCTAssertEqual(details.messages[1].textFormat, "access_token: \"••••\"\nuser {\n  name: \"A\"\n}")
        XCTAssertEqual(details.sentMessageCount, 1)
        XCTAssertEqual(redactedGRPC.request.headers.first?.value, "••••")
        XCTAssertFalse(GRPCurlExporter.command(for: grpc, redaction: policy).contains("4111"))
        XCTAssertFalse(EntryTextExporter.text(for: grpc, redaction: policy).contains("Bearer g"))
        XCTAssertTrue(EntryTextExporter.text(for: grpc).contains("Bearer g"))
    }

    func testCustomPolicyAndReplacement() {
        let custom = RedactionPolicy(headers: ["x-session"], keys: ["iban"], replacement: "<hidden>")
        XCTAssertEqual(custom.redact(headers: [HTTPHeader(name: "X-Session", value: "1")]).first?.value, "<hidden>")
        XCTAssertEqual(custom.redact(json: #"{"IBAN":"KZ00","password":"p"}"#), #"{"IBAN":"<hidden>","password":"p"}"#)
    }

    func testCodableIsLenient() throws {
        let decoded = try JSONDecoder().decode(RedactionPolicy.self, from: Data(#"{"keys":["iban"]}"#.utf8))
        XCTAssertEqual(decoded.keys, ["iban"])
        XCTAssertEqual(decoded.headers, RedactionPolicy.defaultHeaders)
        XCTAssertEqual(decoded.replacement, "••••")
        let roundTrip = try JSONDecoder().decode(RedactionPolicy.self, from: JSONEncoder().encode(custom()))
        XCTAssertEqual(roundTrip, custom())
    }

    func testNetworkSettingsDecodeOlderFilesWithRedactionDefaults() throws {
        let old = Data(#"{"hiddenHosts":["a.com"],"bypassHosts":[],"maxBodySize":10,"limit":5}"#.utf8)
        let settings = try JSONDecoder().decode(NetworkSettings.self, from: old)
        XCTAssertEqual(settings.hiddenHosts, ["a.com"])
        XCTAssertTrue(settings.redactsExports)
        XCTAssertEqual(settings.redaction, .default)
        XCTAssertEqual(settings.exportRedaction, .default)
        let broken = Data(#"{"limit":5,"redaction":42,"redactsExports":"yes"}"#.utf8)
        let lenient = try JSONDecoder().decode(NetworkSettings.self, from: broken)
        XCTAssertEqual(lenient.limit, 5)
        XCTAssertEqual(lenient.redaction, .default)
        XCTAssertTrue(lenient.redactsExports)
        var disabled = settings
        disabled.redactsExports = false
        XCTAssertNil(disabled.exportRedaction)
        let roundTrip = try JSONDecoder().decode(NetworkSettings.self, from: JSONEncoder().encode(disabled))
        XCTAssertEqual(roundTrip, disabled)
    }

    func testSettingsStorePersistsRedaction() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertEqual(store.settings.redaction, .default)
        store.update { $0.redaction = custom() }
        let reloaded = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertEqual(reloaded.settings.redaction, custom())
    }

    private func custom() -> RedactionPolicy {
        RedactionPolicy(headers: ["x-a"], keys: ["b"], replacement: "#")
    }
}
