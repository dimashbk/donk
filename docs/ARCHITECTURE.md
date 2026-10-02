# donk — architecture contract

In-app debugger for iOS apps. SPM package, iOS 15+, SwiftUI UI, zero resources (no asset catalogs, no bundles — SF Symbols and code only).

This document is the contract between modules. Public signatures listed here are binding; implementations may add more API but must not change these.

## Package layout

```
donk/
  Package.swift                      swift-tools-version:5.9, Swift 5 language mode, platforms: [.iOS(.v15)], no dependencies
  Sources/
    DonkJSON/                        Foundation only. Order-preserving JSON parser/printer (JSONValue, JSONFormatting). Shared by Core and UI
    DonkCore/                        Foundation + Combine only (+ DonkJSON, re-exported). Models, stores, rules, breakpoints, gRPC recorder, exporters, search, JSON, persistence, swizzling helpers
    DonkUI/                          SwiftUI/UIKit design system + windowing infra. Depends only on DonkJSON (NOT on DonkCore)
    DonkNetwork/                     HTTP capture engine (URLProtocol + session swizzle), rules/breakpoints application for HTTP
    DonkNetworkUI/                   Network list/detail/filters/rules/breakpoint editor UI (HTTP + gRPC + WebView entries)
    DonkWebView/                     WKWebView capture (JS hooks + navigation observation)
    DonkInspector/                   UI inspector: select/measure, frames, grid, eyedropper
    DonkPerformance/                 CPU/memory/FPS/hitches/hangs/thermal/GPU(experimental), graphs, FPS HUD, alerts
    DonkCrashC/                      C: async-signal-safe crash handler, binary image table
    DonkCrash/                       Crash reports: install, parse, symbolicate, MetricKit, UI
    DonkPush/                        Push simulation, templates, history, token
    DonkStorage/                     Files browser, UserDefaults editor, Keychain viewer
    Donk/                            Umbrella: public facade `Donk`, launcher (bubble, shake), debugger window, home dashboard, settings. @_exported imports (not DonkUI)
  Tests/<Target>Tests/
  Integrations/
    DonkGRPC/                        Standalone sub-package (own Package.swift): grpc-swift 1.x ClientInterceptor feeding DonkCore
      Package.swift                  tools 5.9, iOS 15; depends on the root via .package(name: "Donk", path: "../.."), grpc-swift 1.21..<2,
                                     swift-protobuf 1.25+, swift-nio (NIOCore), swift-nio-http2 (NIOHPACK)
      Sources/DonkGRPC/
      Tests/DonkGRPCTests/           Protos/ excluded from the target
  Example/                           xcodegen project.yml + DonkDemo app (local package dependency)
  docs/
```

Dependency graph:

```
DonkJSON ── DonkCore, DonkUI
DonkCore ─┬─ DonkNetwork
          ├─ DonkWebView
          ├─ DonkGRPC (sub-package; + grpc-swift 1.x, swift-protobuf, NIOCore, NIOHPACK; public DonkCore API only)
DonkUI ───┼─ DonkNetworkUI (+Core)
          ├─ DonkInspector (+Core)
          ├─ DonkPerformance (+Core)
          ├─ DonkCrash (+Core, +DonkCrashC)
          ├─ DonkPush (+Core)
          └─ DonkStorage (+Core)
Donk = all of the above except DonkGRPC
```

Products: root package `Donk` (umbrella) and `DonkCore` (what DonkGRPC links); sub-package `Integrations/DonkGRPC` → `DonkGRPC`.

DonkGRPC lives outside the root package so that consumers of `Donk` fetch no third-party packages and a host that already links grpc-swift never gets a second copy. Because `package` access does not cross package boundaries, DonkGRPC may only use `public` DonkCore API.

## Global rules for all code

- Swift 5 language mode, tools 5.9. Cross-target internals use the `package` access modifier; consumer API is `public`.
- No descriptive comments. No `///` docs, no `//` narration. Only `// MARK: -` and swiftlint directives. Explanations go to docs/.
- No resources, no asset catalogs. Colors in code, icons = SF Symbols available on iOS 15.
- iOS 15 minimum: no `NavigationStack`, no Swift Charts, no `@Observable`. Use `ObservableObject`/`@Published`, `DonkNavigationContainer` (DonkUI) for navigation, `Canvas`/`Path` for charts. Newer APIs only behind `if #available`. Liquid Glass (`glassEffect`) only behind `#if compiler(>=6.2)` + `if #available(iOS 26, *)` with material fallback.
- Thread safety: stores are `@unchecked Sendable` classes guarded by `NSLock`/`os_unfair_lock`; publishers may emit on any thread; view models are `@MainActor ObservableObject`, receive on main and throttle (≈ 250 ms) for list updates.
- Publication order: a store enqueues its event/snapshot into a `PublicationQueue` (package, DonkCore/Support) while holding its state lock and flushes after releasing it. The queue delivers on one thread at a time, in mutation order, and never while a state lock is held; snapshot publishers (`BreakpointCenter.changes`, `RuleStore.changes`, `NetworkSettingsStore.changes`, environment flags) coalesce a batch to its latest value. A mutation made from inside a subscriber is delivered after the current value, not nested. When another thread is already delivering, a mutating call may return before its own event has been delivered.
- Donk never becomes key window unless a text input in the debugger UI is editing; overlay/HUD/bubble windows return `false` from `canBecomeKey` and pass touches through outside their content.
- Donk must never alter app behavior unless a user explicitly enabled a rule/breakpoint/simulation.
- Donk's own network traffic (e.g., push attachment downloads) must bypass capture: mark requests with `URLProtocol.setProperty(true, forKey: DonkEnvironment.internalRequestKey, in:)` or use `DonkEnvironment.internalSession`.
- Persistence lives in `Library/Application Support/Donk/` via `DonkPersistence`. Never write to the app's `UserDefaults.standard` or Documents.
- No disk access before use: constructing a store (including the `shared` instances, which `DonkGRPCOptions` defaults reference) reads no file and creates no directory. A persisted store loads its file on first read, write or `changes` subscription; only a write creates the directory. `DonkPersistence.load` never creates it.
- UI language: English.

## DonkCore API (binding)

### Network models

