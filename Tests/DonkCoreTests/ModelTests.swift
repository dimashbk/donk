import XCTest
@testable import DonkCore

final class BodyDataTests: XCTestCase {
    func testTruncatesToLimit() {
        let body = BodyData(data: Data("0123456789".utf8), contentType: "text/plain", limit: 4)
        XCTAssertEqual(body.data, Data("0123".utf8))
        XCTAssertEqual(body.originalSize, 10)
        XCTAssertTrue(body.isTruncated)
        XCTAssertEqual(body.text, "0123")
    }

    func testKeepsDataWithinLimit() {
        let body = BodyData(data: Data("abc".utf8), contentType: nil, limit: 3)
        XCTAssertEqual(body.data, Data("abc".utf8))
        XCTAssertEqual(body.originalSize, 3)
        XCTAssertFalse(body.isTruncated)
        let empty = BodyData(data: Data("abc".utf8), contentType: nil, limit: 0)
        XCTAssertTrue(empty.data.isEmpty)
        XCTAssertTrue(empty.isTruncated)
        XCTAssertEqual(empty.originalSize, 3)
    }

    func testSliceInputIsRebased() {
        let source = Data("xxhello".utf8)
        let slice = source.dropFirst(2)
        let body = BodyData(data: slice, contentType: nil, limit: 100)
        XCTAssertEqual(body.data.startIndex, 0)
        XCTAssertEqual(body.text, "hello")
        let truncated = BodyData(data: slice, contentType: nil, limit: 2)
        XCTAssertEqual(truncated.data.startIndex, 0)
        XCTAssertEqual(truncated.text, "he")
    }

    func testTextDecoding() {
        XCTAssertEqual(BodyData(text: "Привет 😀").text, "Привет 😀")
        XCTAssertNil(BodyData(data: Data([0x61, 0xC3, 0x28, 0xFF]), contentType: nil, limit: 100).text)
        let emoji = Data("ab😀".utf8)
        let cut = BodyData(data: emoji, contentType: "text/plain", limit: emoji.count - 1)
        XCTAssertTrue(cut.isTruncated)
        XCTAssertEqual(cut.text, "ab")
    }

    func testJSONDetectionByContentType() {
        let body = BodyData(data: Data("not json".utf8), contentType: "application/vnd.api+json; charset=utf-8", limit: 100)
        XCTAssertTrue(body.isJSON)
        XCTAssertNil(body.prettyJSON)
        XCTAssertTrue(BodyData(data: Data(), contentType: "APPLICATION/JSON", limit: 10).isJSON)
    }

    func testJSONDetectionBySniffing() {
        XCTAssertTrue(BodyData(data: Data("  \n{\"a\":1}".utf8), contentType: "text/plain", limit: 100).isJSON)
        XCTAssertTrue(BodyData(data: Data("[1,2]".utf8), contentType: nil, limit: 100).isJSON)
        XCTAssertFalse(BodyData(data: Data("{not json".utf8), contentType: nil, limit: 100).isJSON)
        XCTAssertFalse(BodyData(data: Data("123".utf8), contentType: nil, limit: 100).isJSON)
        XCTAssertFalse(BodyData(data: Data("\"str\"".utf8), contentType: nil, limit: 100).isJSON)
        XCTAssertFalse(BodyData(data: Data(), contentType: nil, limit: 100).isJSON)
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8)
        XCTAssertTrue(BodyData(data: bom, contentType: nil, limit: 100).isJSON)
    }

    func testJSONSniffingIsBoundedToTwoMegabytes() {
        var big = Data("[".utf8)
        big.append(Data(repeating: UInt8(ascii: "1"), count: 2 * 1024 * 1024))
        big.append(Data("]".utf8))
        XCTAssertFalse(BodyData(data: big, contentType: nil, limit: .max).isJSON)
        XCTAssertTrue(BodyData(data: big, contentType: "application/json", limit: .max).isJSON)
    }

    func testPrettyJSONPreservesOrder() {
        let body = BodyData(data: Data(#"{"z":1,"a":{"y":true,"b":null}}"#.utf8), contentType: "application/json", limit: 1000)
        XCTAssertEqual(body.prettyJSON, "{\n  \"z\": 1,\n  \"a\": {\n    \"y\": true,\n    \"b\": null\n  }\n}")
        XCTAssertNil(BodyData(text: "plain").prettyJSON)
    }

    func testImageDetection() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])
        let gif = Data("GIF89a......".utf8)
        let webp = Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WEBPVP8 ".utf8)
        let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 8)
        for (name, data) in [("png", png), ("jpeg", jpeg), ("gif", gif), ("webp", webp), ("heic", heic)] {
            XCTAssertTrue(BodyData(data: data, contentType: nil, limit: 1000).isImage, name)
        }
        XCTAssertTrue(BodyData(data: Data("x".utf8), contentType: "image/svg+xml", limit: 10).isImage)
        XCTAssertFalse(BodyData(data: Data("hello world!".utf8), contentType: "text/plain", limit: 100).isImage)
        let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 8)
        XCTAssertFalse(BodyData(data: mp4, contentType: nil, limit: 100).isImage)
    }

    func testFormURLEncodedAndMimeType() {
        let body = BodyData(data: Data("a=1&b=2".utf8), contentType: "Application/X-WWW-Form-Urlencoded; charset=utf-8", limit: 100)
        XCTAssertTrue(body.isFormURLEncoded)
        XCTAssertEqual(body.mimeType, "application/x-www-form-urlencoded")
        XCTAssertFalse(BodyData(text: "x").isFormURLEncoded)
        XCTAssertNil(BodyData(data: Data(), contentType: nil, limit: 1).mimeType)
    }

    func testCodableRoundTrip() throws {
        let body = BodyData(data: Data([0, 1, 2, 3, 4]), contentType: "application/octet-stream", limit: 3)
        let decoded = try JSONDecoder().decode(BodyData.self, from: JSONEncoder().encode(body))
        XCTAssertEqual(decoded, body)
    }
}

