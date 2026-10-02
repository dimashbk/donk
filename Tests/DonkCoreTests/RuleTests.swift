import Combine
import XCTest
@testable import DonkCore

final class HostPatternTests: XCTestCase {
    func testExactAndCaseInsensitive() {
        XCTAssertTrue(HostPattern.matches("api.example.com", pattern: "api.example.com"))
        XCTAssertTrue(HostPattern.matches("API.Example.COM", pattern: "api.example.com"))
        XCTAssertTrue(HostPattern.matches("api.example.com", pattern: " API.EXAMPLE.com "))
        XCTAssertFalse(HostPattern.matches("api.example.com", pattern: "example.com"))
        XCTAssertFalse(HostPattern.matches("", pattern: "*"))
        XCTAssertFalse(HostPattern.matches("a.com", pattern: ""))
    }

    func testSubdomainWildcard() {
        XCTAssertTrue(HostPattern.matches("api.example.com", pattern: "*.example.com"))
        XCTAssertTrue(HostPattern.matches("a.b.example.com", pattern: "*.example.com"))
        XCTAssertTrue(HostPattern.matches("example.com", pattern: "*.example.com"))
        XCTAssertTrue(HostPattern.matches("CDN.Example.com", pattern: "*.EXAMPLE.com"))
        XCTAssertFalse(HostPattern.matches("badexample.com", pattern: "*.example.com"))
        XCTAssertFalse(HostPattern.matches("example.com.evil.net", pattern: "*.example.com"))
    }

    func testStarAndGlobPatterns() {
        XCTAssertTrue(HostPattern.matches("anything.net", pattern: "*"))
        XCTAssertTrue(HostPattern.matches("api.staging.example.com", pattern: "api.*.example.com"))
        XCTAssertFalse(HostPattern.matches("api.example.com", pattern: "api.*.example.com"))
        XCTAssertTrue(HostPattern.matches("host1.local", pattern: "host?.local"))
        XCTAssertFalse(HostPattern.matches("host12.local", pattern: "host?.local"))
    }

    func testMatchesAny() {
        XCTAssertTrue(HostPattern.matchesAny("a.analytics.io", patterns: ["x.com", "*.analytics.io"]))
        XCTAssertFalse(HostPattern.matchesAny("a.b.c", patterns: ["x.com"]))
        XCTAssertFalse(HostPattern.matchesAny(nil, patterns: ["*"]))
        XCTAssertFalse(HostPattern.matchesAny("a.com", patterns: []))
    }
}

final class URLMatcherTests: XCTestCase {
    func testContainsIsCaseInsensitiveSubstring() {
        let matcher = URLMatcher(pattern: "/V1/Users", mode: .contains)
        XCTAssertTrue(matcher.matches("https://api.example.com/v1/users/42"))
        XCTAssertFalse(matcher.matches("https://api.example.com/v2/users"))
        XCTAssertFalse(URLMatcher(pattern: "", mode: .contains).matches("https://a.com"))
    }

    func testWildcardIsAnchoredAndCaseInsensitive() {
        let matcher = URLMatcher(pattern: "https://API.example.com/v1/*", mode: .wildcard)
        XCTAssertTrue(matcher.matches("https://api.example.com/v1/users?id=1"))
        XCTAssertTrue(matcher.matches("https://api.example.com/v1/"))
        XCTAssertFalse(matcher.matches("http://api.example.com/v1/users"))
        XCTAssertFalse(matcher.matches("xhttps://api.example.com/v1/users"))
        XCTAssertFalse(URLMatcher(pattern: "*/users", mode: .wildcard).matches("https://a.com/users/1"))
        XCTAssertTrue(URLMatcher(pattern: "*/users/?", mode: .wildcard).matches("https://a.com/users/7"))
        XCTAssertFalse(URLMatcher(pattern: "*/users/?", mode: .wildcard).matches("https://a.com/users/77"))
        XCTAssertTrue(URLMatcher(pattern: "*", mode: .wildcard).matches("anything"))
        XCTAssertTrue(URLMatcher(pattern: "*://*.example.com/*/items*", mode: .wildcard).matches("https://cdn.example.com/a/b/items?x"))
        XCTAssertTrue(URLMatcher(pattern: "https://ex.com/привет/*", mode: .wildcard).matches("https://EX.com/ПРИВЕТ/x"))
    }