```swift
public enum NetworkKind: String, Codable, Sendable, CaseIterable { case http, grpc, webView }
public enum NetworkState: String, Codable, Sendable { case pending, paused, streaming, completed, failed, cancelled }
public enum StatusCategory: String, Codable, Sendable, CaseIterable { case pending, success, redirect, clientError, serverError, failure }

public struct HTTPHeader: Codable, Sendable, Hashable { public var name: String; public var value: String }

public struct BodyData: Codable, Sendable, Equatable {
    public var data: Data
    public var contentType: String?
    public var originalSize: Int
    public var isTruncated: Bool
    public init(data: Data, contentType: String?, limit: Int)         // truncates to limit
    public var text: String? { get }                                  // UTF-8 (lossy fallback: nil if not decodable)
    public var isJSON: Bool { get }
    public var prettyJSON: String? { get }
    public var isImage: Bool { get }
    public var isFormURLEncoded: Bool { get }
}

public struct RequestSnapshot: Codable, Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [HTTPHeader]
    public var body: BodyData?
    public var host: String? { get }
    public var path: String { get }
    public var queryItems: [URLQueryItem] { get }                     // URLQueryItem not Codable: computed only
    public func header(_ name: String) -> String?                    // case-insensitive
}

public struct ResponseSnapshot: Codable, Sendable, Equatable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: BodyData?
    public func header(_ name: String) -> String?
}

public struct TransactionMetrics: Codable, Sendable, Equatable {
    public var fetchStart, domainLookupStart, domainLookupEnd, connectStart, connectEnd,
               secureConnectionStart, secureConnectionEnd, requestStart, requestEnd,
               responseStart, responseEnd: Date?
    public var networkProtocol: String?
    public var remoteAddress: String?
    public var tlsProtocol: String?
    public var tlsCipherSuite: String?
    public var isReusedConnection: Bool
    public var isProxyConnection: Bool
    public var requestHeaderBytes, requestBodyBytes, responseHeaderBytes, responseBodyBytes: Int64
}

public struct NetworkTiming: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var responseStartedAt: Date?
    public var endedAt: Date?
    public var transactions: [TransactionMetrics]
    public var duration: TimeInterval? { get }
}

public enum NetworkOrigin: Codable, Sendable, Equatable {
    case network
    case mocked(rule: String)
    case rewritten(rule: String)
    case breakpoint(edited: Bool)
}

public struct NetworkErrorInfo: Codable, Sendable, Equatable { public var domain: String; public var code: Int; public var message: String }

public enum GRPCCallType: String, Codable, Sendable { case unary, clientStreaming, serverStreaming, bidirectionalStreaming }

public struct GRPCMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Direction: String, Codable, Sendable { case sent, received }
    public var id: UUID
    public var direction: Direction
    public var timestamp: Date
    public var typeName: String
    public var size: Int
    public var json: String?
    public var textFormat: String?
    public var raw: Data?
}

public struct GRPCDetails: Codable, Sendable, Equatable {
    public var service: String                                        // "bank.v1.AccountService"
    public var method: String                                         // "GetAccount"
    public var path: String                                           // "/bank.v1.AccountService/GetAccount" (+ any prefix as seen)
    public var callType: GRPCCallType
    public var statusCode: Int?                                       // gRPC code, nil while in flight
    public var statusMessage: String?
    public var requestMetadata: [HTTPHeader]
    public var responseHeaders: [HTTPHeader]
    public var trailers: [HTTPHeader]
    public var messages: [GRPCMessage]                                // ring-capped at 1000 per call (get/set; see below)
    public var timeout: TimeInterval?
    public private(set) var sentMessageCount, receivedMessageCount, sentBytes, receivedBytes: Int   // every message ever seen
    public private(set) var storedMessageBytes: Int                   // json + textFormat + raw bytes of the kept messages
    public var messageCount: Int { get }                              // kept messages, O(1)
    public var droppedMessageCount: Int { get }
    public mutating func append(_ message: GRPCMessage, limit: Int = GRPCDetails.messageLimit)
    public var statusName: String? { get }                            // "OK", "UNAVAILABLE", ...
    public static func statusName(for code: Int) -> String
}
// GRPCMessage also has `public var storedByteCount: Int { get }`.
// The ring keeps a private buffer plus a head index: `append` is amortized O(1) (evicted slots are released at once and the
// buffer is compacted in batches). Reading `messages` copies the kept slice when the head is not 0. Codable keeps the
// original keys ("messages" = kept messages) and Equatable compares kept messages, not the internal layout.

public enum WebInitiator: String, Codable, Sendable { case document, fetch, xhr, beacon, websocket, eventSource, resource }
public enum CaptureLevel: String, Codable, Sendable { case full, metadata, observed }

public struct WebViewDetails: Codable, Sendable, Equatable {
    public var pageURL: String?
    public var initiator: WebInitiator
    public var captureLevel: CaptureLevel
    public var webViewID: String?
}

public struct NetworkEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var kind: NetworkKind
    public var state: NetworkState
    public var origin: NetworkOrigin
    public var request: RequestSnapshot
    public var response: ResponseSnapshot?
    public var error: NetworkErrorInfo?
    public var timing: NetworkTiming
    public var grpc: GRPCDetails?
    public var web: WebViewDetails?
    public var isPinned: Bool

    public var host: String? { get }
    public var path: String { get }
    public var title: String { get }                                  // HTTP: path; gRPC: "Service/Method"
    public var methodLabel: String { get }                            // "GET" / "UNARY" / "SERVER STREAM" / ...
    public var statusLabel: String { get }                            // "200" / "OK" / "UNAVAILABLE" / "…" / "ERR"
    public var statusCategory: StatusCategory { get }                 // gRPC: OK→success, non-OK→serverError/clientError by code, error→failure
    public var requestSize: Int { get }
    public var responseSize: Int { get }
    public var duration: TimeInterval? { get }
}
```

### NetworkStore

```swift
public enum NetworkStoreEvent: Sendable { case added(UUID), updated(UUID), removed(Set<UUID>), cleared }

public final class NetworkStore: @unchecked Sendable {
    public static let shared: NetworkStore
    public static let defaultMaxTotalBytes: Int                       // 96 MB
    public init(limit: Int = 1000, maxBodySize: Int = 2 * 1024 * 1024, maxTotalBytes: Int = NetworkStore.defaultMaxTotalBytes)
    public var limit: Int                                             // ring buffer; pinned entries are never evicted
    public var maxTotalBytes: Int                                     // budget over request + response bodies + gRPC message json/textFormat/raw
    public var totalBytes: Int { get }
    public var maxBodySize: Int
    public var isCaptureEnabled: Bool                                 // capture layers check it before recording
    public func add(_ entry: NetworkEntry)
    public func update(_ id: UUID, _ transform: (inout NetworkEntry) -> Void)
    public func entry(_ id: UUID) -> NetworkEntry?
    public func snapshot() -> [NetworkEntry]                          // newest first
    public func remove(_ ids: Set<UUID>)
    public func clear(keepPinned: Bool = true)
    public var hosts: [String] { get }                                // sorted, unique
    public var count: Int { get }
    public var events: AnyPublisher<NetworkStoreEvent, Never> { get }
}
```