final class SnapshotTests: XCTestCase {
    func testRequestURLComponents() {
        let request = RequestSnapshot(url: "https://user:pw@API.Example.com:8443/v1/caf%C3%A9/items?id=42&q=a%20b&flag#frag")
        XCTAssertEqual(request.host, "API.Example.com")
        XCTAssertEqual(request.path, "/v1/café/items")
        XCTAssertEqual(request.queryItems.map(\.name), ["id", "q", "flag"])
        XCTAssertEqual(request.queryItems.map(\.value), ["42", "a b", nil])
        XCTAssertEqual(request.method, "GET")
    }

    func testRequestPathFallbacks() {
        XCTAssertEqual(RequestSnapshot(url: "https://example.com").path, "/")
        XCTAssertEqual(RequestSnapshot(url: "https://example.com?x=1").path, "/")
        XCTAssertEqual(RequestSnapshot(url: "http://[::1]:8080/status").host, "::1")
        XCTAssertEqual(RequestSnapshot(url: "http://[::1]:8080/status").path, "/status")
        XCTAssertEqual(RequestSnapshot(url: "grpc://grpc/pkg.Svc/Method").host, "grpc")
        XCTAssertNil(RequestSnapshot(url: "about:blank").host)
        XCTAssertEqual(RequestSnapshot(url: "about:blank").path, "about:blank")
        XCTAssertEqual(RequestSnapshot(url: "https://exa mple.com/a b?x=1 2").host, "exa mple.com")
    }

    func testHeaderLookupIsCaseInsensitive() {
        let request = RequestSnapshot(url: "https://a.b", headers: [HTTPHeader(name: "Content-Type", value: "application/json")])
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(request.header("CONTENT-TYPE"), "application/json")
        XCTAssertNil(request.header("accept"))
        let response = ResponseSnapshot(statusCode: 200, headers: [HTTPHeader(name: "x-trace-id", value: "1")])
        XCTAssertEqual(response.header("X-Trace-ID"), "1")
        XCTAssertEqual(response.reasonPhrase, "OK")
        XCTAssertEqual(ResponseSnapshot.reasonPhrase(for: 404), "Not Found")
        XCTAssertEqual(ResponseSnapshot.reasonPhrase(for: 799), "")
    }

    func testHeaderListFromDictionaries() {
        let headers = HTTPHeader.list(from: ["b": "2", "A": "1"] as [String: String])
        XCTAssertEqual(headers, [HTTPHeader(name: "A", value: "1"), HTTPHeader(name: "b", value: "2")])
        let any: [AnyHashable: Any] = ["Content-Length": 12, "Server": "nginx"]
        XCTAssertEqual(HTTPHeader.list(from: any), [HTTPHeader(name: "Content-Length", value: "12"), HTTPHeader(name: "Server", value: "nginx")])
        XCTAssertEqual(HTTPHeader.list(from: nil as [String: String]?), [])
    }

