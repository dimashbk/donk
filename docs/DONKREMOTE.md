# DonkRemote — agent bridge contract

DonkRemote lets coding agents (Claude Code and any other MCP client) read what donk captures in a running app. Several agents can work with the same app at the same time.

```
iOS app (DonkRemote) ──WebSocket /app──▶ donk-hub (Mac, mcp/) ◀──MCP Streamable HTTP /mcp── agent sessions
```

- The app is the WebSocket client. It dials the hub, so nothing listens on the device.
- The hub is one long-running process on the developer's Mac. Every MCP session sees the same registry of connected apps; this shared state is what later phases (issue board, claims, comments) build on.
- Phase 1 (this document) is read-only: network, crashes, UI tree, screenshot, app info. Nothing an agent does in phase 1 can change app behavior.

## Transport

- Hub listens on `127.0.0.1:7337` only (`--port` / `DONK_HUB_PORT` override the port). `ws://127.0.0.1:7337/app` for apps, `http://127.0.0.1:7337/mcp` for MCP clients.
- Simulator apps reach the hub at `127.0.0.1`. Devices are out of scope for phase 1.
- WebSocket text frames, one JSON-RPC 2.0 message per frame, UTF-8. Max frame 16 MB.
- The app uses Network.framework (`NWConnection` + `NWProtocolWebSocket`), not URLSession: no ATS exception needed, and DonkNetwork never sees the traffic.
- Keepalive: the hub sends a WebSocket ping every 20 s and drops an app that misses two. The app sets `autoReplyPing` on its `NWProtocolWebSocket.Options` (Network.framework does not answer pings by default). The app reconnects with backoff 1, 2, 4, 8, 16, 30, 30… s (reset after a successful `welcome`), and stops on `DonkRemote.stop()` / `Donk.stop()`, which sends a 1000 close frame.

## Handshake

The first frame from the app is the `hello` notification:

```json
{"jsonrpc": "2.0", "method": "hello", "params": {
  "protocol": 1,
  "session": "6F1C…",
  "donkVersion": "0.2.3",
  "app": {"name": "Freedom Business", "bundleID": "kz.globerce.fb", "version": "1.17.0", "build": "1234", "osVersion": "26.0", "deviceModel": "iPhone17,1"},
  "device": {"name": "iPhone 17 Pro", "isSimulator": true, "simulatorUDID": "39C8B439-…"},
  "capabilities": ["network", "crashes", "ui"]
}}
```

- `session`: a UUID created per `DonkRemote.start`; it stays the same across reconnects of one launch.
- `simulatorUDID`: `ProcessInfo.processInfo.environment["SIMULATOR_UDID"]`, omitted on devices. Agents use it to pair donk data with simulator control tools.
- `capabilities`: `crashes` only when DonkCrash is installed, `ui` only when a foreground scene exists at connect time (the method still answers later).

The hub answers with a `welcome` notification `{"protocol": 1, "hub": "<hub version>"}`. Without a `welcome` within 10 s the app drops the connection and retries with the backoff above. A hub that does not support the app's `protocol` sends `{"jsonrpc":"2.0","method":"rejected","params":{"reason":"…"}}` and closes with code 4000; the app then stops retrying until the next start. A second `hello` with an already connected `session` replaces the old connection.

## Requests (hub → app)

JSON-RPC requests with string ids. The app answers every request exactly once. The hub times out after 15 s.

Errors:

| code | meaning |
|---|---|
| -32600 / -32601 / -32602 | JSON-RPC standard: invalid request / unknown method / invalid params |
| -32000 | not found (entry, report) |
| -32001 | unavailable (tool not running, no foreground scene, snapshot failed, result larger than the 16 MB frame limit) |
| -32002 | ambiguous id prefix |

Common shapes:

- Dates: ISO 8601 UTC with milliseconds, `"2026-10-22T09:41:05.123Z"`. Durations: `durationMs` (number, may be fractional).
- Ids: full uppercase UUID strings in results. Every `id` parameter (and `before`) accepts the full id or a unique prefix of at least 8 hex characters (case-insensitive, hyphens ignored). A shorter or non-hex prefix is -32602, no match is -32000.
- Headers: `[{"name": "…", "value": "…"}]`, original order.
- Frames: `{"x","y","width","height"}` in points, in the coordinate space of the scene's screen (what simulator tap tools use).