Eviction runs after `add`, after an `update` that pushes `totalBytes` over budget, and when `limit`/`maxTotalBytes` change: the oldest unpinned entries go first, and the entry being added or updated is never evicted by its own call. Slots carry a sequence number, so `remove` followed by `add` with the same id leaves exactly one live slot.

### Settings, filter, search

```swift
public struct NetworkSettings: Codable, Equatable, Sendable {
    public var hiddenHosts: [String]                                  // presentation-only exclusion, HostPattern syntax
    public var bypassHosts: [String]                                  // capture-level exclusion (never intercepted)
    public var maxBodySize: Int
    public var limit: Int
    public var redactsExports: Bool                                   // default true
    public var redaction: RedactionPolicy                             // default .default
    public var exportRedaction: RedactionPolicy? { get }              // redaction when redactsExports, else nil
    public static let `default`: NetworkSettings
}
// Decoding is lenient: missing or malformed keys (older files) fall back to the defaults.

public final class NetworkSettingsStore: @unchecked Sendable {
    public static let shared: NetworkSettingsStore
    public init(fileName: String = "network-settings.json", directory: URL? = nil)   // nil = DonkPersistence directory; no I/O until first access
    public var settings: NetworkSettings                              // persisted "network-settings.json"
    public func update(_ change: (inout NetworkSettings) -> Void)     // atomic read-modify-write
    public var changes: AnyPublisher<NetworkSettings, Never> { get }
}

public enum HostPattern {
    public static func matches(_ host: String, pattern: String) -> Bool
    public static func matchesAny(_ host: String?, patterns: [String]) -> Bool
}
// Case-insensitive, surrounding whitespace ignored. "*" matches every host. "*.domain" (no other wildcard) matches the
// bare domain and any subdomain. Any other pattern containing "*" (any run of characters, including dots) or "?"
// (one character) is a glob over the whole host. Everything else is an exact match.

public struct NetworkFilter: Codable, Equatable, Sendable {
    public var query: String
    public var kinds: Set<NetworkKind>                                // empty = all
    public var hosts: Set<String>                                     // empty = all
    public var statusCategories: Set<StatusCategory>                  // empty = all
    public var onlyModified: Bool                                     // mocked/rewritten/breakpoint
    public var onlyPinned: Bool
    public init()
}

public enum NetworkSearch {
    public static func apply(_ filter: NetworkFilter, hiddenHosts: [String], to entries: [NetworkEntry]) -> [NetworkEntry]
    public static func matches(_ entry: NetworkEntry, query: String) -> Bool   // url, method, status, header names+values, request/response bodies (first 256 KB as text), gRPC messages json, error message; case-insensitive; multiple space-separated terms = AND
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>]
}
```

Search terms that are pure ASCII scan raw UTF-8 bytes (memchr on the rarest byte, ASCII case folding). Other terms compare Unicode-folded text: both sides go through `folding(options: .caseInsensitive)` plus NFC, are searched as bytes with `memmem`, and a hit is rejected when the next scalar continues the grapheme (combining marks, ZWJ, emoji modifiers). This gives the same results as Foundation's `range(of:options: .caseInsensitive)` about 10× faster. For bodies, the folded text is cached in a bounded LRU (32 MB, internal `SearchTextCache`) keyed by entry id + slot. A cheap fingerprint (state, message count, body sizes, sampled bytes) invalidates it, so repeat refreshes skip decoding and folding.

### Rules (replace request/response) — persisted "rules.json"

```swift
public struct URLMatcher: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case contains, wildcard, regex }
    public var pattern: String
    public var mode: Mode
    public func matches(_ url: String) -> Bool                        // wildcard: "*" any chars, matched against full URL string
}

public struct RuleMatch: Codable, Equatable, Sendable {
    public var kinds: Set<NetworkKind>                                // .http and/or .grpc (webView not supported for rules)
    public var method: String?                                        // nil = any; for gRPC ignored
    public var url: URLMatcher                                        // for gRPC matched against "grpc://host/path"
}

public struct HeaderPatch: Codable, Equatable, Sendable {
    public var set: [HTTPHeader]
    public var remove: [String]
    public func apply(to headers: [HTTPHeader]) -> [HTTPHeader]
}

public struct FindReplace: Codable, Equatable, Sendable { public var find: String; public var replace: String; public var isRegex: Bool }

public enum BodyPatch: Codable, Equatable, Sendable {
    case keep
    case replace(String)
    case findReplace([FindReplace])
    public func apply(to data: Data?) -> Data?
}

public struct MockResponse: Codable, Equatable, Sendable {
    public var statusCode: Int                                        // HTTP
    public var headers: [HTTPHeader]
    public var body: String                                           // HTTP body text; base64 if prefixed "base64:"
    public var delay: TimeInterval
    public var grpcStatusCode: Int                                    // gRPC
    public var grpcStatusMessage: String?
    public var grpcMessages: [String]                                 // JSON per response message
}

public struct RequestRewrite: Codable, Equatable, Sendable {
    public var url: String?
    public var method: String?
    public var headers: HeaderPatch
    public var body: BodyPatch
}

public struct ResponseRewrite: Codable, Equatable, Sendable {
    public var statusCode: Int?
    public var headers: HeaderPatch
    public var body: BodyPatch
    public var grpcStatusCode: Int?
    public var grpcStatusMessage: String?
}

public enum RuleAction: Codable, Equatable, Sendable {
    case mapLocal(MockResponse)
    case rewrite(request: RequestRewrite?, response: ResponseRewrite?)
    case breakpoint(request: Bool, response: Bool)
}

public struct NetworkRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var match: RuleMatch
    public var action: RuleAction
    public var createdAt: Date
}

public struct RuleResolution: Sendable {
    public var transform: NetworkRule?                                // first enabled mapLocal/rewrite rule in list order
    public var breakpoint: NetworkRule?                               // first enabled breakpoint rule in list order
    public var isEmpty: Bool { get }
}

public final class RuleStore: @unchecked Sendable {
    public static let shared: RuleStore
    public init(fileName: String = "rules.json", directory: URL? = nil)   // nil = DonkPersistence directory; no I/O until first access
    public var isEnabled: Bool                                        // global switch, persisted
    public var rules: [NetworkRule] { get }
    public func add(_ rule: NetworkRule)
    public func update(_ rule: NetworkRule)
    public func remove(_ id: UUID)
    public func move(fromOffsets: IndexSet, toOffset: Int)
    public func resolve(kind: NetworkKind, method: String, url: String) -> RuleResolution   // fast path: empty when !isEnabled or no enabled rules
    public var hasActiveRules: Bool { get }
    public var changes: AnyPublisher<[NetworkRule], Never> { get }
}
```