    func testTimingDuration() {
        let start = Date()
        XCTAssertNil(NetworkTiming(startedAt: start).duration)
        XCTAssertEqual(NetworkTiming(startedAt: start, endedAt: start.addingTimeInterval(1.5)).duration ?? 0, 1.5, accuracy: 0.0001)
    }

    func testErrorInfoFromNSError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Timed out"])
        let info = NetworkErrorInfo(error)
        XCTAssertEqual(info, NetworkErrorInfo(domain: NSURLErrorDomain, code: -1001, message: "Timed out"))
    }

    func testOriginIsModified() {
        XCTAssertFalse(NetworkOrigin.network.isModified)
        XCTAssertTrue(NetworkOrigin.mocked(rule: "m").isModified)
        XCTAssertTrue(NetworkOrigin.rewritten(rule: "r").isModified)
        XCTAssertTrue(NetworkOrigin.breakpoint(edited: false).isModified)
    }

    func testEditablePayloadsRoundTripBodies() {
        let textRequest = EditableRequest(snapshot: RequestSnapshot(url: "https://a.b", method: "POST", body: BodyData(text: "{\"a\":1}")))
        XCTAssertFalse(textRequest.bodyIsBinary)
        XCTAssertEqual(textRequest.body, "{\"a\":1}")
        XCTAssertEqual(textRequest.bodyData, Data("{\"a\":1}".utf8))
        let binary = Data([0xFF, 0x00, 0x10])
        let binaryResponse = EditableResponse(snapshot: ResponseSnapshot(statusCode: 201, body: BodyData(data: binary, contentType: nil, limit: 10)))
        XCTAssertTrue(binaryResponse.bodyIsBinary)
        XCTAssertEqual(binaryResponse.body, binary.base64EncodedString())
        XCTAssertEqual(binaryResponse.bodyData, binary)
        XCTAssertEqual(binaryResponse.statusCode, 201)
        XCTAssertEqual(EditableRequest(snapshot: RequestSnapshot(url: "https://a.b")).body, "")
    }

    func testEntryCodableRoundTrip() throws {
        var entry = grpcEntry(messages: [GRPCMessage(direction: .sent, typeName: "Req", size: 3, json: "{}")])
        entry.origin = .rewritten(rule: "Rule")
        entry.web = WebViewDetails(pageURL: "https://page", initiator: .fetch, captureLevel: .full, webViewID: "1")
        let decoded = try JSONDecoder().decode(NetworkEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
    }
}

final class NetworkEntryTests: XCTestCase {
    func testHTTPLabelsAndCategories() {
        XCTAssertEqual(httpEntry(state: .pending, status: nil).statusLabel, "…")
        XCTAssertEqual(httpEntry(state: .pending, status: nil).statusCategory, .pending)
        XCTAssertEqual(httpEntry(state: .paused, status: nil).statusCategory, .pending)
        XCTAssertEqual(httpEntry(status: 200).statusLabel, "200")
        XCTAssertEqual(httpEntry(status: 204).statusCategory, .success)
        XCTAssertEqual(httpEntry(status: 301).statusCategory, .redirect)
        XCTAssertEqual(httpEntry(status: 404).statusCategory, .clientError)
        XCTAssertEqual(httpEntry(status: 503).statusCategory, .serverError)
        XCTAssertEqual(httpEntry(status: 503).statusLabel, "503")
    }

    func testHTTPStreamingWithFinalResponseUsesStatus() {
        let streaming = httpEntry(state: .streaming, status: 200)
        XCTAssertEqual(streaming.statusCategory, .success)
        XCTAssertEqual(streaming.statusLabel, "200")
        let informational = httpEntry(state: .pending, status: 101)
        XCTAssertEqual(informational.statusCategory, .pending)
        XCTAssertEqual(informational.statusLabel, "…")
    }

