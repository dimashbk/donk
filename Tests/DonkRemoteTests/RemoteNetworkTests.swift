import DonkCore
import Foundation
import XCTest
@testable import DonkRemote

final class RemoteNetworkTests: XCTestCase {
    private func ids(_ result: JSONValue) -> [String] {
        (result["entries"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-000000000000", value))!
    }

    // MARK: - network.list

    func testListIsNewestFirstWithTotal() async throws {
        let fixture = RemoteFixture()
        for index in 1...5 {
            fixture.store.add(makeHTTPEntry(id: id(index)))
        }
        let result = try await call(fixture.handler, "network.list")
        XCTAssertEqual(result["total"]?.int, 5)
        XCTAssertEqual(ids(result), (1...5).reversed().map { id($0).uuidString })
        XCTAssertNil(result["nextBefore"])
    }

    func testLimitDefaultsAndClamps() async throws {
        let fixture = RemoteFixture()
        for index in 1...520 {
            fixture.store.add(makeHTTPEntry(id: id(index), url: "https://api.example.com/\(index)"))
        }
        let handler = fixture.handler
        let defaults = try await call(handler, "network.list")
        XCTAssertEqual(ids(defaults).count, 50)
        XCTAssertEqual(defaults["total"]?.int, 520)
        let tiny = try await call(handler, "network.list", #"{"limit":0}"#)
        XCTAssertEqual(ids(tiny), [id(520).uuidString])
        XCTAssertEqual(tiny["nextBefore"]?.string, id(520).uuidString)
        let huge = try await call(handler, "network.list", #"{"limit":100000}"#)
        XCTAssertEqual(ids(huge).count, 500)
        XCTAssertEqual(huge["total"]?.int, 520)
    }

    func testBeforeCursorPagesThroughOlderEntries() async throws {
        let fixture = RemoteFixture()
        for index in 1...5 {
            fixture.store.add(makeHTTPEntry(id: id(index)))
        }
        let handler = fixture.handler
        let first = try await call(handler, "network.list", #"{"limit":2}"#)
        XCTAssertEqual(ids(first), [id(5), id(4)].map(\.uuidString))
        let cursor = try XCTUnwrap(first["nextBefore"]?.string)
        XCTAssertEqual(cursor, id(4).uuidString)
        let second = try await call(handler, "network.list", #"{"limit":2,"before":"\#(cursor)"}"#)
        XCTAssertEqual(ids(second), [id(3), id(2)].map(\.uuidString))
        XCTAssertEqual(second["total"]?.int, 5)
        let prefix = String(try XCTUnwrap(second["nextBefore"]?.string).prefix(8)).lowercased()
        let third = try await call(handler, "network.list", #"{"limit":2,"before":"\#(prefix)"}"#)
        XCTAssertEqual(ids(third), [id(1).uuidString])
        XCTAssertNil(third["nextBefore"])
        let missing = await callError(handler, "network.list", #"{"before":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(missing?.code, -32000)
    }

    func testBeforeCursorSkipsFilteredEntries() async throws {
        let fixture = RemoteFixture()
        fixture.store.add(makeHTTPEntry(id: id(1), status: 500))
        fixture.store.add(makeHTTPEntry(id: id(2), status: 200))
        fixture.store.add(makeHTTPEntry(id: id(3), status: 503))
        fixture.store.add(makeHTTPEntry(id: id(4), status: 200))
        let result = try await call(fixture.handler, "network.list", #"{"status":["serverError"],"before":"\#(id(4).uuidString)"}"#)
        XCTAssertEqual(ids(result), [id(3), id(1)].map(\.uuidString))
        XCTAssertEqual(result["total"]?.int, 2)
    }

    func testFilterMapping() async throws {
        let fixture = RemoteFixture()
        fixture.settings.update { $0.hiddenHosts = ["a.example.com"] }
        fixture.store.add(makeHTTPEntry(id: id(1), url: "https://a.example.com/v1/accounts", status: 200))
        fixture.store.add(makeHTTPEntry(id: id(2), url: "https://b.example.com/v1/accounts", status: 500, isPinned: true))
        fixture.store.add(makeGRPCEntry(id: id(3), statusCode: 14))
        fixture.store.add(makeHTTPEntry(id: id(4), url: "https://web.example.com/page", kind: .webView))
        fixture.store.add(makeHTTPEntry(id: id(5), url: "https://a.example.com/v1/profile", origin: .mocked(rule: "Mock profile")))
        fixture.store.add(makeHTTPEntry(id: id(6), url: "https://a.example.com/v1/slow", state: .pending, status: nil, duration: nil))
        fixture.store.add(makeHTTPEntry(id: id(7), url: "https://a.example.com/v1/redirect", status: 302))
        fixture.store.add(makeHTTPEntry(id: id(8), url: "https://a.example.com/v1/missing", status: 404))
        fixture.store.add(makeHTTPEntry(
            id: id(9),
            url: "https://a.example.com/v1/offline",
            state: .failed,
            status: nil,
            error: NetworkErrorInfo(domain: NSURLErrorDomain, code: -1009, message: "The Internet connection appears to be offline.")
        ))
        let handler = fixture.handler

        let all = try await call(handler, "network.list")
        XCTAssertEqual(all["total"]?.int, 9)
        let grpc = try await call(handler, "network.list", #"{"kinds":["grpc"]}"#)
        XCTAssertEqual(ids(grpc), [id(3).uuidString])
        let mixed = try await call(handler, "network.list", #"{"kinds":["grpc","webView"]}"#)
        XCTAssertEqual(ids(mixed), [id(4), id(3)].map(\.uuidString))
        let hosts = try await call(handler, "network.list", #"{"hosts":["B.Example.com"]}"#)
        XCTAssertEqual(ids(hosts), [id(2).uuidString])
        let server = try await call(handler, "network.list", #"{"status":["serverError"]}"#)
        XCTAssertEqual(ids(server), [id(3), id(2)].map(\.uuidString))
        let categories = try await call(handler, "network.list", #"{"status":["pending","redirect","clientError","failure"]}"#)
        XCTAssertEqual(ids(categories), [id(9), id(8), id(7), id(6)].map(\.uuidString))
        let success = try await call(handler, "network.list", #"{"status":["success"],"kinds":["http"]}"#)
        XCTAssertEqual(ids(success), [id(5), id(1)].map(\.uuidString))
        let pinned = try await call(handler, "network.list", #"{"onlyPinned":true}"#)
        XCTAssertEqual(ids(pinned), [id(2).uuidString])
        let modified = try await call(handler, "network.list", #"{"onlyModified":true}"#)
        XCTAssertEqual(ids(modified), [id(5).uuidString])
        let query = try await call(handler, "network.list", #"{"query":"accounts 500"}"#)
        XCTAssertEqual(ids(query), [id(2).uuidString])
        let offline = try await call(handler, "network.list", #"{"query":"offline","kinds":["http"]}"#)
        XCTAssertEqual(ids(offline), [id(9).uuidString])
    }

    func testQuerySearchesRedactedEntries() async throws {
        var fixture = RemoteFixture()
        fixture.store.add(makeHTTPEntry(
            url: "https://api.example.com/v1/me?access_token=sekret42",
            headers: [HTTPHeader(name: "Authorization", value: "Bearer abc123xyz")],
            body: BodyData(text: #"{"password":"hunter2","user":"dina"}"#, contentType: "application/json")
        ))
        let redacted = try await call(fixture.handler, "network.list", #"{"query":"abc123xyz"}"#)
        XCTAssertEqual(redacted["total"]?.int, 0)
        let body = try await call(fixture.handler, "network.list", #"{"query":"hunter2"}"#)
        XCTAssertEqual(body["total"]?.int, 0)
        let query = try await call(fixture.handler, "network.list", #"{"query":"sekret42"}"#)
        XCTAssertEqual(query["total"]?.int, 0)
        let visible = try await call(fixture.handler, "network.list", #"{"query":"dina"}"#)
        XCTAssertEqual(visible["total"]?.int, 1)
        XCTAssertEqual(visible["entries"]?[0]?["url"]?.string, "https://api.example.com/v1/me?access_token=••••")
        fixture.redacts = false
        let raw = try await call(fixture.handler, "network.list", #"{"query":"abc123xyz"}"#)
        XCTAssertEqual(raw["total"]?.int, 1)
    }

    func testSummaryFields() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(
            id: entryID,
            url: "https://api.example.com/v1/accounts?token=abc&page=2",
            method: "post",
            body: BodyData(text: "{}", contentType: "application/json"),
            status: 503,
            responseBody: BodyData(text: "unavailable"),
            error: NetworkErrorInfo(domain: "test", code: 1, message: "connection reset"),
            origin: .rewritten(rule: "Slow down"),
            isPinned: true
        ))
        fixture.store.add(makeHTTPEntry(url: "https://api.example.com/v1/live", state: .pending, status: nil, duration: nil))
        let result = try await call(fixture.handler, "network.list")
        let live = try XCTUnwrap(result["entries"]?[0])
        XCTAssertNil(live["durationMs"])
        XCTAssertEqual(live["status"]?.string, "…")
        XCTAssertEqual(live["statusCategory"]?.string, "pending")
        XCTAssertEqual(live["state"]?.string, "pending")
        let summary = try XCTUnwrap(result["entries"]?[1])
        XCTAssertEqual(summary.keys, [
            "id", "kind", "state", "origin", "rule", "method", "title", "url", "host", "status", "statusCategory",
            "startedAt", "durationMs", "requestSize", "responseSize", "error", "pinned",
        ])
        XCTAssertEqual(summary["id"]?.string, entryID.uuidString)
        XCTAssertEqual(summary["kind"]?.string, "http")
        XCTAssertEqual(summary["state"]?.string, "completed")
        XCTAssertEqual(summary["origin"]?.string, "rewritten")
        XCTAssertEqual(summary["rule"]?.string, "Slow down")
        XCTAssertEqual(summary["method"]?.string, "POST")
        XCTAssertEqual(summary["title"]?.string, "/v1/accounts")
        XCTAssertEqual(summary["url"]?.string, "https://api.example.com/v1/accounts?token=••••&page=2")
        XCTAssertEqual(summary["host"]?.string, "api.example.com")
        XCTAssertEqual(summary["status"]?.string, "503")
        XCTAssertEqual(summary["statusCategory"]?.string, "serverError")
        XCTAssertEqual(summary["startedAt"]?.string, "2027-01-15T08:00:00.125Z")
        XCTAssertEqual(summary["durationMs"]?.double ?? 0, 341.2, accuracy: 0.001)
        XCTAssertEqual(summary["requestSize"]?.int, 2)
        XCTAssertEqual(summary["responseSize"]?.int, 11)
        XCTAssertEqual(summary["error"]?.string, "connection reset")
        XCTAssertEqual(summary["pinned"]?.bool, true)
    }

    func testOriginValues() async throws {
        let fixture = RemoteFixture()
        fixture.store.add(makeHTTPEntry(id: id(1)))
        fixture.store.add(makeHTTPEntry(id: id(2), origin: .mocked(rule: "Mock")))
        fixture.store.add(makeHTTPEntry(id: id(3), origin: .breakpoint(edited: true)))
        let result = try await call(fixture.handler, "network.list")
        let origins = (result["entries"]?.array ?? []).map { [$0["origin"]?.string ?? "", $0["rule"]?.string ?? "-"] }
        XCTAssertEqual(origins, [["breakpoint", "-"], ["mocked", "Mock"], ["network", "-"]])
    }

    func testGRPCSummary() async throws {
        let fixture = RemoteFixture()
        fixture.store.add(makeGRPCEntry(
            statusCode: 14,
            statusMessage: "connection reset",
            messages: [
                GRPCMessage(direction: .sent, typeName: "bank.v1.GetAccountRequest", size: 12, json: #"{"id":"1"}"#),
                GRPCMessage(direction: .received, typeName: "bank.v1.Account", size: 40, json: #"{"balance":1}"#),
            ]
        ))
        let result = try await call(fixture.handler, "network.list")
        let summary = try XCTUnwrap(result["entries"]?[0])
        XCTAssertEqual(summary["kind"]?.string, "grpc")
        XCTAssertEqual(summary["method"]?.string, "UNARY")
        XCTAssertEqual(summary["title"]?.string, "AccountService/GetAccount")
        XCTAssertEqual(summary["url"]?.string, "grpc://api.example.com/bank.v1.AccountService/GetAccount")
        XCTAssertEqual(summary["status"]?.string, "UNAVAILABLE")
        XCTAssertEqual(summary["statusCategory"]?.string, "serverError")
        XCTAssertEqual(summary["requestSize"]?.int, 12)
        XCTAssertEqual(summary["responseSize"]?.int, 40)
        let grpc = try XCTUnwrap(summary["grpc"])
        XCTAssertEqual(grpc.keys, ["service", "method", "statusCode", "statusName", "statusMessage", "messages"])
        XCTAssertEqual(grpc["service"]?.string, "bank.v1.AccountService")
        XCTAssertEqual(grpc["method"]?.string, "GetAccount")
        XCTAssertEqual(grpc["statusCode"]?.int, 14)
        XCTAssertEqual(grpc["statusName"]?.string, "UNAVAILABLE")
        XCTAssertEqual(grpc["statusMessage"]?.string, "connection reset")
        XCTAssertEqual(grpc["messages"]?.int, 2)
    }

    // MARK: - network.get

    func testHTTPDetail() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let metrics = TransactionMetrics(networkProtocol: "h2", remoteAddress: "1.2.3.4", isReusedConnection: true)
        var entry = makeHTTPEntry(
            id: entryID,
            url: "https://api.example.com/v1/login?otp=123456",
            method: "POST",
            headers: [HTTPHeader(name: "Authorization", value: "Bearer abc123xyz"), HTTPHeader(name: "Accept", value: "application/json")],
            body: BodyData(text: #"{"user":"dina","password":"hunter2"}"#, contentType: "application/json"),
            responseHeaders: [HTTPHeader(name: "Set-Cookie", value: "session=s3cr3t"), HTTPHeader(name: "Content-Type", value: "application/json")],
            responseBody: BodyData(text: #"{"token":"tkn-999","name":"Dina"}"#, contentType: "application/json"),
            transactions: [TransactionMetrics(networkProtocol: "http/1.1"), metrics]
        )
        entry.timing.responseStartedAt = entry.timing.startedAt.addingTimeInterval(0.2)
        fixture.store.add(entry)
        let result = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString.lowercased())"}"#)
        let detail = try XCTUnwrap(result["entry"])
        XCTAssertEqual(detail["id"]?.string, entryID.uuidString)
        XCTAssertEqual(detail["url"]?.string, "https://api.example.com/v1/login?otp=••••")

        let request = try XCTUnwrap(detail["request"])
        XCTAssertEqual(request["url"]?.string, "https://api.example.com/v1/login?otp=••••")
        XCTAssertEqual(request["method"]?.string, "POST")
        XCTAssertEqual(request["headers"], .array([
            .object([JSONMember(key: "name", value: .string("Authorization")), JSONMember(key: "value", value: .string("••••"))]),
            .object([JSONMember(key: "name", value: .string("Accept")), JSONMember(key: "value", value: .string("application/json"))]),
        ]))
        let requestBody = try XCTUnwrap(request["body"])
        XCTAssertEqual(requestBody.keys, ["contentType", "size", "truncated", "encoding", "text"])
        XCTAssertEqual(requestBody["contentType"]?.string, "application/json")
        XCTAssertEqual(requestBody["encoding"]?.string, "text")
        XCTAssertEqual(requestBody["truncated"]?.bool, false)
        XCTAssertEqual(requestBody["size"]?.int, 36)
        let requestText = try XCTUnwrap(requestBody["text"]?.string)
        XCTAssertTrue(requestText.contains("\n"))
        XCTAssertTrue(requestText.contains(#""password": "••••""#))
        XCTAssertFalse(requestText.contains("hunter2"))

        let response = try XCTUnwrap(detail["response"])
        XCTAssertEqual(response["statusCode"]?.int, 200)
        XCTAssertEqual(response["headers"]?[0]?["value"]?.string, "••••")
        let responseText = try XCTUnwrap(response["body"]?["text"]?.string)
        XCTAssertFalse(responseText.contains("tkn-999"))
        XCTAssertTrue(responseText.contains("Dina"))

        let timing = try XCTUnwrap(detail["timing"])
        XCTAssertEqual(timing.keys, ["startedAt", "responseStartedAt", "endedAt", "durationMs", "protocol", "remoteAddress", "reusedConnection"])
        XCTAssertEqual(timing["startedAt"]?.string, "2027-01-15T08:00:00.125Z")
        XCTAssertEqual(timing["protocol"]?.string, "h2")
        XCTAssertEqual(timing["remoteAddress"]?.string, "1.2.3.4")
        XCTAssertEqual(timing["reusedConnection"]?.bool, true)

        let curl = try XCTUnwrap(detail["curl"]?.string)
        XCTAssertTrue(curl.hasPrefix("curl -X POST"))
        XCTAssertTrue(curl.contains("Authorization: ••••"))
        XCTAssertFalse(curl.contains("abc123xyz"))
        XCTAssertFalse(curl.contains("hunter2"))
        XCTAssertFalse(curl.contains("123456"))
        XCTAssertNil(detail["grpcurl"])
        XCTAssertNil(detail["grpc"])
        XCTAssertNil(detail["web"])
        XCTAssertNil(detail["errorInfo"])
    }

    func testDetailWithoutResponseOrMetrics() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(
            id: entryID,
            url: "https://web.example.com/api",
            state: .failed,
            status: nil,
            error: NetworkErrorInfo(domain: NSURLErrorDomain, code: -1005, message: "The network connection was lost."),
            kind: .webView
        ))
        let response = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        let detail = try XCTUnwrap(response["entry"])
        XCTAssertNil(detail["response"])
        XCTAssertNil(detail["request"]?["body"])
        XCTAssertEqual(detail["errorInfo"]?.keys, ["domain", "code", "message"])
        XCTAssertEqual(detail["errorInfo"]?["code"]?.int, -1005)
        XCTAssertEqual(detail["timing"]?.keys, ["startedAt", "endedAt", "durationMs"])
        XCTAssertEqual(detail["web"]?["pageURL"]?.string, "https://web.example.com/page?token=••••")
        XCTAssertEqual(detail["web"]?["initiator"]?.string, "fetch")
        XCTAssertEqual(detail["web"]?["captureLevel"]?.string, "full")
        XCTAssertNotNil(detail["curl"])
    }

    func testBodyIsCutOnScalarBoundary() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let text = "a" + String(repeating: "😀", count: 1000)
        fixture.store.add(makeHTTPEntry(id: entryID, responseBody: BodyData(text: text)))
        let handler = fixture.handler
        let small = try await call(handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxBodyBytes":10}"#)
        let body = try XCTUnwrap(small["entry"]?["response"]?["body"])
        let cut = try XCTUnwrap(body["text"]?.string)
        XCTAssertEqual(cut.utf8.count, 1021)
        XCTAssertEqual(cut, "a" + String(repeating: "😀", count: 255))
        XCTAssertEqual(body["truncated"]?.bool, true)
        XCTAssertEqual(body["size"]?.int, 4001)
        let full = try await call(handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        XCTAssertEqual(full["entry"]?["response"]?["body"]?["text"]?.string, text)
        XCTAssertEqual(full["entry"]?["response"]?["body"]?["truncated"]?.bool, false)
    }

    func testMaxBodyBytesUpperClamp() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let text = String(repeating: "x", count: 1024 * 1024 + 500)
        fixture.store.add(makeHTTPEntry(id: entryID, responseBody: BodyData(text: text)))
        let result = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxBodyBytes":99999999}"#)
        XCTAssertEqual(result["entry"]?["response"]?["body"]?["text"]?.string?.utf8.count, 1024 * 1024)
    }

    func testCaptureTruncationAndBinaryBodies() async throws {
        let fixture = RemoteFixture()
        let truncatedID = UUID()
        let imageID = UUID()
        let binaryID = UUID()
        fixture.store.add(makeHTTPEntry(id: truncatedID, responseBody: BodyData(data: Data(String(repeating: "y", count: 500).utf8), contentType: "text/plain", limit: 100)))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        fixture.store.add(makeHTTPEntry(id: imageID, responseBody: BodyData(data: png, contentType: "image/png", limit: .max)))
        fixture.store.add(makeHTTPEntry(id: binaryID, responseBody: BodyData(data: Data([0xFF, 0xFE, 0x00, 0xC3]), contentType: "application/octet-stream", limit: .max)))
        let handler = fixture.handler

        let truncated = try await call(handler, "network.get", #"{"id":"\#(truncatedID.uuidString)"}"#)
        let truncatedBody = try XCTUnwrap(truncated["entry"]?["response"]?["body"])
        XCTAssertEqual(truncatedBody["truncated"]?.bool, true)
        XCTAssertEqual(truncatedBody["size"]?.int, 500)
        XCTAssertEqual(truncatedBody["text"]?.string?.count, 100)

        let image = try await call(handler, "network.get", #"{"id":"\#(imageID.uuidString)"}"#)
        let imageBody = try XCTUnwrap(image["entry"]?["response"]?["body"])
        XCTAssertEqual(imageBody["encoding"]?.string, "binary")
        XCTAssertNil(imageBody["text"])
        XCTAssertEqual(imageBody["image"]?.bool, true)
        XCTAssertEqual(imageBody["size"]?.int, 12)

        let binary = try await call(handler, "network.get", #"{"id":"\#(binaryID.uuidString)"}"#)
        let binaryBody = try XCTUnwrap(binary["entry"]?["response"]?["body"])
        XCTAssertEqual(binaryBody["encoding"]?.string, "binary")
        XCTAssertNil(binaryBody["text"])
        XCTAssertNil(binaryBody["image"])
    }

    func testGRPCDetail() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var messages = [GRPCMessage(direction: .sent, timestamp: start, typeName: "bank.v1.WatchRequest", size: 12, json: #"{"token":"t-1","account":"A"}"#)]
        for index in 1...4 {
            messages.append(GRPCMessage(
                direction: .received,
                timestamp: start.addingTimeInterval(Double(index)),
                typeName: "bank.v1.Event\(index)",
                size: 10 * index,
                json: index == 3 ? nil : #"{"seq":\#(index),"secret":"s-\#(index)"}"#,
                textFormat: index == 3 ? "seq: 3\npin: \"0000\"" : nil,
                raw: Data([0x08, 0x03])
            ))
        }
        fixture.store.add(makeGRPCEntry(
            id: entryID,
            path: "/bank.v1.AccountService/Watch",
            callType: .serverStreaming,
            statusCode: 0,
            metadata: [HTTPHeader(name: "authorization", value: "Bearer grpc-secret"), HTTPHeader(name: "x-request-id", value: "r-1")],
            messages: messages,
            timeout: 30
        ))
        let handler = fixture.handler
        let result = try await call(handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxMessages":2}"#)
        let detail = try XCTUnwrap(result["entry"])
        XCTAssertEqual(detail["method"]?.string, "SERVER STREAM")
        let grpc = try XCTUnwrap(detail["grpc"])
        XCTAssertEqual(grpc.keys, [
            "service", "method", "statusCode", "statusName", "path", "callType", "timeoutSec", "requestMetadata",
            "responseHeaders", "trailers", "sentMessageCount", "receivedMessageCount", "droppedMessageCount", "messages",
        ])
        XCTAssertEqual(grpc["path"]?.string, "/bank.v1.AccountService/Watch")
        XCTAssertEqual(grpc["callType"]?.string, "serverStreaming")
        XCTAssertEqual(grpc["timeoutSec"]?.int, 30)
        XCTAssertEqual(grpc["statusName"]?.string, "OK")
        XCTAssertEqual(grpc["requestMetadata"]?[0]?["value"]?.string, "••••")
        XCTAssertEqual(grpc["requestMetadata"]?[1]?["value"]?.string, "r-1")
        XCTAssertEqual(grpc["sentMessageCount"]?.int, 1)
        XCTAssertEqual(grpc["receivedMessageCount"]?.int, 4)
        XCTAssertEqual(grpc["droppedMessageCount"]?.int, 0)
        let kept = try XCTUnwrap(grpc["messages"]?.array)
        XCTAssertEqual(kept.compactMap { $0["typeName"]?.string }, ["bank.v1.Event3", "bank.v1.Event4"])
        XCTAssertEqual(kept[0].keys, ["direction", "timestamp", "typeName", "size", "textFormat"])
        XCTAssertEqual(kept[0]["textFormat"]?.string, "seq: 3\npin: \"••••\"")
        XCTAssertEqual(kept[1].keys, ["direction", "timestamp", "typeName", "size", "json"])
        XCTAssertEqual(kept[1]["direction"]?.string, "received")
        XCTAssertEqual(kept[1]["timestamp"]?.string, "2027-01-15T08:00:04.000Z")
        XCTAssertEqual(kept[1]["size"]?.int, 40)
        XCTAssertEqual(kept[1]["json"]?.string, #"{"seq":4,"secret":"••••"}"#)
        let grpcurl = try XCTUnwrap(detail["grpcurl"]?.string)
        XCTAssertTrue(grpcurl.hasPrefix("grpcurl"))
        XCTAssertTrue(grpcurl.contains("authorization: ••••"))
        XCTAssertFalse(grpcurl.contains("grpc-secret"))
        XCTAssertFalse(grpcurl.contains("t-1"))
        XCTAssertTrue(grpcurl.contains("bank.v1.AccountService/Watch"))
        XCTAssertNil(detail["curl"])
        XCTAssertFalse(detail.compact().contains("CAM="))

        let none = try await call(handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxMessages":0}"#)
        XCTAssertEqual(none["entry"]?["grpc"]?["messages"]?.array?.count, 0)
        let defaults = try await call(handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        XCTAssertEqual(defaults["entry"]?["grpc"]?["messages"]?.array?.count, 5)
    }

    func testGRPCMessageTextIsCut() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let long = #"{"blob":""# + String(repeating: "ж", count: 2000) + #""}"#
        fixture.store.add(makeGRPCEntry(id: entryID, messages: [GRPCMessage(direction: .received, typeName: "Blob", size: 4000, json: long)]))
        let result = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxBodyBytes":1024}"#)
        let message = try XCTUnwrap(result["entry"]?["grpc"]?["messages"]?[0])
        let json = try XCTUnwrap(message["json"]?.string)
        XCTAssertLessThanOrEqual(json.utf8.count, 1024)
        XCTAssertFalse(json.contains("\u{FFFD}"))
        XCTAssertEqual(message["truncated"]?.bool, true)
    }

    func testMaxMessagesClamp() async throws {
        let fixture = RemoteFixture()
        let entryID = UUID()
        let messages = (0..<1200).map { GRPCMessage(direction: .received, typeName: "M\($0)", size: 1, json: "{}") }
        fixture.store.add(makeGRPCEntry(id: entryID, callType: .serverStreaming, messages: messages))
        let result = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)","maxMessages":5000,"maxBodyBytes":1024}"#)
        let grpc = try XCTUnwrap(result["entry"]?["grpc"])
        XCTAssertEqual(grpc["messages"]?.array?.count, 1000)
        XCTAssertEqual(grpc["messages"]?.array?.last?["typeName"]?.string, "M1199")
        XCTAssertEqual(grpc["droppedMessageCount"]?.int, 200)
        XCTAssertEqual(grpc["receivedMessageCount"]?.int, 1200)
    }

    // MARK: - Redaction policy

    func testRemotePolicyOverridesSettingsPolicy() async throws {
        var fixture = RemoteFixture()
        fixture.redaction = RedactionPolicy(headers: ["x-custom"], keys: [])
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(id: entryID, headers: [
            HTTPHeader(name: "X-Custom", value: "hidden"),
            HTTPHeader(name: "Authorization", value: "Bearer shown"),
        ]))
        let response = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        let detail = try XCTUnwrap(response["entry"])
        XCTAssertEqual(detail["request"]?["headers"]?[0]?["value"]?.string, "••••")
        XCTAssertEqual(detail["request"]?["headers"]?[1]?["value"]?.string, "Bearer shown")
    }

    func testSettingsPolicyAppliesEvenWhenExportsAreNotRedacted() async throws {
        let fixture = RemoteFixture()
        fixture.settings.update { settings in
            settings.redactsExports = false
            settings.redaction = RedactionPolicy(headers: ["x-session"], keys: ["iban"], replacement: "<hidden>")
        }
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(
            id: entryID,
            headers: [HTTPHeader(name: "X-Session", value: "s-1")],
            body: BodyData(text: #"{"iban":"KZ00","password":"visible"}"#, contentType: "application/json")
        ))
        let response = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        let detail = try XCTUnwrap(response["entry"])
        XCTAssertEqual(detail["request"]?["headers"]?[0]?["value"]?.string, "<hidden>")
        let text = try XCTUnwrap(detail["request"]?["body"]?["text"]?.string)
        XCTAssertTrue(text.contains("<hidden>"))
        XCTAssertFalse(text.contains("KZ00"))
        XCTAssertTrue(text.contains("visible"))
        XCTAssertTrue(try XCTUnwrap(detail["curl"]?.string).contains("X-Session: <hidden>"))
    }

    func testRedactionCanBeTurnedOff() async throws {
        var fixture = RemoteFixture()
        fixture.redacts = false
        let entryID = UUID()
        fixture.store.add(makeHTTPEntry(id: entryID, url: "https://api.example.com/?token=raw", headers: [HTTPHeader(name: "Authorization", value: "Bearer raw")]))
        let response = try await call(fixture.handler, "network.get", #"{"id":"\#(entryID.uuidString)"}"#)
        let detail = try XCTUnwrap(response["entry"])
        XCTAssertEqual(detail["url"]?.string, "https://api.example.com/?token=raw")
        XCTAssertEqual(detail["request"]?["headers"]?[0]?["value"]?.string, "Bearer raw")
        XCTAssertTrue(try XCTUnwrap(detail["curl"]?.string).contains("Bearer raw"))
    }

    // MARK: - Ids

    func testIDPrefixResolution() async throws {
        let fixture = RemoteFixture()
        let first = UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "ABCDEF12-1111-4000-8000-000000000002")!
        fixture.store.add(makeHTTPEntry(id: first))
        fixture.store.add(makeHTTPEntry(id: second))
        let handler = fixture.handler

        let ambiguous = await callError(handler, "network.get", #"{"id":"abcdef12"}"#)
        XCTAssertEqual(ambiguous?.code, -32002)
        let unique = try await call(handler, "network.get", #"{"id":"abcdef12-1"}"#)
        XCTAssertEqual(unique["entry"]?["id"]?.string, second.uuidString)
        let compact = try await call(handler, "network.get", #"{"id":"ABCDEF120000"}"#)
        XCTAssertEqual(compact["entry"]?["id"]?.string, first.uuidString)
        let full = try await call(handler, "network.get", #"{"id":"\#(first.uuidString.lowercased())"}"#)
        XCTAssertEqual(full["entry"]?["id"]?.string, first.uuidString)
        let short = await callError(handler, "network.get", #"{"id":"abcdef1"}"#)
        XCTAssertEqual(short?.code, -32602)
        let missing = await callError(handler, "network.get", #"{"id":"99999999"}"#)
        XCTAssertEqual(missing?.code, -32000)
        let unknownFull = await callError(handler, "network.get", #"{"id":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(unknownFull?.code, -32000)
        let garbage = await callError(handler, "network.get", #"{"id":"not-an-id-at-all"}"#)
        XCTAssertEqual(garbage?.code, -32602)
    }
}