### Breakpoints

```swift
public enum BreakpointPhase: String, Codable, Sendable { case request, response }

public struct EditableRequest: Codable, Equatable, Sendable {
    public var url: String
    public var method: String
    public var headers: [HTTPHeader]
    public var body: String                                           // text; gRPC: pretty JSON of one message (the first held request message)
    public var bodyIsBinary: Bool                                     // true: body is base64 and not editable as text
}

public struct EditableResponse: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var headers: [HTTPHeader]
    public var body: String
    public var bodyIsBinary: Bool
    public var grpcStatusCode: Int?
    public var grpcStatusMessage: String?
}

public enum BreakpointPayload: Equatable, Sendable { case request(EditableRequest), response(EditableResponse) }

public struct PausedExchange: Identifiable, Sendable {
    public var id: UUID
    public var entryID: UUID
    public var kind: NetworkKind
    public var phase: BreakpointPhase
    public var ruleName: String
    public var createdAt: Date
    public var payload: BreakpointPayload
}

public enum BreakpointDecision: Sendable {
    case resume(BreakpointPayload)                                    // possibly edited
    case abort                                                        // fail the call (HTTP: NSURLErrorCancelled; gRPC: CANCELLED)
    case respond(EditableResponse)                                    // request phase only: answer locally, never hit the server
}

public final class BreakpointCenter: @unchecked Sendable {
    public static let shared: BreakpointCenter
    public init(timeout: TimeInterval = 300, hasPresenter: Bool = false)
    public var timeout: TimeInterval                                  // auto-resume unedited, default 300
    public var hasPresenter: Bool                                     // thread-safe; false: pause returns .resume(original) at once
    public func pause(_ exchange: PausedExchange) async -> BreakpointDecision
    public func resolve(_ id: UUID, with decision: BreakpointDecision)
    public var pending: [PausedExchange] { get }
    public var changes: AnyPublisher<[PausedExchange], Never> { get }
}
```

The capture layer sets the entry `state = .paused` while waiting and restores it after.

`hasPresenter` says whether a UI can resolve exchanges. The umbrella's `BreakpointCoordinator` sets it to true on start and false on stop. While it is false, `pause` returns `.resume(original payload)` at once and nothing is published. Setting it to false resumes every pending exchange with its original payload, so nothing waits out the 300 s timeout with no UI. `changes` is published in mutation order (see Publication order), so a resolved exchange never reappears after a stale snapshot.

gRPC payloads: a request breakpoint shows the first held request message as one pretty JSON object (base64 + `bodyIsBinary` if it has no JSON form). A response breakpoint shows one message: the first held message for unary/client-streaming calls, or the current message for server/bidi streams. On resume or respond, the response body may be one JSON object or a JSON array of objects. An array replaces that position with several messages, and an empty body sends none.

### gRPC recording API (transport-agnostic)

```swift
public final class GRPCCallRecorder: @unchecked Sendable {
    public static let maxMessageTextSize: Int                         // 64 KB per message json / textFormat
    public static let responseBodyInterval: TimeInterval              // 0.25 s
    public init(host: String?, path: String, callType: GRPCCallType, requestMetadata: [HTTPHeader], timeout: TimeInterval?, store: NetworkStore = .shared)
    public var entryID: UUID { get }
    public func didSend(typeName: String, size: Int, json: String?, textFormat: String? = nil, raw: Data? = nil)
    public func didReceiveHeaders(_ headers: [HTTPHeader])
    public func didReceive(typeName: String, size: Int, json: String?, textFormat: String? = nil, raw: Data? = nil)
    public func didFinish(statusCode: Int, message: String?, trailers: [HTTPHeader])
    public func didFail(_ error: Error)
    public func didCancel()
    public func setOrigin(_ origin: NetworkOrigin)
}
```

Entry mapping: `kind = .grpc`, `request.url = "grpc://<host or "grpc"><path>"`, `request.method = "POST"`, `request.headers = requestMetadata`, `request.body` = first sent message JSON (UTF-8), `response.statusCode = 200` once headers arrive, `response.body` = last received message JSON, `grpc.messages` = full timeline. `state`: pending → streaming (stream types after first message) → completed/failed/cancelled. One entry per RPC, updated live. Idempotent finish (first terminal event wins).

Each timeline message's `json`/`textFormat` is capped at `maxMessageTextSize` UTF-8 bytes (cut on a scalar boundary) with the suffix `… (truncated, N bytes)`, where N is the full size. `request.body`/`response.body` keep the full JSON up to `maxBodySize`. `response.body` is refreshed at most every `responseBodyInterval`: the first received message applies at once, later ones within the window are held and applied by a trailing flush, and the latest held message is always applied on finish/fail/cancel.

### Exporters

```swift
public enum CurlExporter {
    public static func command(for request: RequestSnapshot) -> String
    public static func command(for request: RequestSnapshot, redaction: RedactionPolicy?) -> String
}   // POSIX single-quote escaping ('\''), --compressed when Accept-Encoding gzip, -X only when needed, --globoff when the URL has [ ] { },
    // binary body -> --data-binary @body.bin note, truncated body -> first line "# donk: request body truncated (N of M bytes)"
public enum GRPCurlExporter {
    public static func command(for entry: NetworkEntry, plaintext: Bool = false) -> String
    public static func command(for entry: NetworkEntry, plaintext: Bool = false, redaction: RedactionPolicy?) -> String
}   // grpcurl -H ... -d '<json>' host:443 service/method
public enum EntryTextExporter {
    public static func text(for entry: NetworkEntry) -> String
    public static func text(for entry: NetworkEntry, redaction: RedactionPolicy?) -> String
}   // full human-readable representation of request + response (+ gRPC messages)
public enum HARExporter {
    public static let creatorVersion: String                          // DonkEnvironment.version
    public static func data(for entries: [NetworkEntry]) throws -> Data
    public static func data(for entries: [NetworkEntry], redaction: RedactionPolicy?) throws -> Data
    public static func document(for entries: [NetworkEntry]) -> JSONValue
    public static func document(for entries: [NetworkEntry], redaction: RedactionPolicy?) -> JSONValue
}
```