    func testHTTPFailures() {
        let error = NetworkErrorInfo(domain: NSURLErrorDomain, code: -1009, message: "Offline")
        let failed = httpEntry(state: .failed, status: nil, error: error)
        XCTAssertEqual(failed.statusLabel, "ERR")
        XCTAssertEqual(failed.statusCategory, .failure)
        let cancelled = httpEntry(state: .cancelled, status: nil)
        XCTAssertEqual(cancelled.statusLabel, "ERR")
        XCTAssertEqual(cancelled.statusCategory, .failure)
        let failedAfterResponse = httpEntry(state: .failed, status: 500, error: error)
        XCTAssertEqual(failedAfterResponse.statusCategory, .serverError)
    }

    func testHTTPMethodTitleHostSizes() {
        let entry = httpEntry(
            url: "https://api.example.com/v1/users?id=1",
            method: "post",
            body: BodyData(text: "12345"),
            responseBody: BodyData(data: Data(count: 100), contentType: nil, limit: 10)
        )
        XCTAssertEqual(entry.methodLabel, "POST")
        XCTAssertEqual(entry.title, "/v1/users")
        XCTAssertEqual(entry.path, "/v1/users")
        XCTAssertEqual(entry.host, "api.example.com")
        XCTAssertEqual(entry.requestSize, 5)
        XCTAssertEqual(entry.responseSize, 100)
        XCTAssertEqual(entry.duration ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(httpEntry(method: "").methodLabel, "GET")
    }

    func testWebViewUsesHTTPMethod() {
        var entry = httpEntry(method: "put")
        entry.kind = .webView
        entry.web = WebViewDetails(initiator: .xhr, captureLevel: .metadata)
        XCTAssertEqual(entry.methodLabel, "PUT")
        XCTAssertEqual(entry.statusCategory, .success)
    }

    func testGRPCLabels() {
        XCTAssertEqual(grpcEntry(callType: .unary).methodLabel, "UNARY")
        XCTAssertEqual(grpcEntry(callType: .clientStreaming).methodLabel, "CLIENT STREAM")
        XCTAssertEqual(grpcEntry(callType: .serverStreaming).methodLabel, "SERVER STREAM")
        XCTAssertEqual(grpcEntry(callType: .bidirectionalStreaming).methodLabel, "BIDI STREAM")
        let entry = grpcEntry()
        XCTAssertEqual(entry.title, "AccountService/GetAccount")
        XCTAssertEqual(entry.path, "/bank.v1.AccountService/GetAccount")
        XCTAssertEqual(entry.host, "api.example.com")
    }

    func testGRPCStatusCategories() {
        let pending = grpcEntry(state: .pending, statusCode: nil)
        XCTAssertEqual(pending.statusCategory, .pending)
        XCTAssertEqual(pending.statusLabel, "…")
        XCTAssertEqual(grpcEntry(state: .streaming, statusCode: nil).statusCategory, .pending)
        XCTAssertEqual(grpcEntry(statusCode: 0).statusCategory, .success)
        XCTAssertEqual(grpcEntry(statusCode: 0).statusLabel, "OK")
        for code in [3, 5, 6, 7, 9, 11, 16] {
            XCTAssertEqual(grpcEntry(statusCode: code).statusCategory, .clientError, "\(code)")
        }
        for code in [1, 2, 4, 8, 10, 12, 13, 14, 15, 42] {
            XCTAssertEqual(grpcEntry(statusCode: code).statusCategory, .serverError, "\(code)")
        }
        XCTAssertEqual(grpcEntry(statusCode: 14).statusLabel, "UNAVAILABLE")
        let failed = grpcEntry(state: .failed, statusCode: nil, error: NetworkErrorInfo(domain: "NIO", code: 1, message: "reset"))
        XCTAssertEqual(failed.statusCategory, .failure)
        XCTAssertEqual(failed.statusLabel, "ERR")
        let cancelled = grpcEntry(state: .cancelled, statusCode: nil)
        XCTAssertEqual(cancelled.statusCategory, .failure)
        XCTAssertEqual(cancelled.statusLabel, "CANCELLED")
    }

    func testGRPCStatusNames() {
        let expected = [
            "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
            "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
            "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED",
        ]
        for (code, name) in expected.enumerated() {
            XCTAssertEqual(GRPCDetails.statusName(for: code), name)
        }
        XCTAssertEqual(GRPCDetails.statusName(for: 17), "CODE 17")
        XCTAssertEqual(GRPCDetails.statusName(for: -1), "CODE -1")
        XCTAssertNil(grpcEntry(statusCode: nil).grpc?.statusName)
    }

    func testGRPCSizesCountAllMessagesEvenWhenCapped() {
        var details = GRPCDetails(path: "/a.B/C", callType: .serverStreaming)
        details.append(GRPCMessage(direction: .sent, typeName: "Req", size: 10))
        for _ in 0..<5 {
            details.append(GRPCMessage(direction: .received, typeName: "Res", size: 7), limit: 3)
        }
        XCTAssertEqual(details.messages.count, 3)
        XCTAssertEqual(details.receivedMessageCount, 5)
        XCTAssertEqual(details.sentMessageCount, 1)
        XCTAssertEqual(details.droppedMessageCount, 3)
        let entry = NetworkEntry(kind: .grpc, request: RequestSnapshot(url: "grpc://h/a.B/C"), grpc: details)
        XCTAssertEqual(entry.requestSize, 0 + 10)
        XCTAssertEqual(entry.responseSize, 35)
        let manual = NetworkEntry(
            kind: .grpc,
            request: RequestSnapshot(url: "grpc://h/a.B/C"),
            grpc: GRPCDetails(service: "a.B", method: "C", path: "/a.B/C", messages: [GRPCMessage(direction: .received, typeName: "R", size: 4)])
        )
        XCTAssertEqual(manual.responseSize, 4)
    }

    func testGRPCPathSplitting() {
        XCTAssertEqual(GRPCDetails.split(path: "/pkg.Svc/Method").service, "pkg.Svc")
        XCTAssertEqual(GRPCDetails.split(path: "/api/contents/pkg.Svc/Method").service, "pkg.Svc")
        XCTAssertEqual(GRPCDetails.split(path: "/api/contents/pkg.Svc/Method").method, "Method")
        XCTAssertEqual(GRPCDetails.split(path: "Method").method, "Method")
        XCTAssertEqual(GRPCDetails.split(path: "Method").service, "")
        XCTAssertEqual(GRPCDetails.split(path: "/").method, "")
    }
}

final class GRPCDetailsRingTests: XCTestCase {
    private func message(_ index: Int) -> GRPCMessage {
        GRPCMessage(direction: index % 2 == 0 ? .sent : .received, typeName: "M", size: 1, json: "{\"i\":\(index)}")
    }