    func testRegexIsUnanchoredSearch() {
        let matcher = URLMatcher(pattern: #"/users/\d+$"#, mode: .regex)
        XCTAssertTrue(matcher.matches("https://api.example.com/users/42"))
        XCTAssertFalse(matcher.matches("https://api.example.com/users/42/posts"))
        XCTAssertTrue(URLMatcher(pattern: "example\\.COM", mode: .regex).matches("https://api.example.com/x"))
        XCTAssertTrue(matcher.isValid)
    }

    func testInvalidRegexNeverMatches() {
        let matcher = URLMatcher(pattern: "([unclosed", mode: .regex)
        XCTAssertFalse(matcher.matches("([unclosed"))
        XCTAssertFalse(matcher.matches("anything"))
        XCTAssertFalse(matcher.isValid)
        XCTAssertFalse(matcher.matches("anything"))
    }

    func testRuleMatchKindsAndMethods() {
        let match = RuleMatch(kinds: [.http], method: "post", url: URLMatcher(pattern: "/upload"))
        XCTAssertTrue(match.matches(kind: .http, method: "POST", url: "https://a.com/upload"))
        XCTAssertFalse(match.matches(kind: .http, method: "GET", url: "https://a.com/upload"))
        XCTAssertFalse(match.matches(kind: .grpc, method: "POST", url: "grpc://a.com/upload"))
        XCTAssertFalse(match.matches(kind: .webView, method: "POST", url: "https://a.com/upload"))
        let any = RuleMatch(kinds: [.http, .grpc], method: nil, url: URLMatcher(pattern: "/upload"))
        XCTAssertTrue(any.matches(kind: .http, method: "DELETE", url: "https://a.com/upload"))
        let grpcMatch = RuleMatch(kinds: [.grpc], method: "GET", url: URLMatcher(pattern: "grpc://*/pkg.Svc/*", mode: .wildcard))
        XCTAssertTrue(grpcMatch.matches(kind: .grpc, method: "POST", url: "grpc://h.com/pkg.Svc/Get"))
        let emptyMethod = RuleMatch(kinds: [.http], method: " ", url: URLMatcher(pattern: "a"))
        XCTAssertTrue(emptyMethod.matches(kind: .http, method: "PATCH", url: "a"))
    }
}

final class PatchTests: XCTestCase {
    private let headers = [
        HTTPHeader(name: "Accept", value: "*/*"),
        HTTPHeader(name: "Authorization", value: "old"),
        HTTPHeader(name: "X-Trace", value: "1"),
        HTTPHeader(name: "authorization", value: "duplicate"),
    ]

    func testSetReplacesInPlaceCaseInsensitively() {
        let patch = HeaderPatch(set: [HTTPHeader(name: "AUTHORIZATION", value: "Bearer new")])
        XCTAssertEqual(patch.apply(to: headers), [
            HTTPHeader(name: "Accept", value: "*/*"),
            HTTPHeader(name: "AUTHORIZATION", value: "Bearer new"),
            HTTPHeader(name: "X-Trace", value: "1"),
        ])
    }

    func testSetAppendsMissingAndRemoveDrops() {
        let patch = HeaderPatch(set: [HTTPHeader(name: "X-New", value: "v")], remove: ["x-trace", " ACCEPT "])
        XCTAssertEqual(patch.apply(to: headers), [
            HTTPHeader(name: "Authorization", value: "old"),
            HTTPHeader(name: "authorization", value: "duplicate"),
            HTTPHeader(name: "X-New", value: "v"),
        ])
    }