### Redaction

Everything that leaves the app goes through `RedactionPolicy` (DonkCore): entries are redacted with `redact(_ entry:)` before any field is read, cURL/grpcurl use the same policy. The policy is `RemoteConfiguration.redaction` when set, else `NetworkSettingsStore.shared.settings.redaction`, regardless of `redactsExports`. `RemoteConfiguration.redacts = false` turns it off (local experiments only).

### `app.info`

Params: none. Result:

```json
{"app": {…as in hello…}, "device": {…}, "donkVersion": "0.2.3", "session": "…", "uptimeSec": 812.4,
 "network": {"captureEnabled": true, "entries": 214, "totalBytes": 5120000, "limit": 1000},
 "rules": {"enabled": true, "active": 2},
 "crashes": {"installed": true, "reports": 3}}
```

`crashes` is omitted when DonkCrash is not linked into the build.

### `network.list`

Params (all optional):

```json
{"query": "accounts 500", "kinds": ["http", "grpc", "webView"], "hosts": ["api.example.com"],
 "status": ["pending", "success", "redirect", "clientError", "serverError", "failure"],
 "onlyModified": false, "onlyPinned": false, "limit": 50, "before": "<id>"}
```

- Maps onto `NetworkFilter` + `NetworkSearch.apply` with `hiddenHosts: []` (agents see hidden hosts too).
- `limit`: default 50, clamped to 1…500. Newest first. `before`: return only entries older than that entry (cursor from `nextBefore`); the cursor entry itself need not match the filter.
- `query` is matched against the redacted entries, so a redacted secret never matches.

Result:

```json
{"total": 214, "entries": [Summary], "nextBefore": "<id or absent>"}
```

`total` counts all entries matching the filter, not just the page. Summary:

```json
{"id": "…", "kind": "grpc", "state": "completed", "origin": "network",
 "method": "UNARY", "title": "AccountService/GetAccount", "url": "grpc://api.example.com/bank.v1.AccountService/GetAccount",
 "host": "api.example.com", "status": "UNAVAILABLE", "statusCategory": "serverError",
 "startedAt": "…", "durationMs": 341.2, "requestSize": 120, "responseSize": 0,
 "error": "connection reset", "pinned": false,
 "grpc": {"service": "bank.v1.AccountService", "method": "GetAccount", "statusCode": 14, "statusName": "UNAVAILABLE", "statusMessage": "…", "messages": 2}}
```

- `method` = `NetworkEntry.methodLabel`, `status` = `statusLabel`, `title` = `title` (HTTP: path; gRPC: last service component + method), `url` redacted. `grpc.messages` = `sentMessageCount + receivedMessageCount`.
- `origin`: `network` | `mocked` | `rewritten` | `breakpoint`; `rule` (string) is added for mocked/rewritten.
- `error` = `NetworkErrorInfo.message`, absent when nil. `durationMs` absent while in flight. `grpc` only for gRPC entries.

### `network.get`

Params: `{"id": "…", "maxBodyBytes": 65536, "maxMessages": 50}`. `maxBodyBytes` default 64 KB, clamped to 1 KB…1 MB, applies to each body and each gRPC message text. `maxMessages` default 50, clamped to 0…1000, keeps the newest messages.

Result: `{"entry": Detail}`. Detail = every Summary field plus:

```json
{"request": {"url": "…", "method": "POST", "headers": [...], "body": Body},
 "response": {"statusCode": 200, "headers": [...], "body": Body},
 "errorInfo": {"domain": "NSURLErrorDomain", "code": -1005, "message": "…"},
 "timing": {"startedAt": "…", "responseStartedAt": "…", "endedAt": "…", "durationMs": 341.2,
            "protocol": "h2", "remoteAddress": "1.2.3.4", "reusedConnection": true},
 "grpc": {…summary fields…, "path": "/bank.v1.AccountService/GetAccount", "callType": "unary", "timeoutSec": 30,
          "requestMetadata": [...], "responseHeaders": [...], "trailers": [...],
          "sentMessageCount": 1, "receivedMessageCount": 1, "droppedMessageCount": 0,
          "messages": [{"direction": "sent", "timestamp": "…", "typeName": "bank.v1.GetAccountRequest", "size": 12, "json": "{…}"}]},
 "web": {"pageURL": "…", "initiator": "fetch", "captureLevel": "full"},
 "curl": "curl …", "grpcurl": "grpcurl …"}
```

