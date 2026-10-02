import XCTest
@testable import DonkCore

final class CurlExporterTests: XCTestCase {
    func testSimpleGET() {
        let request = RequestSnapshot(url: "https://example.com/a?b=1&c=2")
        XCTAssertEqual(CurlExporter.command(for: request), "curl 'https://example.com/a?b=1&c=2'")
    }

    func testPOSTWithHeadersAndQuotes() {
        let request = RequestSnapshot(
            url: "https://api.example.com/items",
            method: "post",
            headers: [
                HTTPHeader(name: "Content-Type", value: "application/json"),
                HTTPHeader(name: "X-Note", value: "it's"),
                HTTPHeader(name: "Content-Length", value: "18"),
                HTTPHeader(name: ":authority", value: "api.example.com"),
            ],
            body: BodyData(text: #"{"msg":"it's ok"}"#, contentType: "application/json")
        )
        let expected = """
        curl -X POST 'https://api.example.com/items' \\
          -H 'Content-Type: application/json' \\
          -H 'X-Note: it'\\''s' \\
          --data-raw '{"msg":"it'\\''s ok"}'
        """
        XCTAssertEqual(CurlExporter.command(for: request), expected)
    }

    func testNewlinesAndUnicodeArePreservedInsideQuotes() {
        let request = RequestSnapshot(url: "https://example.com/привет", method: "PUT", body: BodyData(text: "line1\nline2 'q' 😀"))
        let expected = "curl -X PUT 'https://example.com/привет' \\\n  --data-raw 'line1\nline2 '\\''q'\\'' 😀'"
        XCTAssertEqual(CurlExporter.command(for: request), expected)
    }

    func testCompressedFlag() {
        let request = RequestSnapshot(url: "https://e.com", headers: [HTTPHeader(name: "accept-encoding", value: "GZIP, deflate, br")])
        XCTAssertEqual(CurlExporter.command(for: request), "curl 'https://e.com' \\\n  -H 'accept-encoding: GZIP, deflate, br' \\\n  --compressed")
        let identity = RequestSnapshot(url: "https://e.com", headers: [HTTPHeader(name: "Accept-Encoding", value: "identity")])
        XCTAssertFalse(CurlExporter.command(for: identity).contains("--compressed"))
    }

    func testBinaryBody() {
        let request = RequestSnapshot(url: "https://e.com/upload", method: "PUT", body: BodyData(data: Data([0xFF, 0x00, 0xC3]), contentType: nil, limit: 10))
        XCTAssertEqual(CurlExporter.command(for: request), "curl -X PUT 'https://e.com/upload' \\\n  --data-binary @body.bin")
    }

    func testGloboffWhenURLHasBracketsOrBraces() {
        XCTAssertEqual(
            CurlExporter.command(for: RequestSnapshot(url: "https://e.com/a?ids[]=1&f={x}")),
            "curl --globoff 'https://e.com/a?ids[]=1&f={x}'"
        )
        XCTAssertFalse(CurlExporter.command(for: RequestSnapshot(url: "https://e.com/a?b=1")).contains("--globoff"))
    }

    func testTruncatedBodyAddsCommentLine() {
        let body = BodyData(data: Data(repeating: UInt8(ascii: "a"), count: 20), contentType: "text/plain", limit: 8)
        let command = CurlExporter.command(for: RequestSnapshot(url: "https://e.com/u", method: "POST", body: body))
        XCTAssertEqual(command, "# donk: request body truncated (8 of 20 bytes)\ncurl -X POST 'https://e.com/u' \\\n  --data-raw 'aaaaaaaa'")
    }

    func testRedactionOverload() {
        let request = RequestSnapshot(
            url: "https://e.com/login?token=abc&lang=en",
            method: "POST",
            headers: [HTTPHeader(name: "Authorization", value: "Bearer secret"), HTTPHeader(name: "Accept", value: "*/*")],
            body: BodyData(text: #"{"login":"bob","password":"hunter2"}"#, contentType: "application/json")
        )
        let plain = CurlExporter.command(for: request)
        XCTAssertTrue(plain.contains("hunter2"))
        XCTAssertEqual(CurlExporter.command(for: request, redaction: nil), plain)
        let redacted = CurlExporter.command(for: request, redaction: .default)
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("Bearer secret"))
        XCTAssertFalse(redacted.contains("token=abc"))
        XCTAssertTrue(redacted.contains("token=••••&lang=en"))
        XCTAssertTrue(redacted.contains("'Authorization: ••••'"))
        XCTAssertTrue(redacted.contains(#""login":"bob","password":"••••""#))
    }

    func testMethodFlagRules() {
        XCTAssertEqual(
            CurlExporter.command(for: RequestSnapshot(url: "https://e.com", method: "GET", body: BodyData(text: "q"))),
            "curl -X GET 'https://e.com' \\\n  --data-raw 'q'"
        )
        XCTAssertEqual(CurlExporter.command(for: RequestSnapshot(url: "https://e.com", method: "DELETE")), "curl -X DELETE 'https://e.com'")
        XCTAssertEqual(CurlExporter.command(for: RequestSnapshot(url: "https://e.com", method: "HEAD")), "curl --head 'https://e.com'")
        XCTAssertEqual(CurlExporter.command(for: RequestSnapshot(url: "https://e.com", method: "BAD METHOD")), "curl -X 'BAD METHOD' 'https://e.com'")
        XCTAssertEqual(
            CurlExporter.command(for: RequestSnapshot(url: "https://e.com", method: "GET", body: BodyData(data: Data(), contentType: nil, limit: 1))),
            "curl 'https://e.com'"
        )
        XCTAssertEqual(CurlExporter.command(for: RequestSnapshot(url: "https://e.com/it's")), "curl 'https://e.com/it'\\''s'")
    }
}

final class GRPCurlExporterTests: XCTestCase {
    private let metadata = [
        HTTPHeader(name: ":authority", value: "api.example.com"),
        HTTPHeader(name: "content-type", value: "application/grpc"),
        HTTPHeader(name: "te", value: "trailers"),
        HTTPHeader(name: "User-Agent", value: "grpc-swift"),
        HTTPHeader(name: "grpc-accept-encoding", value: "gzip"),
        HTTPHeader(name: "grpc-timeout", value: "5S"),
        HTTPHeader(name: "authorization", value: "Bearer abc"),
        HTTPHeader(name: "x-request-id", value: "r'1"),
    ]

    func testUnaryCommand() {
        let entry = grpcEntry(
            metadata: metadata,
            messages: [GRPCMessage(direction: .sent, typeName: "Req", size: 10, json: "{\n  \"accountId\": \"A1\"\n}")],
            timeout: 2.5
        )
        let expected = """
        grpcurl \\
          -H 'authorization: Bearer abc' \\
          -H 'x-request-id: r'\\''1' \\
          -d '{"accountId":"A1"}' \\
          -max-time 2.5 \\
          api.example.com:443 \\
          bank.v1.AccountService/GetAccount
        """
        XCTAssertEqual(GRPCurlExporter.command(for: entry), expected)
    }

    func testPlaintextPortAndNoMessages() {
        let entry = grpcEntry(path: "/pkg.Svc/Ping", host: "localhost:50051", timeout: 30)
        XCTAssertEqual(GRPCurlExporter.command(for: entry, plaintext: true), "grpcurl \\\n  -plaintext \\\n  -max-time 30 \\\n  localhost:50051 \\\n  pkg.Svc/Ping")
    }

    func testStreamsConcatenateSentMessages() {
        let messages = [
            GRPCMessage(direction: .sent, typeName: "N", size: 1, json: #"{ "n": 1 }"#),
            GRPCMessage(direction: .received, typeName: "R", size: 1, json: #"{"ignored":true}"#),
            GRPCMessage(direction: .sent, typeName: "N", size: 1, json: #"{"n":2}"#),
        ]
        for callType in [GRPCCallType.clientStreaming, .bidirectionalStreaming] {
            let entry = grpcEntry(callType: callType, messages: messages)
            XCTAssertTrue(GRPCurlExporter.command(for: entry).contains("-d '{\"n\":1}\n{\"n\":2}'"), "\(callType)")
        }
        let server = grpcEntry(callType: .serverStreaming, messages: messages)
        XCTAssertTrue(GRPCurlExporter.command(for: server).contains("-d '{\"n\":1}' \\"))
    }

    func testPathPrefixAndAddressVariants() {
        let entry = grpcEntry(path: "/api/contents/pkg.Svc/Method", host: "gw.example.com")
        XCTAssertTrue(GRPCurlExporter.command(for: entry).hasSuffix("gw.example.com:443 \\\n  pkg.Svc/Method"))
        XCTAssertEqual(GRPCurlExporter.address(for: "grpc://[::1]/a.B/C"), "[::1]:443")
        XCTAssertEqual(GRPCurlExporter.address(for: "grpc://[::1]:9000/a.B/C"), "[::1]:9000")
        XCTAssertEqual(GRPCurlExporter.address(for: "grpc://grpc/a.B/C"), "grpc:443")
    }
}

final class TextAndHARExporterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000.25)

    private func detailedEntry() -> NetworkEntry {
        var entry = httpEntry(
            url: "https://api.example.com/v1/users?id=42&q=a%20b",
            method: "POST",
            headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
            body: BodyData(text: #"{"name":"Alice"}"#, contentType: "application/json"),
            status: 201,
            responseHeaders: [HTTPHeader(name: "Content-Type", value: "application/json")],
            responseBody: BodyData(data: Data(#"{"id":7,"ok":true}"#.utf8), contentType: "application/json", limit: 1000),
            origin: .mocked(rule: "Users mock"),
            startedAt: start,
            duration: 0.5
        )
        entry.timing.responseStartedAt = start.addingTimeInterval(0.3)
        entry.timing.transactions = [TransactionMetrics(
            fetchStart: start,
            domainLookupStart: start.addingTimeInterval(0.01),
            domainLookupEnd: start.addingTimeInterval(0.03),
            connectStart: start.addingTimeInterval(0.03),
            connectEnd: start.addingTimeInterval(0.1),
            secureConnectionStart: start.addingTimeInterval(0.05),
            secureConnectionEnd: start.addingTimeInterval(0.1),
            requestStart: start.addingTimeInterval(0.1),
            requestEnd: start.addingTimeInterval(0.12),
            responseStart: start.addingTimeInterval(0.3),
            responseEnd: start.addingTimeInterval(0.5),
            networkProtocol: "h2",
            remoteAddress: "93.184.216.34"
        )]
        return entry
    }

    func testEntryTextContainsAllSections() {
        let text = EntryTextExporter.text(for: detailedEntry())
        XCTAssertTrue(text.hasPrefix("POST https://api.example.com/v1/users?id=42&q=a%20b → 201 (500 ms)"))
        XCTAssertTrue(text.contains("Mocked by rule \"Users mock\""))
        XCTAssertTrue(text.contains("REQUEST\nPOST https://api.example.com/v1/users?id=42&q=a%20b\nContent-Type: application/json"))
        XCTAssertTrue(text.contains("{\n  \"name\": \"Alice\"\n}"))
        XCTAssertTrue(text.contains("RESPONSE\n201 Created\nContent-Type: application/json"))
        XCTAssertTrue(text.contains("{\n  \"id\": 7,\n  \"ok\": true\n}"))
        XCTAssertTrue(text.contains("TIMING\nStarted: 2023-11-14T22:13:20.250Z"))
        XCTAssertTrue(text.contains("Duration: 500 ms"))
        XCTAssertTrue(text.contains("Protocol: h2"))
        XCTAssertFalse(text.contains("ERROR"))
    }

    func testEntryTextForGRPCAndErrors() {
        let entry = grpcEntry(
            statusCode: 14,
            statusMessage: "down",
            messages: [
                GRPCMessage(direction: .sent, timestamp: start, typeName: "bank.v1.Req", size: 12, json: #"{"a":1}"#),
                GRPCMessage(direction: .received, timestamp: start.addingTimeInterval(0.1), typeName: "bank.v1.Res", size: 2048, json: nil, raw: Data([1, 2])),
            ]
        )
        let text = EntryTextExporter.text(for: entry)
        XCTAssertTrue(text.contains("GRPC\nbank.v1.AccountService/GetAccount (UNARY)\nStatus: 14 UNAVAILABLE — down"))
        XCTAssertTrue(text.contains("Messages (2)"))
        XCTAssertTrue(text.contains("] → bank.v1.Req (12 B)\n{\n  \"a\": 1\n}"))
        XCTAssertTrue(text.contains("] ← bank.v1.Res (2.0 KB)\n<binary, 2 B>"))
        let failed = httpEntry(state: .failed, status: nil, error: NetworkErrorInfo(domain: "NSURLErrorDomain", code: -1001, message: "Timed out"))
        XCTAssertTrue(EntryTextExporter.text(for: failed).contains("ERROR\nNSURLErrorDomain -1001: Timed out"))
        let binary = httpEntry(responseBody: BodyData(data: Data([0xFF, 0xD8, 0xFF, 0x00]), contentType: "image/jpeg", limit: 2))
        let binaryText = EntryTextExporter.text(for: binary)
        XCTAssertTrue(binaryText.contains("<image image/jpeg, 4 B>\n… truncated (2 B of 4 B)"))
    }

    private func harObject(_ entries: [NetworkEntry]) throws -> [String: Any] {
        let data = try HARExporter.data(for: entries)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["log"] as? [String: Any])
    }

    func testHARStructure() throws {
        let detailed = detailedEntry()
        let older = httpEntry(url: "https://e.com/old", startedAt: start.addingTimeInterval(-10), duration: 0.25)
        let log = try harObject([detailed, older])
        XCTAssertEqual(log["version"] as? String, "1.2")
        XCTAssertEqual((log["creator"] as? [String: Any])?["name"] as? String, "donk")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries[0]["request"] as? [String: Any])?["url"] as? String, "https://e.com/old")

        let entry = entries[1]
        XCTAssertEqual(entry["startedDateTime"] as? String, "2023-11-14T22:13:20.250Z")
        XCTAssertNotNil(entry["cache"] as? [String: Any])
        XCTAssertEqual(entry["serverIPAddress"] as? String, "93.184.216.34")

        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "POST")
        XCTAssertEqual(request["httpVersion"] as? String, "HTTP/2")
        XCTAssertEqual(request["headersSize"] as? Int, -1)
        XCTAssertEqual(request["bodySize"] as? Int, 16)
        XCTAssertEqual((request["cookies"] as? [Any])?.count, 0)
        XCTAssertEqual((request["headers"] as? [[String: String]])?.first?["name"], "Content-Type")
        let query = try XCTUnwrap(request["queryString"] as? [[String: String]])
        XCTAssertEqual(query, [["name": "id", "value": "42"], ["name": "q", "value": "a b"]])
        let postData = try XCTUnwrap(request["postData"] as? [String: Any])
        XCTAssertEqual(postData["mimeType"] as? String, "application/json")
        XCTAssertEqual(postData["text"] as? String, #"{"name":"Alice"}"#)

        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 201)
        XCTAssertEqual(response["statusText"] as? String, "Created")
        XCTAssertEqual(response["redirectURL"] as? String, "")
        XCTAssertEqual(response["headersSize"] as? Int, -1)
        XCTAssertEqual(response["bodySize"] as? Int, 18)
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["size"] as? Int, 18)
        XCTAssertEqual(content["mimeType"] as? String, "application/json")
        XCTAssertEqual(content["text"] as? String, #"{"id":7,"ok":true}"#)

        let timings = try XCTUnwrap(entry["timings"] as? [String: Double])
        XCTAssertEqual(timings["blocked"] ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(timings["dns"] ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(timings["connect"] ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(timings["ssl"] ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(timings["send"] ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(timings["wait"] ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(timings["receive"] ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(entry["time"] as? Double ?? 0, 500, accuracy: 0.01)

        let olderTimings = try XCTUnwrap(entries[0]["timings"] as? [String: Double])
        XCTAssertEqual(olderTimings["wait"] ?? 0, 250, accuracy: 0.01)
        XCTAssertEqual(olderTimings["send"], 0)
        XCTAssertEqual(olderTimings["dns"], -1)
        XCTAssertEqual(entries[0]["time"] as? Double ?? 0, 250, accuracy: 0.01)
    }

    func testHARBinaryFailedAndGRPCEntries() throws {
        let binary = httpEntry(
            url: "https://e.com/img",
            responseHeaders: [HTTPHeader(name: "Content-Type", value: "image/png")],
            responseBody: BodyData(data: Data([0x89, 0x50, 0xFF]), contentType: "image/png", limit: 100),
            startedAt: start
        )
        let failed = httpEntry(url: "https://e.com/fail", state: .failed, status: nil, error: NetworkErrorInfo(domain: "D", code: 1, message: "boom"), startedAt: start.addingTimeInterval(1), duration: nil)
        let grpc = grpcEntry(statusCode: 0, messages: [GRPCMessage(direction: .received, typeName: "R", size: 3, json: "{}")])
        let log = try harObject([binary, failed, grpc])
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 3)
        let byURL = Dictionary(uniqueKeysWithValues: entries.map { (($0["request"] as? [String: Any])?["url"] as? String ?? "", $0) })

        let binaryContent = try XCTUnwrap((byURL["https://e.com/img"]?["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertEqual(binaryContent["encoding"] as? String, "base64")
        XCTAssertEqual(binaryContent["text"] as? String, Data([0x89, 0x50, 0xFF]).base64EncodedString())

        let failedEntry = try XCTUnwrap(byURL["https://e.com/fail"])
        XCTAssertEqual((failedEntry["response"] as? [String: Any])?["status"] as? Int, 0)
        XCTAssertEqual(failedEntry["_error"] as? String, "D 1: boom")
        XCTAssertEqual(failedEntry["time"] as? Double, 0)

        let grpcEntryValue = try XCTUnwrap(byURL["grpc://api.example.com/bank.v1.AccountService/GetAccount"])
        XCTAssertEqual((grpcEntryValue["request"] as? [String: Any])?["httpVersion"] as? String, "HTTP/2")
        let grpcInfo = try XCTUnwrap(grpcEntryValue["_grpc"] as? [String: Any])
        XCTAssertEqual(grpcInfo["statusName"] as? String, "OK")
        XCTAssertEqual((grpcInfo["messages"] as? [Any])?.count, 1)
    }

    func testHARCreatorVersionAndRedaction() throws {
        let entry = httpEntry(
            url: "https://e.com/a?pin=1234",
            headers: [HTTPHeader(name: "Cookie", value: "sid=1")],
            responseHeaders: [HTTPHeader(name: "Set-Cookie", value: "sid=2")],
            responseBody: BodyData(text: #"{"access_token":"t","user":{"name":"A"}}"#, contentType: "application/json")
        )
        let plain = try harObject([entry])
        XCTAssertEqual((plain["creator"] as? [String: Any])?["version"] as? String, DonkEnvironment.version)
        let data = try HARExporter.data(for: [entry], redaction: .default)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("1234"))
        XCTAssertFalse(text.contains("sid=1"))
        XCTAssertFalse(text.contains("sid=2"))
        XCTAssertFalse(text.contains(#"\"t\""#))
        XCTAssertTrue(text.contains("\"name\": \"pin\""))
        XCTAssertEqual(try HARExporter.data(for: [entry]), try HARExporter.data(for: [entry], redaction: nil))
    }

    func testHAREmpty() throws {
        let log = try harObject([])
        XCTAssertEqual((log["entries"] as? [Any])?.count, 0)
    }
}