    func testRepeatedSetNamesProduceMultipleHeaders() {
        let patch = HeaderPatch(set: [HTTPHeader(name: "Set-Cookie", value: "a=1"), HTTPHeader(name: "set-cookie", value: "b=2"), HTTPHeader(name: "", value: "x")])
        let result = patch.apply(to: [HTTPHeader(name: "Set-Cookie", value: "old=0")])
        XCTAssertEqual(result, [HTTPHeader(name: "Set-Cookie", value: "a=1"), HTTPHeader(name: "set-cookie", value: "b=2")])
        XCTAssertTrue(HeaderPatch().isEmpty)
        XCTAssertEqual(HeaderPatch().apply(to: headers), headers)
    }

    func testBodyPatchKeepAndReplace() {
        let input = Data("original".utf8)
        XCTAssertEqual(BodyPatch.keep.apply(to: input), input)
        XCTAssertNil(BodyPatch.keep.apply(to: nil))
        XCTAssertEqual(BodyPatch.replace("{\"ok\":true}").apply(to: input), Data("{\"ok\":true}".utf8))
        XCTAssertEqual(BodyPatch.replace("new").apply(to: nil), Data("new".utf8))
        XCTAssertEqual(BodyPatch.replace("base64:AAEC/w==").apply(to: input), Data([0, 1, 2, 255]))
        XCTAssertEqual(BodyPatch.replace("base64:%%%").apply(to: input), Data("base64:%%%".utf8))
        XCTAssertEqual(BodyPatch.replace("").apply(to: input), Data())
    }