- In Detail, `grpc.messages` is the message array (the newest `maxMessages`), not the summary count; the count is `sentMessageCount + receivedMessageCount`.
- `response`, `errorInfo`, `grpc`, `web` absent when nil. `timing.protocol`/`remoteAddress`/`reusedConnection` come from the last `TransactionMetrics`, absent when there is none.
- `curl` for HTTP/webView entries (`CurlExporter`), `grpcurl` for gRPC (`GRPCurlExporter`), both with the redaction policy.
- Body:

```json
{"contentType": "application/json", "size": 2048, "truncated": false, "encoding": "text", "text": "{\n  …pretty…\n}"}
```

  `size` = `originalSize`. `encoding`: `text` (pretty JSON when the body is JSON, else UTF-8 text) or `binary` (no `text`; images report `"image": true`). `truncated` is true when donk truncated the capture or `maxBodyBytes` cut the text (cut on a scalar boundary).
- gRPC message `json` is cut the same way (the message then has `"truncated": true`); when it has no JSON, `textFormat` is sent instead; raw bytes are never sent.

### `crashes.list`

Params: `{"limit": 20}` (1…200). Newest first. Result:

```json
{"reports": [{"id": "…", "date": "…", "kind": "signal", "title": "EXC_BAD_ACCESS (SIGSEGV)", "reason": "…", "appVersion": "1.17.0", "appBuild": "1234", "osVersion": "26.0"}]}
```

`title`/`reason` are the same strings the DonkCrash list rows show. Error -32001 when DonkCrash is not installed.

### `crashes.get`

Params: `{"id": "…"}`. Result: `{"report": {…list fields…, "text": "<full report as DonkCrash's text export>"}}`.

### `ui.tree`

Params: `{"maxDepth": 40, "includeHidden": false, "maxNodes": 3000}` (`maxDepth` 0…256, `maxNodes` 1…20000). Runs on the main actor against the foreground-active scene (`DonkWindowManager.activeWindowScene` rules).

Result:

```json
{"screen": {"width": 402, "height": 874, "scale": 3},
 "topViewController": "AccountsViewController",
 "controllers": ControllerNode,
 "windows": [{"class": "UIWindow", "frame": {…}, "level": 0, "isKey": true, "root": Node}],
 "nodeCount": 812, "truncated": false}
```

- `windows`: the scene's windows back to front, excluding donk's own windows (class prefix `Donk`, or level ≥ `DonkWindowLevel.inspector`), hidden windows and windows with alpha 0. `root` is the node of the window itself (depth 0). Frame values are rounded to 0.01 pt.
- Node:

```json
{"class": "UIButton", "frame": {…}, "id": "login.button", "label": "Войти", "text": "Войти",
 "value": "…", "traits": ["button"], "interactive": true, "hidden": false, "alpha": 1,
 "viewController": "LoginViewController", "children": [Node]}
```

  `id` = `accessibilityIdentifier`, `label` = `accessibilityLabel`, `value` = `accessibilityValue`, `text` = UILabel text, UIButton current title, UITextField/UITextView text (secure entry → `"••••"`; empty text → placeholder with `"placeholder": true`). Empty/nil fields are omitted. `class` is the module-free class name (same naming as the inspector). `viewController` is set on a controller's root view. `interactive` = user interaction enabled and the view is a UIControl or has an enabled gesture recognizer.
- Hidden views (`isHidden`, alpha < 0.01) and their subtrees are skipped unless `includeHidden`. Depth beyond `maxDepth` is cut (the node gets `"childrenOmitted": n`). Traversal stops at `maxNodes` with `truncated: true`.
- UIKit vends its default accessibility values (a label's `accessibilityLabel`, a button's `button` trait) only while the accessibility runtime is on (VoiceOver, Accessibility Inspector and similar clients). Phase 1 does not turn it on, so `label`, `value` and `traits` show explicitly set values otherwise; `text`, `interactive` and `class` are read from the views directly. `label`, `text` and `value` longer than 4 KB are cut and end with `…`.
- SwiftUI: hosting views expose what UIKit exposes (`accessibilityElements` with frames, labels, identifiers, traits) as children with `"class": "AXElement"`; no private API in phase 1.
- ControllerNode: `{"class": "UINavigationController", "title": "…", "children": [ControllerNode], "presented": ControllerNode}` from the key app window's root controller.