The overloads without `redaction` export verbatim (nil = no redaction). DonkNetworkUI's copy/share actions pass `NetworkSettingsStore.shared.settings.exportRedaction`.

### Redaction (exports)

```swift
public struct RedactionPolicy: Codable, Equatable, Sendable {
    public static let defaultHeaders: [String]   // authorization, proxy-authorization, cookie, set-cookie, x-api-key, x-auth-token, x-access-token
    public static let defaultKeys: [String]      // password, pass, passcode, pin, token, access_token, accessToken, refresh_token, refreshToken,
                                                 // id_token, secret, client_secret, otp, cvv, cvc, cardNumber, card_number, pan
    public static let defaultReplacement: String // "••••"
    public static let `default`: RedactionPolicy
    public var headers: [String]                 // case-insensitive header names
    public var keys: [String]                    // case-insensitive JSON keys, query/form/fragment names, protobuf text-format fields
    public var replacement: String
    public init(headers: [String] = defaultHeaders, keys: [String] = defaultKeys, replacement: String = defaultReplacement)
    public func redactsHeader(_ name: String) -> Bool
    public func redactsKey(_ key: String) -> Bool
    public func redact(_ entry: NetworkEntry) -> NetworkEntry
    public func redact(_ request: RequestSnapshot) -> RequestSnapshot
    public func redact(_ response: ResponseSnapshot) -> ResponseSnapshot
    public func redact(headers: [HTTPHeader]) -> [HTTPHeader]
    public func redact(url: String) -> String
    public func redact(body: BodyData) -> BodyData
    public func redact(json: String) -> String
    public func redact(formURLEncoded text: String) -> String
}
```

`redact(_ entry:)` covers request/response headers, the URL query and a `key=value` fragment (`#access_token=…`), web page URL, JSON bodies (by JSON content type, or text that starts with `{`/`[`), form-urlencoded bodies, gRPC request metadata, response headers, trailers, message JSON and text format. JSON is redacted recursively through DonkJSON: member order is kept, a matching key's whole value (string, number, object or array) becomes the replacement string, and output is compact unless the original contained a newline. JSON that does not parse (for example a truncated body) is redacted by a tolerant scanner that keeps the original bytes and replaces only matching values. A form/query name also matches through its last bracket component (`user[password]`). Body `originalSize`/`isTruncated` are kept. Binary bodies and raw protobuf bytes are not redacted. Decoding is lenient (missing keys → defaults).

### JSON (target DonkJSON, already implemented — Sources/DonkJSON/JSONValue.swift; DonkCore re-exports it with `@_exported import DonkJSON`)

The parser rejects nesting deeper than 200 levels. At about 500 levels, recursive descent overflowed 512 KB background-thread stacks in -Onone builds.

```swift
public struct JSONMember: Equatable, Sendable { public var key: String; public var value: JSONValue }
public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])                                         // key order preserved
    case array([JSONValue])
    case string(String)
    case number(String)                                               // raw literal preserved
    case bool(Bool)
    case null
    public static func parse(_ data: Data) throws -> JSONValue
    public static func parse(_ string: String) throws -> JSONValue
    public var isContainer: Bool; public var childCount: Int; public var typeName: String
    public subscript(key: String) -> JSONValue?
    public func prettyPrinted(indent: Int = 2) -> String
    public func compact() -> String
}
public enum JSONFormatting {
    public static func pretty(_ data: Data) -> String?
    public static func pretty(_ string: String) -> String?
    public static func isValid(_ string: String) -> Bool
    public static func isValid(_ data: Data) -> Bool
    public static func escape(_ string: String) -> String             // quoted JSON string literal
}
```

### Persistence, swizzling, misc

```swift
package enum DonkPersistence {                                     // package: only donk modules persist through it
    package static var directory: URL { get }                        // Library/Application Support/Donk; computing it touches no disk
    package static func load<T: Decodable>(_ type: T.Type, from name: String) -> T?
    package static func save<T: Encodable>(_ value: T, to name: String)
    package static func load<T: Decodable>(_ type: T.Type, from name: String, in directory: URL) -> T?   // never creates the directory
    package static func save<T: Encodable>(_ value: T, to name: String, in directory: URL)            // creates the directory on demand
    package static func remove(_ name: String, in directory: URL)
    package static func createDirectory(_ url: URL)                  // creating `directory` (or a subfolder) marks it excluded from backup
}
package enum DonkSwizzle {                                         // package: nothing outside the root package swizzles
    @discardableResult package static func instanceMethod(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) -> Bool
    @discardableResult package static func classMethod(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) -> Bool
}
public enum DonkEnvironment {                                      // was `enum DonkCore`; renamed so `DonkCore.X` can disambiguate module types
    public static let version: String                                // "0.1.0"; Donk.version and HARExporter.creatorVersion forward to it
    public static let internalRequestKey: String                     // URLProtocol property key: request must not be captured
    public static let internalSession: URLSession                    // ephemeral session whose requests are marked internal
    public static var appInfo: AppInfo { get }                       // name, bundleID, version, build, os, device model
    package static func markInternal(_ configuration: URLSessionConfiguration)    // swizzled session init skips marked configurations (identity, checked before URLSession copies it)
    package static func isInternal(_ configuration: URLSessionConfiguration) -> Bool

    public static var isActive: Bool { get }                         // true between Donk.start and Donk.stop (thread-safe)
    public static var activation: AnyPublisher<Bool, Never> { get }  // current value first, then changes
    package static func setActive(_ isActive: Bool)                  // umbrella DonkEngine only

    public static var isDebuggerVisible: Bool { get }                // debugger window shown (thread-safe)
    public static var debuggerVisibility: AnyPublisher<Bool, Never> { get }
    package static func setDebuggerVisible(_ isVisible: Bool)        // umbrella DebuggerPresenter only
    package static var hideDebuggerHandler: (@MainActor () -> Void)? // set by the umbrella runtime while started (lock-protected)
    @MainActor public static func requestHideDebugger()              // hides the debugger without animation; no-op when donk is not started
}
public struct AppInfo: Sendable { public var name, bundleID, version, build, osVersion, deviceModel: String }
```

