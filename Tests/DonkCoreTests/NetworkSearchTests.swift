import XCTest
@testable import DonkCore

final class NetworkSearchTests: XCTestCase {
    private lazy var users = httpEntry(
        url: "https://api.example.com/v1/users?id=42",
        headers: [HTTPHeader(name: "X-Trace", value: "abc123")],
        status: 200,
        responseHeaders: [HTTPHeader(name: "Content-Type", value: "application/json")],
        responseBody: BodyData(data: Data(#"{"name":"Alice","city":"Алматы"}"#.utf8), contentType: "application/json", limit: 1024)
    )
    private lazy var upload = httpEntry(
        url: "https://cdn.other.net/upload",
        method: "POST",
        body: BodyData(text: "file=report.pdf"),
        status: 500,
        origin: .mocked(rule: "Fail upload"),
        isPinned: true
    )
    private lazy var account = grpcEntry(
        path: "/bank.v1.AccountService/GetAccount",
        host: "grpc.example.com",
        statusCode: 14,
        statusMessage: "backend down",
        metadata: [HTTPHeader(name: "authorization", value: "Bearer token-xyz")],
        messages: [
            GRPCMessage(direction: .sent, typeName: "bank.v1.GetAccountRequest", size: 20, json: #"{"accountId":"ACC-777"}"#),
            GRPCMessage(direction: .received, typeName: "bank.v1.Account", size: 30, json: #"{"balance":"1000"}"#),
        ]
    )
    private lazy var failed = httpEntry(
        url: "https://offline.test/ping",
        state: .failed,
        status: nil,
        error: NetworkErrorInfo(domain: NSURLErrorDomain, code: -1009, message: "The Internet connection appears to be offline.")
    )

    private var all: [NetworkEntry] { [users, upload, account, failed] }

    private func ids(_ entries: [NetworkEntry]) -> [UUID] { entries.map(\.id) }

    private func search(_ query: String) -> [UUID] {
        var filter = NetworkFilter()
        filter.query = query
        return ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(search(""), ids(all))
        XCTAssertEqual(search("   "), ids(all))
        XCTAssertTrue(NetworkSearch.matches(users, query: ""))
        XCTAssertTrue(NetworkFilter().isEmpty)
    }

    func testURLMethodAndStatus() {
        XCTAssertEqual(search("users"), [users.id])
        XCTAssertEqual(search("post"), [upload.id, account.id])
        XCTAssertEqual(search("500"), [upload.id])
        XCTAssertEqual(search("unavailable"), [account.id])
        XCTAssertEqual(search("unary"), [account.id])
        XCTAssertEqual(search("ERR"), [failed.id])
    }

    func testMultipleTermsAreAnded() {
        XCTAssertEqual(search("alice users"), [users.id])
        XCTAssertEqual(search("ALICE   v1 json"), [users.id])
        XCTAssertEqual(search("alice upload"), [])
    }

    func testHeaderNamesAndValues() {
        XCTAssertEqual(search("abc123"), [users.id])
        XCTAssertEqual(search("x-trace"), [users.id])
        XCTAssertEqual(search("token-XYZ"), [account.id])
    }

    func testBodiesAreSearchedCaseInsensitively() {
        XCTAssertEqual(search("aLiCe"), [users.id])
        XCTAssertEqual(search("report.pdf"), [upload.id])
        XCTAssertEqual(search("алматы"), [users.id])
        XCTAssertEqual(search("АЛМАТЫ"), [users.id])
    }

    func testGRPCMessagesStatusAndError() {
        XCTAssertEqual(search("acc-777"), [account.id])
        XCTAssertEqual(search("balance"), [account.id])
        XCTAssertEqual(search("GetAccountRequest"), [account.id])
        XCTAssertEqual(search("backend down"), [account.id])
        XCTAssertEqual(search("offline"), [failed.id])
        XCTAssertEqual(search("-1009"), [failed.id])
    }

    func testHiddenHostsAreExcluded() {
        let visible = NetworkSearch.apply(NetworkFilter(), hiddenHosts: ["*.example.com"], to: all)
        XCTAssertEqual(ids(visible), [upload.id, failed.id])
        XCTAssertEqual(ids(NetworkSearch.apply(NetworkFilter(), hiddenHosts: ["", " "], to: all)), ids(all))
    }

    func testStructuredFilters() {
        var filter = NetworkFilter()
        filter.kinds = [.grpc]
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [account.id])

        filter = NetworkFilter()
        filter.statusCategories = [.serverError]
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [upload.id, account.id])

        filter.statusCategories = [.failure, .success]
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [users.id, failed.id])

        filter = NetworkFilter()
        filter.onlyPinned = true
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [upload.id])

        filter = NetworkFilter()
        filter.onlyModified = true
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [upload.id])