    func testBodyPatchFindReplace() {
        let input = Data(#"{"name":"Alice","role":"user","id":42}"#.utf8)
        let patch = BodyPatch.findReplace([
            FindReplace(find: "\"user\"", replace: "\"admin\""),
            FindReplace(find: #""id":(\d+)"#, replace: #""id":"$1-x""#, isRegex: true),
            FindReplace(find: "", replace: "ignored"),
            FindReplace(find: "([bad", replace: "x", isRegex: true),
        ])
        XCTAssertEqual(patch.apply(to: input).flatMap { String(data: $0, encoding: .utf8) }, #"{"name":"Alice","role":"admin","id":"42-x"}"#)
        XCTAssertNil(patch.apply(to: nil))
        let binary = Data([0xC3, 0x28, 0x00, 0x75, 0x73, 0x65, 0x72])
        XCTAssertEqual(BodyPatch.findReplace([FindReplace(find: "user", replace: "x")]).apply(to: binary), binary)
    }

    func testMockResponseBodyDecoding() {
        XCTAssertEqual(MockResponse(body: "plain").bodyData, Data("plain".utf8))
        XCTAssertEqual(MockResponse(body: "base64:aGk=").bodyData, Data("hi".utf8))
        let mock = MockResponse()
        XCTAssertEqual(mock.statusCode, 200)
        XCTAssertEqual(mock.grpcStatusCode, 0)
        XCTAssertEqual(mock.delay, 0)
    }

    func testRuleCodableRoundTrip() throws {
        let rules = [
            NetworkRule(name: "Mock", match: RuleMatch(url: URLMatcher(pattern: "/a")), action: .mapLocal(MockResponse(statusCode: 418, body: "tea"))),
            NetworkRule(
                name: "Rewrite",
                isEnabled: false,
                match: RuleMatch(kinds: [.http, .grpc], method: "PUT", url: URLMatcher(pattern: "^/b$", mode: .regex)),
                action: .rewrite(
                    request: RequestRewrite(url: "https://x", headers: HeaderPatch(set: [HTTPHeader(name: "A", value: "1")]), body: .replace("z")),
                    response: ResponseRewrite(statusCode: 500, body: .findReplace([FindReplace(find: "a", replace: "b", isRegex: true)]), grpcStatusCode: 14)
                )
            ),
            NetworkRule(name: "Pause", match: RuleMatch(url: URLMatcher(pattern: "*", mode: .wildcard)), action: .breakpoint(request: true, response: false)),
        ]
        let decoded = try JSONDecoder().decode([NetworkRule].self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }
}

final class RuleStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> RuleStore {
        RuleStore(fileName: "rules.json", directory: directory)
    }

    private func rule(
        _ name: String,
        kinds: Set<NetworkKind> = [.http],
        method: String? = nil,
        pattern: String = "/api",
        mode: URLMatcher.Mode = .contains,
        enabled: Bool = true,
        action: RuleAction = .mapLocal(MockResponse())
    ) -> NetworkRule {
        NetworkRule(name: name, isEnabled: enabled, match: RuleMatch(kinds: kinds, method: method, url: URLMatcher(pattern: pattern, mode: mode)), action: action)
    }

    func testEmptyStoreResolvesNothing() {
        let store = makeStore()
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertFalse(store.hasActiveRules)
        XCTAssertTrue(store.resolve(kind: .http, method: "GET", url: "https://a.com/api").isEmpty)
    }

    func testResolveReturnsFirstTransformAndFirstBreakpointInListOrder() {
        let store = makeStore()
        let disabled = rule("disabled", enabled: false)
        let noOpBreakpoint = rule("noop", action: .breakpoint(request: false, response: false))
        let rewrite = rule("rewrite", action: .rewrite(request: RequestRewrite(method: "PUT"), response: nil))
        let breakpoint = rule("breakpoint", action: .breakpoint(request: true, response: true))
        let mock = rule("mock")
        let laterBreakpoint = rule("later", action: .breakpoint(request: true, response: false))
        [disabled, noOpBreakpoint, rewrite, breakpoint, mock, laterBreakpoint].forEach(store.add)
        let resolution = store.resolve(kind: .http, method: "GET", url: "https://a.com/api/users")
        XCTAssertEqual(resolution.transform?.id, rewrite.id)
        XCTAssertEqual(resolution.breakpoint?.id, breakpoint.id)
        XCTAssertFalse(resolution.isEmpty)
        XCTAssertTrue(store.hasActiveRules)
    }

    func testResolveFiltersByKindMethodAndURL() {
        let store = makeStore()
        let grpcOnly = rule("grpc", kinds: [.grpc], method: "DELETE", pattern: "grpc://*/pkg.Svc/*", mode: .wildcard)
        let postOnly = rule("post", method: "post", pattern: "/api")
        let regex = rule("regex", pattern: #"/items/\d+"#, mode: .regex)
        [grpcOnly, postOnly, regex].forEach(store.add)
        XCTAssertEqual(store.resolve(kind: .grpc, method: "POST", url: "grpc://h/pkg.Svc/Get").transform?.id, grpcOnly.id)
        XCTAssertNil(store.resolve(kind: .grpc, method: "POST", url: "grpc://h/other.Svc/Get").transform)
        XCTAssertEqual(store.resolve(kind: .http, method: "POST", url: "https://a.com/api").transform?.id, postOnly.id)
        XCTAssertNil(store.resolve(kind: .http, method: "GET", url: "https://a.com/api").transform)
        XCTAssertEqual(store.resolve(kind: .http, method: "GET", url: "https://a.com/items/12").transform?.id, regex.id)
        XCTAssertTrue(store.resolve(kind: .webView, method: "POST", url: "https://a.com/api").isEmpty)
    }

    func testGlobalSwitchDisablesResolution() {
        let store = makeStore()
        store.add(rule("mock"))
        store.isEnabled = false
        XCTAssertFalse(store.hasActiveRules)
        XCTAssertTrue(store.resolve(kind: .http, method: "GET", url: "https://a.com/api").isEmpty)
        store.isEnabled = true
        XCTAssertFalse(store.resolve(kind: .http, method: "GET", url: "https://a.com/api").isEmpty)
    }

    func testUpdateRemoveAndMove() {
        let store = makeStore()
        let rules = ["a", "b", "c", "d"].map { rule($0) }
        rules.forEach(store.add)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.rules.map(\.name), ["b", "c", "a", "d"])
        store.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        XCTAssertEqual(store.rules.map(\.name), ["a", "d", "b", "c"])
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 4)
        XCTAssertEqual(store.rules.map(\.name), ["a", "b", "c", "d"])
        store.move(fromOffsets: IndexSet(integer: 10), toOffset: 0)
        XCTAssertEqual(store.rules.map(\.name), ["a", "b", "c", "d"])
        var updated = rules[1]
        updated.name = "B!"
        updated.isEnabled = false
        store.update(updated)
        store.update(rule("unknown"))
        XCTAssertEqual(store.rules.map(\.name), ["a", "B!", "c", "d"])
        store.remove(rules[0].id)
        XCTAssertEqual(store.rules.map(\.name), ["B!", "c", "d"])
        XCTAssertEqual(store.resolve(kind: .http, method: "GET", url: "/api").transform?.name, "c")
    }

    func testChangesPublisherEmitsCurrentAndUpdates() {
        let store = makeStore()
        let events = EventRecorder(store.changes)
        let first = rule("first")
        store.add(first)
        store.isEnabled = false
        store.isEnabled = false
        store.remove(UUID())
        store.remove(first.id)
        XCTAssertEqual(events.values.map { $0.map(\.name) }, [[], ["first"], ["first"], []])
    }

    func testPersistenceRoundTrip() {
        let store = makeStore()
        let mock = rule("mock", method: "GET", action: .mapLocal(MockResponse(statusCode: 201, headers: [HTTPHeader(name: "A", value: "B")], body: "{}", delay: 1.5)))
        let pause = rule("pause", kinds: [.grpc], pattern: "Svc", action: .breakpoint(request: false, response: true))
        store.add(mock)
        store.add(pause)
        store.isEnabled = false
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rules, [mock, pause])
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rules.json").path))
        let other = RuleStore(fileName: "other.json", directory: directory)
        XCTAssertTrue(other.rules.isEmpty)
    }

    func testLenientDecodingSkipsBrokenRules() throws {
        let valid = rule("valid")
        let encodedRule = try JSONEncoder().encode(valid)
        let ruleJSON = String(decoding: encodedRule, as: UTF8.self)
        let file = #"{"isEnabled":true,"rules":[{"broken":true},\#(ruleJSON),42]}"#
        try Data(file.utf8).write(to: directory.appendingPathComponent("rules.json"))
        let store = makeStore()
        XCTAssertEqual(store.rules, [valid])
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("rules.json"))
        XCTAssertTrue(makeStore().rules.isEmpty)
    }