Feature modules use these flags to cooperate with the umbrella without depending on it. DonkGRPC passes calls through untouched while `isActive` is false. Performance alerts can be suppressed while `isDebuggerVisible` is true. Push Inject/Tap call `requestHideDebugger()` before invoking app delegates.

`DonkCoreImageSentinel` (`@objc(DonkCoreImageSentinel)`, internal, referenced from `DonkEnvironment`) detects duplicate images. If DonkCore is statically linked into two images (for example the app and a dynamic framework or an extension that both link donk), the ObjC runtime logs `Class DonkCoreImageSentinel is implemented in both …`. Each image then has its own stores and swizzles. Link donk into exactly one image, or use dynamic frameworks.

## Feature module entry points (binding)

```swift
// DonkNetwork
public struct NetworkCaptureConfiguration: Sendable { public var isEnabled = true; public var bypassHosts: [String] = []; public init() }
public enum DonkNetworkCapture {
    public static func start(_ configuration: NetworkCaptureConfiguration)
    public static func stop()
    public static var isRunning: Bool { get }
    public static func inject(into configuration: URLSessionConfiguration)   // manual opt-in
}

// DonkNetworkUI
public enum DonkNetworkUI {
    @MainActor public static func makeRootView() -> AnyView
    @MainActor public static func makeBreakpointView(_ exchange: PausedExchange) -> AnyView
}

// DonkWebView
public enum DonkWebViewCapture {
    public static func start(automatic: Bool = true)                   // always hooks -[WKWebView setNavigationDelegate:]; automatic: also hooks
                                                                       // init(frame:configuration:) and init(coder:) and attaches scripts to new web views
    public static func stop()
    public static func attach(to configuration: WKWebViewConfiguration)
    @MainActor public static func attach(to webView: WKWebView)       // existing web view: scripts + navigation observation
    public static var makesWebViewsInspectable: Bool                   // iOS 16.4+ isInspectable, persisted; turning it on installs the init hooks too
    public static var isRunning: Bool { get }
}

// DonkInspector
public enum InspectorMode: String, CaseIterable, Sendable { case select, frames, grid, colorPicker }
public enum DonkInspector {
    @MainActor public static func start(_ mode: InspectorMode)
    @MainActor public static func stop()
    @MainActor public static var activeMode: InspectorMode? { get }
    @MainActor public static func makeRootView() -> AnyView          // settings/entry screen inside debugger

    // extra API (not binding for other modules)
    @MainActor public static var onWillStart: (() -> Void)?          // called by every start(_:); the umbrella hides the debugger here
    @MainActor public static var onOpenDebugger: (() -> Void)?       // toolbar "open donk" button; hidden while nil
    @MainActor public static var showsOutlinesWhileSelecting: Bool { get set }   // Frames combined with Select, persisted
    @MainActor public static var selectedView: UIView? { get }
    @MainActor public static func select(view: UIView, expandsPanel: Bool = false)   // starts Select if needed
    @MainActor public static func select(at point: CGPoint, expandsPanel: Bool = false)   // active scene, window points; may pick a SwiftUI accessibility element
    @MainActor public static func measure(to view: UIView)            // with a selection: measure selection ↔ view
    @MainActor @discardableResult public static func sampleColor(at point: CGPoint) -> String?   // starts Eyedropper, pins the loupe, returns #RRGGBB[AA]
}
// Inspector notes: one DonkHostingPassthroughWindow per foreground scene at DonkWindowLevel.inspector (never key).
// Drawing: UIKit canvas (CAShapeLayers) inserted below the hosting view + SwiftUI (Canvas grid, loupe, chrome).
// Frames/Grid pass touches through; Select/Eyedropper capture them except on the toolbar and panels.
// SwiftUI vends its accessibility tree only while application accessibility is on, so Select mode enables it via
// libAccessibility `_AXSApplicationAccessibilitySetEnabled` (dlsym, no-op if missing) and restores it when Select ends.
// Settings and recent colors persist in "inspector-settings.json".

// DonkPerformance
public struct PerformanceConfiguration: Sendable { public var alertsEnabled = true; public init() }
public enum DonkPerformance {
    public static func start(_ configuration: PerformanceConfiguration)
    public static func stop()
    @MainActor public static var isHUDVisible: Bool { get set }       // FPS overlay above all screens, persisted
    @MainActor public static func makeRootView() -> AnyView
    @MainActor public static func makeDashboardSparkline() -> AnyView // tiny live view for home tile
}

// DonkCrash
public enum DonkCrash {
    public static func install()                                     // call before FirebaseApp.configure()
    public static var isInstalled: Bool { get }
    public static func reportCount() -> Int
    @MainActor public static func makeRootView() -> AnyView
}

// DonkPush
public struct PushTemplate: Codable, Sendable, Identifiable { public var id: UUID; public var name: String; public var payload: String }   // payload: APNs JSON
public struct PushConfiguration: Sendable {
    public var templates: [PushTemplate] = []
    public var attachmentURLKeyPaths: [String] = ["fcm_options.image", "imageUrl", "image", "attachment-url", "media-url"]
    public var recordsIncomingPushes = true
    public init()
}
public enum DonkPush {
    public static func start(_ configuration: PushConfiguration)
    public static func didRegister(deviceToken: Data)
    public static func setFCMToken(_ token: String?)
    public static var contentProcessor: (@Sendable (UNMutableNotificationContent) async -> UNNotificationContent)?   // run host NSE logic; replaces donk's own attachment download
    public static func attachMedia(to content: UNMutableNotificationContent, keyPaths: [String]? = nil) async -> UNMutableNotificationContent   // for processors: downloads the first URL found in userInfo (nil = attachmentURLKeyPaths) through an internal, never captured session and appends it to attachments; returns the same instance, unchanged when no URL is found or the download fails
    @MainActor public static func makeRootView() -> AnyView
}

// DonkStorage
public struct StorageConfiguration: Sendable { public var appGroupIdentifiers: [String] = []; public var userDefaultsSuites: [String] = []; public init() }
public enum DonkStorage {
    public static func configure(_ configuration: StorageConfiguration)
    @MainActor public static func makeRootView() -> AnyView
}

// Donk (umbrella)
public struct DonkConfiguration: Sendable {
    public var network = NetworkCaptureConfiguration()
    public var captureWebViews = true
    public var performance = PerformanceConfiguration()
    public var push = PushConfiguration()
    public var storage = StorageConfiguration()
    public var showsBubble = true
    public var opensOnShake = true
    public var redaction: RedactionPolicy? = nil                      // non-nil: replaces NetworkSettings.redaction at start (persisted)
    public var tools: Set<DonkTool> = Set(DonkTool.allCases)          // disabled tools are neither started nor shown
    public init()
}
public enum Donk {
    public static func start(_ configuration: DonkConfiguration = .init())
    public static func stop()
    public static func installCrashReporter()                         // forwards to DonkCrash.install()
    @MainActor public static func show()
    @MainActor public static func hide()
    @MainActor public static func toggle()
}

// Donk (umbrella) — extra API beyond the binding contract
public enum DonkTool: String, CaseIterable, Sendable { case network, rules, performance, inspector, push, storage, crashes, settings }
extension Donk {
    public static let version: String                                 // DonkEnvironment.version
    public static var isRunning: Bool { get }
    @MainActor public static func show(_ tool: DonkTool)              // opens the debugger at a tool (deep link)
    @MainActor public static func showQuickActions()                  // opens the bubble's quick-actions menu
}
```