        filter = NetworkFilter()
        filter.hosts = ["API.example.com", "offline.test"]
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [users.id, failed.id])
        XCTAssertFalse(filter.isEmpty)

        filter.query = "ping"
        XCTAssertEqual(ids(NetworkSearch.apply(filter, hiddenHosts: [], to: all)), [failed.id])
    }

    func testBodySearchIsLimitedToFirst256KB() {
        var payload = Data(repeating: UInt8(ascii: "a"), count: 300 * 1024)
        payload.append(Data("needle".utf8))
        var early = Data("early-needle ".utf8)
        early.append(Data(repeating: UInt8(ascii: "b"), count: 300 * 1024))
        let late = httpEntry(responseBody: BodyData(data: payload, contentType: "text/plain", limit: .max))
        let found = httpEntry(responseBody: BodyData(data: early, contentType: "text/plain", limit: .max))
        XCTAssertFalse(NetworkSearch.matches(late, query: "needle"))
        XCTAssertTrue(NetworkSearch.matches(found, query: "EARLY-NEEDLE"))
        var boundary = Data(repeating: UInt8(ascii: "c"), count: 256 * 1024 - 6)
        boundary.append(Data("needle".utf8))
        XCTAssertTrue(NetworkSearch.matches(httpEntry(responseBody: BodyData(data: boundary, contentType: nil, limit: .max)), query: "needle"))
        var past = Data(repeating: UInt8(ascii: "c"), count: 256 * 1024 - 5)
        past.append(Data("needle".utf8))
        XCTAssertFalse(NetworkSearch.matches(httpEntry(responseBody: BodyData(data: past, contentType: nil, limit: .max)), query: "needle"))
    }

    func testImageBodiesAreSkipped() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data("tEXtsecret".utf8))
        let entry = httpEntry(url: "https://img.test/a", responseBody: BodyData(data: png, contentType: "image/png", limit: .max))
        XCTAssertFalse(NetworkSearch.matches(entry, query: "secret"))
    }

    func testASCIISearchAgreesWithFoundation() {
        let haystack = "The Quick brown FOX jumps over the lazy dog; quick-quack {\"key\":\"Value\"} 12345"
        let entry = httpEntry(responseBody: BodyData(text: haystack))
        let terms = ["quick", "QUACK", "fox", "dog;", "\"key\"", "value\"}", "345", "z", "lazy dogs", "xyz", "the", "k-q", "}", "12345 "]
        for term in terms {
            let expected = haystack.range(of: term.trimmingCharacters(in: .whitespaces), options: .caseInsensitive) != nil
            XCTAssertEqual(NetworkSearch.matches(entry, query: term), expected, term)
        }
    }

    func testSearchOverThousandLargeEntriesIsFast() {
        let chunk = Data(#"{"id":12345,"name":"lorem ipsum dolor sit amet","items":[1,2,3],"flag":true},"#.utf8)
        var body = Data()
        while body.count < 2 * 1024 * 1024 { body.append(chunk) }
        let shared = BodyData(data: body, contentType: "application/json", limit: .max)
        let entries = (0..<1000).map { index in
            httpEntry(url: "https://api.example.com/items/\(index)", body: shared, responseBody: shared)
        }
        var filter = NetworkFilter()
        filter.query = "zzqx"
        let start = Date()
        XCTAssertTrue(NetworkSearch.apply(filter, hiddenHosts: ["*.hidden.com"], to: entries).isEmpty)
        filter.query = "ipsum items/999"
        XCTAssertEqual(NetworkSearch.apply(filter, hiddenHosts: [], to: entries).count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNonASCIISearchAgreesWithFoundation() {
        let cases: [(String, String)] = [
            ("Алматы, ул. Абая", "АЛМАТЫ"), ("Алматы", "маты"), ("Ёлка", "ёл"), ("ӘЛЕМ Қазақстан", "қазақ"),
            ("Straße", "STRAẞE"), ("ΟΔΟΣ", "οδος"), ("οδοσ", "ς"), ("café", "CAFÉ"), ("cafe\u{301}", "café"),
            ("café", "é"), ("x\u{301}y", "x\u{301}"), ("ﬁle", "ﬁ"), ("µ", "μ"), ("Привет мир", "мира"),
            ("перевод средств", "СРЕДСТВ"), ("👨‍👩‍👧 family", "👨"), ("👍🏽 ok", "👍"), ("日本語テキスト", "テキ"),
            ("नमस्ते", "नम"), ("한국어", "국"), ("Ǆemal", "ǆ"), ("İstanbul", "İst"),
        ]
        for (haystack, term) in cases {
            let expected = haystack.range(of: term, options: .caseInsensitive) != nil
            let body = httpEntry(url: "https://e.com/a", responseBody: BodyData(text: "{\"v\":\"\(haystack)\"}", contentType: "application/json"))
            XCTAssertEqual(NetworkSearch.matches(body, query: term), expected, "body \(haystack) / \(term)")
            let header = httpEntry(url: "https://e.com/b", headers: [HTTPHeader(name: "X-Note", value: haystack)])
            XCTAssertEqual(NetworkSearch.matches(header, query: term), expected, "header \(haystack) / \(term)")
        }
    }

    func testNonASCIIBodySearchIsCachedAndInvalidatedOnChange() {
        let cache = SearchTextCache.shared
        var entry = httpEntry(responseBody: BodyData(text: "{\"city\":\"Алматы\"}", contentType: "application/json"))
        let misses = cache.missCount
        XCTAssertTrue(NetworkSearch.matches(entry, query: "алматы"))
        XCTAssertTrue(NetworkSearch.matches(entry, query: "АЛМАТЫ"))
        XCTAssertFalse(NetworkSearch.matches(entry, query: "астана"))
        XCTAssertEqual(cache.missCount - misses, 1)
        entry.response?.body = BodyData(text: "{\"city\":\"Астана\"}", contentType: "application/json")
        XCTAssertTrue(NetworkSearch.matches(entry, query: "астана"))
        XCTAssertFalse(NetworkSearch.matches(entry, query: "алматы"))
        XCTAssertEqual(cache.missCount - misses, 2)
    }

    func testCacheStaysWithinItsBudget() {
        let cache = SearchTextCache(byteBudget: 64 * 1024)
        let body = BodyData(text: String(repeating: "Ж", count: 4_000))
        for _ in 0..<100 {
            let entry = httpEntry(responseBody: body)
            _ = cache.foldedText(for: body, entry: entry, slot: .response, limit: NetworkSearch.bodySearchLimit)
        }
        XCTAssertLessThanOrEqual(cache.count * 8_000, 64 * 1024)
        XCTAssertGreaterThan(cache.count, 0)
    }

    func testRepeatedNonASCIISearchOverLargeBodiesIsFast() {
        var text = ""
        while text.utf8.count < 128 * 1024 {
            text += #"{"name":"Алматы Медеу","city":"Нур-Султан","note":"перевод средств на счёт"},"#
        }
        let body = BodyData(text: text, contentType: "application/json")
        let entries = (0..<60).map { index in
            httpEntry(url: "https://api.example.com/items/\(index)", body: body, responseBody: body)
        }
        var filter = NetworkFilter()
        filter.query = "АСТАНА"
        let firstStart = Date()
        XCTAssertTrue(NetworkSearch.apply(filter, hiddenHosts: [], to: entries).isEmpty)
        let first = Date().timeIntervalSince(firstStart)
        let repeatStart = Date()
        for _ in 0..<5 {
            XCTAssertTrue(NetworkSearch.apply(filter, hiddenHosts: [], to: entries).isEmpty)
        }
        let repeated = Date().timeIntervalSince(repeatStart) / 5
        filter.query = "медеу items/59"
        XCTAssertEqual(NetworkSearch.apply(filter, hiddenHosts: [], to: entries).map(\.id), [entries[59].id])
        XCTAssertLessThan(repeated, first)
        XCTAssertLessThan(repeated, 1)
    }

    func testRanges() {
        let text = "foo bar FooBar baz"
        let ranges = NetworkSearch.ranges(of: "foo BAR", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["foo", "bar", "FooBar"])
        XCTAssertEqual(NetworkSearch.ranges(of: "", in: text), [])
        XCTAssertEqual(NetworkSearch.ranges(of: "zzz", in: text), [])
        let overlapping = "aaaa"
        XCTAssertEqual(NetworkSearch.ranges(of: "aa aaa", in: overlapping).map { String(overlapping[$0]) }, ["aaaa"])
        let unicode = "Привет мир"
        XCTAssertEqual(NetworkSearch.ranges(of: "МИР", in: unicode).map { String(unicode[$0]) }, ["мир"])
    }
}