    func testConcurrentResolveWhileMutating() {
        let store = makeStore()
        store.add(rule("base", pattern: "/api"))
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index % 20 == 0 {
                store.add(rule("extra-\(index)", pattern: "/never"))
            } else {
                XCTAssertEqual(store.resolve(kind: .http, method: "GET", url: "https://a.com/api").transform?.name, "base")
            }
        }
        XCTAssertEqual(store.rules.count, 11)
    }
}

final class NetworkSettingsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testDefaultsWhenMissing() {
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertEqual(store.settings, .default)
        XCTAssertEqual(NetworkSettings.default.limit, 1000)
        XCTAssertEqual(NetworkSettings.default.maxBodySize, 2 * 1024 * 1024)
        XCTAssertTrue(NetworkSettings.default.hiddenHosts.isEmpty)
    }

    func testPersistsAndPublishes() {
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        let events = EventRecorder(store.changes)
        var settings = store.settings
        settings.hiddenHosts = ["*.analytics.io"]
        settings.bypassHosts = ["localhost"]
        settings.limit = 250
        store.settings = settings
        store.settings = settings
        XCTAssertEqual(events.values, [.default, settings])
        let reloaded = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertEqual(reloaded.settings, settings)
    }

    func testPartialFileFallsBackToDefaults() throws {
        try Data(#"{"limit":5}"#.utf8).write(to: directory.appendingPathComponent("settings.json"))
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertEqual(store.settings, NetworkSettings(limit: 5))
    }
}