Umbrella hosting rules (what feature modules can rely on):

- `makeRootView()` of every module is pushed onto the debugger's navigation stack (a `DonkNavigationContainer` owned by the umbrella), so a root view must not embed its own navigation container; `donkNavigationTitle`, `.toolbar` and `NavigationLink` work as usual.
- `DonkNetworkUI.makeBreakpointView(_:)` is presented by the umbrella as a page sheet wrapped in a `DonkNavigationContainer` (toolbar items work, the view must not embed its own container). The sheet is dismissed automatically when the exchange leaves `BreakpointCenter.pending`; queued exchanges are shown one after another.
- `Donk.start` is safe from `didFinishLaunching` on any thread: capture layers start synchronously, UI pieces (bubble, shake, breakpoint observer) hop to main. `show`/`showQuickActions` called before a scene is active are deferred until one activates.
- Inspector modes started from the bubble menu or the home quick toggles hide the debugger first; the umbrella also hides the debugger when `DonkInspector.activeMode` changes while it is open.
- Launcher preferences, `NetworkStore.isCaptureEnabled` and the breakpoint auto-resume timeout are persisted by the umbrella in `preferences.json`; network limits, host lists and the export redaction policy live in `NetworkSettingsStore`.
- `DonkEngine.start` calls `DonkEnvironment.setActive(true)` once capture layers run, and `stop` calls `setActive(false)` first. `BreakpointCoordinator` sets `BreakpointCenter.shared.hasPresenter` on start/stop. `DebuggerPresenter` reports show/hide through `DonkEnvironment.setDebuggerVisible`. `DonkRuntime` installs `DonkEnvironment.hideDebuggerHandler` (hide without animation) on start and clears it on stop.
- `DonkConfiguration.tools` (default: every `DonkTool`) gates tools. A disabled tool is not started and not shown: without `.performance` `DonkPerformance.start` is not called and the FPS HUD toggle/quick action disappear; without `.push` `DonkPush.start` is not called; without `.storage` `DonkStorage.configure` is skipped and the Storage tile is hidden; without `.inspector` the UI Inspector tile, the home quick toggles and the bubble's inspector actions are hidden; without `.crashes` the Crashes tile is hidden (installing the reporter stays a separate `Donk.installCrashReporter()` call); without `.network`/`.rules`/`.settings` the matching tile, banner or row is hidden. Network capture itself is controlled by `network.isEnabled`, not by `.network`. `Donk.show(_:)` for a disabled tool stays on Home and logs a notice. `Donk.stop()` stops what `start` started (capture, web views, performance, push).
- Every `DonkTool` is reachable through `Donk.show(_:)` at any time: Home keeps a hidden navigation link per enabled tool, independent of banners (for example `.rules` opens with zero active rules). A route to a tool that cannot be shown is cleared instead of being kept for later.
- The debugger window (`DonkKeyWindow`) is shown visible but **not key**, so host code that finds "the key window" (`topMostViewController()`, loader overlays, push routing) keeps targeting the app window while donk is open; host presentations land under donk and are visible once it closes. The window becomes key only while one of its text inputs is editing and hands key status back to the app window when editing ends, the keyboard hides, and on hide. Ordinary taps (buttons, toggles, lists) never make it key, not even briefly: `canBecomeKey` is true only right after a touch lands on a text field, text view or search bar, or while one is editing. Opening donk ends editing in the app window so the host keyboard does not cover donk.
- On hide, controllers presented on the debugger window that donk did not create (not registered through `DonkWindowManager.markDonkPresentation` and not of a Donk*/SwiftUI type) are logged (`os.Logger`, subsystem `dev.donk`, category `debugger`) and dismissed before the window hides, instead of vanishing with it.
- The scene used for donk windows prefers the scene whose bubble was tapped (or that was shaken), then the key window's scene, then the first foreground-active scene (`DonkWindowManager.activeWindowScene`).
- The umbrella re-exports DonkCore, DonkJSON and the feature modules, but not DonkUI (its generically named types would leak into hosts). Code that uses DonkUI types imports `DonkUI` explicitly.

## DonkGRPC (sub-package, binding)

```swift
public struct DonkGRPCOptions: Sendable {
    public var preserveProtoFieldNames, alwaysPrintEnumsAsInts, isRulesEnabled: Bool
    public var anyTypeRegistry: [any SwiftProtobuf.Message.Type]
    public var maxRenderedMessageSize: Int                            // 1 MB: larger messages are not rendered to JSON
    public var maxRawMessageSize: Int                                 // 64 KB: raw bytes kept per message
    public var maxRenderBacklogMessages: Int                          // 256: queued renders per call before placeholders
    public var maxRenderBacklogBytes: Int                             // 4 MB: queued bytes per call before placeholders
    public var bypassHosts: [String]
    public var store: NetworkStore
    public var ruleStore: RuleStore                                   // RuleStore(fileName:directory:) is public for test seams
    public var breakpointCenter: BreakpointCenter
    public var settingsStore: NetworkSettingsStore?                   // bypass hosts from settings; nil to ignore
    public init(...)                                                  // all parameters defaulted to the shared instances; referencing them does no I/O
}
public enum DonkGRPC {
    public static func interceptors<Request, Response>(host: String?, options: DonkGRPCOptions = .init()) -> [ClientInterceptor<Request, Response>]
    public static func interceptors<Request, Response>(host: String?, options: DonkGRPCOptions = .init(), after existing: [ClientInterceptor<Request, Response>]) -> [ClientInterceptor<Request, Response>]
    public static func register(anyTypes: [any SwiftProtobuf.Message.Type])
}
public final class DonkClientInterceptor<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>: ClientInterceptor<Request, Response>
```