    func testRingKeepsTheLastMessagesAcrossCompactions() {
        var details = GRPCDetails(path: "/pkg.S/M", callType: .bidirectionalStreaming)
        for index in 0..<5_000 {
            details.append(message(index), limit: 1_000)
            XCTAssertLessThanOrEqual(details.messageCount, 1_000)
        }
        XCTAssertEqual(details.messageCount, 1_000)
        XCTAssertEqual(details.messages.count, 1_000)
        XCTAssertEqual(details.messages.first?.json, "{\"i\":4000}")
        XCTAssertEqual(details.messages.last?.json, "{\"i\":4999}")
        XCTAssertEqual(details.droppedMessageCount, 4_000)
        XCTAssertEqual(details.storedMessageBytes, details.messages.reduce(0) { $0 + $1.storedByteCount })
        XCTAssertEqual(details.sentMessageCount + details.receivedMessageCount, 5_000)
    }

    func testEqualityAndCodableIgnoreInternalLayout() throws {
        var ring = GRPCDetails(path: "/pkg.S/M", callType: .serverStreaming)
        for index in 0..<10 {
            ring.append(message(index), limit: 4)
        }
        var flat = GRPCDetails(path: "/pkg.S/M", callType: .serverStreaming)
        for index in 0..<10 {
            flat.append(message(index), limit: 100)
        }
        XCTAssertNotEqual(ring, flat)
        let decoded = try JSONDecoder().decode(GRPCDetails.self, from: JSONEncoder().encode(ring))
        XCTAssertEqual(decoded, ring)
        XCTAssertEqual(decoded.messages.map(\.json), ["{\"i\":6}", "{\"i\":7}", "{\"i\":8}", "{\"i\":9}"])
        XCTAssertEqual(decoded.droppedMessageCount, 6)
        XCTAssertEqual(decoded.storedMessageBytes, ring.storedMessageBytes)
        var replaced = ring
        replaced.messages = Array(ring.messages.suffix(2))
        XCTAssertEqual(replaced.messageCount, 2)
        XCTAssertEqual(replaced.storedMessageBytes, replaced.messages.reduce(0) { $0 + $1.storedByteCount })
    }
}