### `ui.screenshot`

Params: `{"scale": 1, "format": "jpeg", "quality": 0.7}`. `scale`: pixels per point, clamped to 0.25…3 (default 1). `format`: `jpeg` | `png` (anything else is -32602). `quality`: JPEG quality, clamped to 0…1.

Result: `{"mimeType": "image/jpeg", "width": 402, "height": 874, "data": "<base64>"}` (`width`/`height` in pixels). The image is the composite of the app windows of the scene (donk windows excluded) as the inspector snapshot draws them, so secure containers render like the inspector shows them.

## Hub → MCP

The hub exposes MCP tools over Streamable HTTP with stateful sessions; any number of MCP sessions run concurrently against the same app registry.

Every tool except `donk_apps` takes an optional `app` argument: a `session` (or 8+ char prefix), a `bundleID`, or a `simulatorUDID`. When omitted and exactly one app is connected, that app is used; otherwise the tool returns an error that lists the connected apps.

| tool | app method | output |
|---|---|---|
| `donk_apps` | `app.info` per app | connected apps (session prefix, app, version/build, device, simulator UDID, connectedAt) and their capture stats |
| `donk_network_list` | `network.list` | one line per entry: `<id8> <HH:mm:ss.SSS> <METHOD> <status> <duration> <title> <host>`, then `total` and the `before` cursor |
| `donk_network_get` | `network.get` | readable request/response text (headers, bodies, gRPC timeline, cURL/grpcurl) |
| `donk_crash_list` | `crashes.list` | one line per report |
| `donk_crash_get` | `crashes.get` | full report text |
| `donk_ui_tree` | `ui.tree` | indented tree, one node per line: `UIButton "Войти" #login.button (16,620 343×52) [tap]`; optional `match` argument keeps only the branches leading to nodes whose class/id/label/text contains it |
| `donk_screenshot` | `ui.screenshot` | MCP image content |

Tool results are text (plus image content for screenshots); errors from the app are returned as MCP tool errors with the app's message. The server `instructions` tell agents to start with `donk_apps`, that data is redacted, that phase 1 is read-only, and that `simulatorUDID` pairs with simulator control tools.

## Swift API (DonkRemote target)

```swift
public struct RemoteConfiguration: Sendable {
    public var isEnabled = false
    public var hubURL = URL(string: "ws://127.0.0.1:7337/app")!
    public var redacts = true
    public var redaction: RedactionPolicy? = nil
    public init()
}
public enum RemoteStatus: Equatable, Sendable { case stopped, connecting, connected, rejected(String) }
public enum DonkRemote {
    public static func start(_ configuration: RemoteConfiguration)
    public static func stop()
    public static var status: RemoteStatus { get }
    public static var statusChanges: AnyPublisher<RemoteStatus, Never> { get }
}
```

`start` does nothing when `isEnabled` is false; a second `start` replaces the running connection and creates a new `session`. `statusChanges` emits the current status first. `status` is `connecting` while dialing, waiting for `welcome` or backing off, and stays `rejected(reason)` until the next `start`.

The umbrella adds `DonkConfiguration.remote = RemoteConfiguration()`; `Donk.start` calls `DonkRemote.start` only when `remote.isEnabled`, `Donk.stop` stops it. Settings shows an "Agent bridge" row with the hub address and status while it is enabled. Hosts enable it only in debug builds.

## Later phases (not in phase 1)

- Phase 2 — control: rules (Map Local / Rewrite) created by agents and marked as such in the UI, breakpoints with the hub as a presenter, UserDefaults/files, push simulation, log capture.
- Phase 3 — collaboration: issue board in the hub (`issues_list/claim/comment/resolve`), "Send to agent" in donk (screenshot + UI tree + recent entries + note) as an app → hub request, agent comments shown in donk, devices over LAN with pairing.