The interceptor decides per call, on its first outbound part. It passes the call through untouched (no entry, no rules, no breakpoints) when `DonkEnvironment.isActive` is false, capture is disabled, or the host is bypassed. The environment check goes through an internal `isEnvironmentActive` closure on the options, which tests override with `@testable import`.

Each message is serialized once on the event loop. JSON is decoded from those bytes on a per-call background queue with a bounded backlog. When the backlog is full, a placeholder records the real size and the note "rendering skipped (backlog)", so counts and byte totals stay exact.

How rules apply to streams:

- **Unary and server-streaming:**
  - A request breakpoint pauses on the message; headers and body are editable.
  - Map Local answers after the client sends `.end`.
- **Client-streaming and bidi:**
  - Metadata is forwarded immediately.
  - A request breakpoint pauses on the first message only, and header edits are ignored.
  - Respond or abort cancels the already-open server stream.
- **Map Local on bidi** answers after the first client message, or at `.end` if that comes first. Client-streaming still waits for `.end`.
- **Response breakpoints:**
  - On streams they pause on each received message, and only the body is editable. An empty body drops the message; a JSON array splits it into several.
  - Unary and client-streaming responses pause once, at the end.
- **No presenter:** breakpoints are skipped when `BreakpointCenter.hasPresenter` is false.

## Window levels (DonkUI `DonkWindowLevel`)

| Window | Level | Key? | Touches |
|---|---|---|---|
| inspector overlay | `.alert + 100` | no | captures when a mode needs taps |
| FPS HUD | `.alert + 200` | no | only the pill |
| bubble | `.alert + 300` | no | only the bubble |
| debugger | `.alert + 400` | only while a donk text input is editing | all |
| toast | `.alert + 500` | no | only the toast |

One window per active `UIWindowScene` (`DonkWindowManager` in DonkUI tracks scenes).

## HTTP capture design (DonkNetwork)

- `DonkURLProtocol` (URLProtocol subclass). Injected by swizzling `+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]` (prepend to `configuration.protocolClasses` on a copy) and `URLProtocol.registerClass` (covers `URLSession.shared`). Background configurations (`identifier != nil`) untouched.
- `canInit(with:)`: false when capture disabled, scheme not http/https, request marked internal or already handled (`URLProtocol.property` marker), host in bypass list, `Upgrade: websocket`.
- `startLoading`: records entry, reads `httpBodyStream` fully before re-issuing, resolves rules: mapLocal → answer locally (respect delay with `asyncAfter`, never block threads); breakpoint(request) → `await BreakpointCenter.pause`; rewrite(request) → patch. Re-issues via an inner session that mirrors the outer session's configuration (one context and runtime protocol subclass per outer session or injected configuration, looked up with `object_getClass(self)`; request marked handled). The inner `willCacheResponse` is forwarded to the outer task/session delegate on its delegate queue, so cache vetoes are honored. Streams chunks to `client` immediately (SSE works), accumulates body up to limit.
- Auth challenges from the inner session are forwarded to the outer task delegate: wrap with `URLAuthenticationChallenge(authenticationChallenge:sender:)` where `sender` is the protocol (implements `URLAuthenticationChallengeSender`), call `client?.urlProtocol(self, didReceive:)`. Outer session delegate (e.g., Alamofire `ServerTrustManager` / SPKI pinning) decides; sender callbacks complete the inner handler. This keeps certificate pinning working.
- Redirects: when the outer delegate handles redirects, `wasRedirectedTo`, the 3xx response, its body and the finish are delivered in one block (measured clean under slow and jittered decisions). Otherwise only `wasRedirectedTo` is sent and everything else is held until `stopLoading`, with a 5 s safety release.
- Uploads: upload tasks and requests with a streamed body pass through natively (progress callbacks keep working) unless an active rule matches them, so their bodies are captured only when a rule targets them.
- All `client` calls are performed on the thread that called `startLoading` (store `Thread.current` + run loop modes, use `perform(_:on:with:waitUntilDone:modes:)`).
- Metrics from the inner task → `TransactionMetrics`.
- Response breakpoints/rewrite need the full body: buffer instead of streaming only when a response-phase rule matches.

## UI design language (DonkUI)

Native, calm, dense, Proxyman-like clarity with Pulse-level polish.

- Palette (dynamic light/dark): accent `#6D5DFC`/`#8B7FFF`; success `#16A34A`/`#22C55E`; warning `#D97706`/`#F59E0B`; error `#DC2626`/`#F87171`; info `#2563EB`/`#60A5FA`; grpc `#9333EA`/`#C084FC`; web `#0D9488`/`#2DD4BF`; backgrounds = system grouped backgrounds.
- Method colors: GET info, POST success, PUT warning, PATCH `#CA8A04`/`#FACC15`, DELETE error, other secondary.
- Code syntax colors: keys `#7C3AED`/`#C4B5FD`, strings `#059669`/`#6EE7B7`, numbers `#2563EB`/`#93C5FD`, bool/null `#DB2777`/`#F9A8D4`, punctuation secondary label.
- Typography: system; headings `.rounded`; code `.system(.footnote, design: .monospaced)`. Dynamic Type friendly.
- Shapes: cards radius 16 (continuous), badges radius 6, pills capsule. Spacing 4/8/12/16/20/24.
- Motion & feedback: springs, light haptic on copy/toggle, toast "Copied".
- Patterns: status-colored rows, method badges, live state indicators (pulsing dot for pending/streaming), segmented detail tabs, collapsible JSON tree with search highlight, copy everywhere (context menus), share sheet, empty states with SF Symbol + hint, swipe actions, "Modified" pill for mocked/rewritten entries, global banner while rules are active.
