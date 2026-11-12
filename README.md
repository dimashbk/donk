# donk

**An in-app debugger for iOS.** Network traffic (HTTP, gRPC, WebView) with Proxyman-style rules and breakpoints, a UI inspector, push simulation, a file / UserDefaults / Keychain browser, performance monitoring and crash reports — all inside your app, in native SwiftUI.

![iOS 15+](https://img.shields.io/badge/iOS-15%2B-blue) ![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange) ![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home.png" width="260" alt="donk home screen"><br><sub>Home: every tool one tap away</sub></td>
    <td align="center"><img src="docs/screenshots/network-list.png" width="260" alt="Network log with gRPC and HTTP entries"><br><sub>HTTP, gRPC and WebView in one log</sub></td>
    <td align="center"><img src="docs/screenshots/inspector-select.png" width="260" alt="UI inspector selecting a button"><br><sub>Inspect and measure any view</sub></td>
  </tr>
</table>

- **iOS 15+**, Swift 5.9+ (Xcode 15+), SPM.
- No resources. `Donk` itself has no third-party code; the package declares grpc-swift, swift-protobuf and swift-nio only for the optional `DonkGRPC` product.
- Opens from a floating bubble, by shaking the device, or with `Donk.show()`.
- Nothing runs until you call `Donk.start` (see [Shipping](#shipping)).

**Contents:** [Features](#features) · [Agent bridge](#agent-bridge-mcp) · [Installation](#installation) · [Quick start](#quick-start) · [Configuration](#configuration) · [Shipping](#shipping) · [Example app](#example-app) · [Requirements](#requirements) · [License](#license)

## Features

| Area | What you get |
|---|---|
| [**Launcher**](#launcher-and-home) | Floating bubble (tap to open, long-press for quick actions), shake to open, `Donk.show()` / `Donk.show(.network)` from code. |
| [**HTTP**](#http) | Every `URLSession` request with full headers, bodies and real `URLSessionTaskMetrics`. Search, filters, cURL / HAR / text export, repeat request. |
| [**gRPC**](#grpc) | grpc-swift 1.x interceptor. One live record per RPC with a message timeline for streams, metadata, trailers and status. |
| [**WebView**](#webview) | fetch / XHR / beacon, document navigations, sub-resources and WebSocket / EventSource connections. |
| [**Rules & breakpoints**](#rules-map-local-rewrite-breakpoints) | Map Local, Rewrite and Breakpoints for HTTP and gRPC. |
| [**UI inspector**](#ui-inspector) | Select, measure, frames, grid and an eyedropper. |
| [**Performance**](#performance) | CPU, memory, FPS, hitches, hangs with stack traces, thermal state, FPS HUD. |
| [**Push**](#push) | Simulate a backend push with the exact payload; history and templates. |
| [**Storage**](#storage) | Sandbox and App Group files, UserDefaults, Keychain, cookies. |
| [**Crashes**](#crashes) | Crashlytics-compatible signal / NSException handlers, symbolicated reports, MetricKit. |
| [**Agents**](#agent-bridge-mcp) | Opt-in MCP bridge: Claude Code or any MCP client reads network entries, crash reports, the UI tree and screenshots of a running simulator app. Read-only, redacted before anything leaves the app. |

### Launcher and home

Tap the bubble to open donk, long-press it for quick actions (inspector modes, FPS HUD, clear the network log, hide the bubble). The bubble counts captured requests and flashes green, orange or red as requests finish. Home shows app and device info, the "rules active" banner, a tile per tool with live counters, and quick toggles.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/quick-actions.png" width="260" alt="Bubble quick actions menu"><br><sub>Bubble quick actions</sub></td>
    <td align="center"><img src="docs/screenshots/home.png" width="260" alt="Home dashboard"><br><sub>Home dashboard</sub></td>
    <td align="center"><img src="docs/screenshots/settings.png" width="260" alt="Settings"><br><sub>Settings: launcher, capture limits, hosts, redaction</sub></td>
  </tr>
</table>

### HTTP

Every `URLSession` request: Alamofire, `URLSession.shared`, completion handlers, async/await, uploads, SSE streaming. Full request/response with headers, bodies and real `URLSessionTaskMetrics` (protocol, TLS, timings). Search across any field, host filter, hidden hosts, cURL / HAR / text export, repeat request. Certificate pinning keeps working: auth challenges are forwarded to your session delegate.

Bodies open as a JSON tree, pretty text or raw, with find-in-body. The list is color-coded by status, and entries changed by a rule are tagged **Mocked**, **Rewritten** or **Edited**. **Select** in the list lets you tick specific requests and export only those as HAR or text.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/network-statuses.png" width="260" alt="Network list with status colors"><br><sub>Status colors, methods, sizes, durations</sub></td>
    <td align="center"><img src="docs/screenshots/http-body-search.png" width="260" alt="JSON body tree with search highlight"><br><sub>JSON tree with find-in-body</sub></td>
    <td align="center"><img src="docs/screenshots/http-timing.png" width="260" alt="Timing waterfall"><br><sub>Timing waterfall from real metrics</sub></td>
  </tr>
</table>

<details>
<summary>More HTTP screenshots</summary>
<br>
<table>
  <tr>
    <td align="center"><img src="docs/screenshots/http-overview.png" width="260" alt="Request overview"><br><sub>Overview: protocol, TLS, connection</sub></td>
    <td align="center"><img src="docs/screenshots/http-export.png" width="260" alt="Export menu"><br><sub>cURL / text / HAR export, redacted by default</sub></td>
    <td align="center"><img src="docs/screenshots/network-list-dark.png" width="260" alt="Network list in dark mode"><br><sub>Dark mode</sub></td>
  </tr>
</table>
</details>

### gRPC

`DonkClientInterceptor` for grpc-swift 1.x. One live record per RPC with a message timeline for streams, metadata, trailers and status. Protobuf is rendered as JSON (text format as fallback). Exports a `grpcurl` command. Unary, client-, server- and bidirectional streaming calls are all supported.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/grpc-timeline.png" width="260" alt="gRPC bidi stream message timeline"><br><sub>Message timeline of a bidi stream</sub></td>
    <td align="center"><img src="docs/screenshots/grpc-overview.png" width="260" alt="gRPC call overview"><br><sub>Call overview: status, service, method</sub></td>
    <td align="center"><img src="docs/screenshots/network-list.png" width="260" alt="gRPC calls in the network log"><br><sub>Live streams and gRPC status codes</sub></td>
  </tr>
</table>

### WebView

fetch/XHR/beacon with bodies, document navigations (status, headers), sub-resources via PerformanceObserver, WebSocket/EventSource connections. Each entry shows how much could be captured. An optional `isInspectable` toggle enables Safari Web Inspector.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/network-webview-modified.png" width="260" alt="WebView entries in the network log"><br><sub>WebView document, resource, fetch and XHR entries</sub></td>
  </tr>
</table>

### Rules: Map Local, Rewrite, Breakpoints

Rules in the style of Proxyman: **Map Local**, **Rewrite** (request/response: URL, method, headers, body, find/replace, status) and **Breakpoints** (pause a request or response, edit it, then continue, abort or answer locally). They work for HTTP and gRPC. Patterns match by *contains*, *wildcard* or *regex*, and the editor previews which recent requests a rule would hit. A banner on Home and in the network log shows when rules are active.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/rules-list.png" width="260" alt="Rules list"><br><sub>Rules, evaluated top to bottom</sub></td>
    <td align="center"><img src="docs/screenshots/rule-map-local.png" width="260" alt="Map Local rule editor"><br><sub>Map Local: status, delay, headers, body</sub></td>
    <td align="center"><img src="docs/screenshots/breakpoint-request.png" width="260" alt="Paused HTTP request at a breakpoint"><br><sub>Breakpoint: edit, continue, execute locally or abort</sub></td>
  </tr>
</table>

<details>
<summary>More rule screenshots</summary>
<br>
<table>
  <tr>
    <td align="center"><img src="docs/screenshots/rule-rewrite.png" width="260" alt="Rewrite rule editor"><br><sub>Rewrite request and/or response</sub></td>
    <td align="center"><img src="docs/screenshots/breakpoint-grpc-response.png" width="260" alt="Paused gRPC response"><br><sub>gRPC response breakpoint</sub></td>
  </tr>
</table>
</details>

### UI inspector

Tap a view to see its class, size, frame, font, colors, padding to the superview and the hierarchy. Measure the distance between two views. Show the frames of all views. An adjustable grid (cell width/height, columns). An eyedropper with a loupe that copies the HEX value. The app stays usable underneath: Frames and Grid pass touches through.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/inspector-select.png" width="260" alt="Select mode"><br><sub>Select: size and padding to the superview</sub></td>
    <td align="center"><img src="docs/screenshots/inspector-info-panel.png" width="260" alt="Expanded info panel"><br><sub>Info panel: layout, constraints, appearance</sub></td>
    <td align="center"><img src="docs/screenshots/inspector-measure.png" width="260" alt="Measuring between two views"><br><sub>Measure between two views</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/inspector-frames.png" width="260" alt="Frames overlay"><br><sub>Frames, colored by depth or kind</sub></td>
    <td align="center"><img src="docs/screenshots/inspector-grid.png" width="260" alt="Grid overlay"><br><sub>Adjustable layout grid</sub></td>
    <td align="center"><img src="docs/screenshots/inspector-eyedropper.png" width="260" alt="Eyedropper with loupe"><br><sub>Eyedropper with loupe and HEX</sub></td>
  </tr>
</table>

### Performance

CPU (total and per thread), memory footprint vs. the system limit, FPS and hitches, main-thread hangs with stack traces, thermal state. GPU time is experimental. Charts, alerts on abnormal activity, and an FPS HUD that stays above every screen.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/performance-cpu-memory.png" width="260" alt="CPU and memory charts"><br><sub>CPU and memory, live</sub></td>
    <td align="center"><img src="docs/screenshots/performance-events.png" width="260" alt="Performance events"><br><sub>Alerts and hangs</sub></td>
    <td align="center"><img src="docs/screenshots/fps-hud.png" width="260" alt="FPS HUD over the app"><br><sub>FPS HUD and alert toasts over the app</sub></td>
  </tr>
</table>

<details>
<summary>More performance screenshots</summary>
<br>
<table>
  <tr>
    <td align="center"><img src="docs/screenshots/performance-frames.png" width="260" alt="Frames and hitch charts"><br><sub>FPS, dropped frames and hitch ratio</sub></td>
    <td align="center"><img src="docs/screenshots/performance-hang.png" width="260" alt="Hang detail with main thread stack"><br><sub>Hang with the main-thread stack</sub></td>
  </tr>
</table>
</details>

### Push

Simulates a backend push with the exact payload (same `userInfo`, same keys, attachments downloaded like a Notification Service Extension would). Three delivery paths: system banner, direct delegate injection (foreground arrival or tap), and silent `didReceiveRemoteNotification`. Also `.apns` export, a history of real pushes, and templates.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/push-compose.png" width="260" alt="Push composer with preview"><br><sub>Composer with a live banner preview</sub></td>
    <td align="center"><img src="docs/screenshots/push-history.png" width="260" alt="Push history"><br><sub>History of received pushes</sub></td>
    <td align="center"><img src="docs/screenshots/push-templates.png" width="260" alt="Push templates"><br><sub>Built-in and app templates</sub></td>
  </tr>
</table>

### Storage

A sandbox and App Group file browser with previews (text, JSON, plist, images, SQLite, QuickLook, hex) and editing. A UserDefaults editor with typed values, a Keychain viewer/editor, and cookies.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/storage.png" width="260" alt="Storage overview"><br><sub>Files, UserDefaults suites, Keychain, cookies</sub></td>
    <td align="center"><img src="docs/screenshots/storage-files.png" width="260" alt="File browser"><br><sub>File browser</sub></td>
    <td align="center"><img src="docs/screenshots/storage-userdefaults.png" width="260" alt="UserDefaults editor"><br><sub>Typed UserDefaults editor</sub></td>
  </tr>
</table>

<details>
<summary>More storage screenshots</summary>
<br>
<table>
  <tr>
    <td align="center"><img src="docs/screenshots/storage-sqlite.png" width="260" alt="SQLite table rows"><br><sub>SQLite browser</sub></td>
    <td align="center"><img src="docs/screenshots/storage-keychain.png" width="260" alt="Keychain items"><br><sub>Keychain</sub></td>
  </tr>
</table>
</details>

### Crashes

Signal and NSException handlers that stay compatible with Firebase Crashlytics, symbolicated reports saved on the device, MetricKit diagnostics, unclean-exit detection. Reports can be shared as an Apple-style `.crash` text (works with `atos`) or as JSON.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/crashes-list.png" width="260" alt="Crash list"><br><sub>Signals, exceptions, unclean exits</sub></td>
    <td align="center"><img src="docs/screenshots/crash-report.png" width="260" alt="Crash report summary"><br><sub>Report summary and reason</sub></td>
    <td align="center"><img src="docs/screenshots/crash-backtrace.png" width="260" alt="Symbolicated backtrace"><br><sub>Symbolicated backtrace, app frames highlighted</sub></td>
  </tr>
</table>

### Dark mode

donk follows the system light/dark appearance.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home-dark.png" width="260" alt="Home in dark mode"></td>
    <td align="center"><img src="docs/screenshots/network-list-dark.png" width="260" alt="Network log in dark mode"></td>
  </tr>
</table>

## Agent bridge (MCP)

Coding agents can read what donk captures in a running app: network traffic, crash reports, the view tree with frames in screen points and screenshots. The app dials `donk-hub`, a small server on your Mac, over a WebSocket (Network.framework, so the traffic is never captured and needs no ATS exception). Agents connect to the hub over MCP, and several agent sessions can share one app.

```swift
#if DEBUG
configuration.remote.isEnabled = true          // dials ws://127.0.0.1:7337/app
#endif
```

```sh
cd mcp && npm install && npm run build && npm start
claude mcp add --transport http donk http://127.0.0.1:7337/mcp
```

Phase 1 is read-only and covers simulator apps. Everything goes through the redaction policy first: `configuration.remote.redaction`, or the policy from donk Settings when that is nil. While the bridge is enabled, donk Settings shows its hub address and connection status. The wire protocol is in [docs/DONKREMOTE.md](docs/DONKREMOTE.md), the hub and its tools in [mcp/README.md](mcp/README.md).

## Installation

```swift
.package(url: "https://github.com/dimashbk/donk.git", from: "0.3.0")
```

Products:

- **`Donk`:** everything.
- **`DonkCore`:** models, stores, rules and exporters, with no UI.
- **`DonkGRPC`:** the grpc-swift 1.x interceptor (grpc-swift `1.21.0..<2.0.0`, swift-protobuf `1.25+`).

SwiftPM resolves the grpc-swift dependencies for every consumer of the package, but only targets that link `DonkGRPC` build them.

If your app already links grpc-swift, add donk in the same place (the same `Package.swift` or the same Xcode project packages), so that SwiftPM resolves one grpc-swift. Link `Donk` and `DonkGRPC` into the image that already contains GRPC. That keeps one copy of GRPC and one of DonkCore. See [docs/DONKGRPC.md](docs/DONKGRPC.md).

### Integration notes

- `import Donk` re-exports DonkCore and the feature modules. The DonkUI design system is not re-exported: import `DonkUI` explicitly if you use its components.
- Performance monitoring has a constant cost while it runs:
  - a `CADisplayLink` on the main run loop (60 Hz, or up to 120 Hz if you opt in);
  - a watchdog that pings the main queue 10 times a second;
  - a sampler at 0.5–2 Hz.

  Leave `.performance` out of `DonkConfiguration.tools` if you don't need it.
- Link donk into exactly one image. If DonkCore ends up statically linked into two images (for example the app and a dynamic framework or an extension that both link donk), each copy keeps its own stores and swizzles, and the ObjC runtime logs `Class DonkCoreImageSentinel is implemented in both …` at launch. To fix it, link donk only from the app target, or turn the module that links donk into a dynamic framework that everything else shares.

## Quick start

```swift
import Donk

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        Donk.installCrashReporter()
        #endif
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        var configuration = DonkConfiguration()
        configuration.network.bypassHosts = ["*.crashlytics.com"]
        configuration.storage.appGroupIdentifiers = ["group.com.example.shared"]
        Donk.start(configuration)
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if DEBUG
        DonkPush.didRegister(deviceToken: deviceToken)
        #endif
    }
}
```

- Call `Donk.installCrashReporter()` before `FirebaseApp.configure()`. Crashlytics then keeps receiving every crash, and so does the system crash reporter.
- Call `Donk.start` as early as possible. Sessions created before it are captured only through `URLSession.shared`.
- `Donk.show()`, `Donk.show(.network)`, `Donk.hide()` and `Donk.toggle()` control the debugger in code.

### gRPC (grpc-swift 1.x)

```swift
import DonkGRPC

final class AccountInterceptors: Bank_V1_AccountServiceClientInterceptorFactoryProtocol {
    func makeGetAccountInterceptors() -> [ClientInterceptor<Bank_V1_GetAccountRequest, Bank_V1_Account>] {
        DonkGRPC.interceptors(host: "api.example.com:443", after: [AuthInterceptor()])
    }
}
```

The interceptor can't see `:authority`, so pass the host to the factory yourself. Create new interceptor instances for every call. If a message uses `google.protobuf.Any`, register its types with `DonkGRPC.register(anyTypes:)`. Until `Donk.start` runs (and after `Donk.stop`), the interceptor passes calls through untouched: nothing is recorded and no rules apply.

### WebView

Web views are captured automatically when `captureWebViews` is on: `-[WKWebView setNavigationDelegate:]` is always hooked, and the `WKWebView` initializers are hooked too. To attach yourself, call `DonkWebViewCapture.attach(to: configuration)` or `DonkWebViewCapture.attach(to: webView)`.

### Export redaction

cURL, grpcurl, text and HAR exports from the debugger are redacted by default. Values of `Authorization`, `Cookie`, `Set-Cookie`, API-key headers are replaced with `••••`, and so are values of JSON keys and query/form fields such as `password`, `token`, `otp`, `cvv`, `cardNumber` and `pan`. To set your own list:

```swift
configuration.redaction = RedactionPolicy(
    headers: RedactionPolicy.defaultHeaders + ["x-session-id"],
    keys: RedactionPolicy.defaultKeys + ["iban", "documentNumber"]
)
```

`RedactionPolicy.redact(_:)` and the `redaction:` overloads of `CurlExporter`, `GRPCurlExporter`, `EntryTextExporter` and `HARExporter` are public, so you can use them for your own exports. Binary bodies are exported as they are.

### Push

`DonkPush.contentProcessor` lets the Banner mode run your Notification Service Extension logic, if that logic lives in shared code:

```swift
DonkPush.contentProcessor = { content in await PushEnricher.process(content) }
```

Once a processor is set, donk no longer downloads the attachment itself. To keep the image, call `DonkPush.attachMedia(to:keyPaths:)` from your processor. It looks up the first attachment URL in `userInfo` (by default at `PushConfiguration.attachmentURLKeyPaths`), downloads it through an internal session that is never captured, and appends it to `attachments`. If no URL is found or the download fails, the content comes back unchanged.

```swift
DonkPush.contentProcessor = { content in
    content.title = content.userInfo["sender"] as? String ?? content.title
    content.body = "Sent you a photo"
    return await DonkPush.attachMedia(to: content)
}
```

## Configuration

Everything is set on `DonkConfiguration` before `Donk.start`:

| Property | Default | What it does |
|---|---|---|
| `network.isEnabled` | `true` | Turns HTTP capture on or off. |
| `network.bypassHosts` | `[]` | Hosts that are never intercepted (wildcards like `*.crashlytics.com`). |
| `captureWebViews` | `true` | Captures `WKWebView` traffic automatically. |
| `performance.alertsEnabled` | `true` | Enables alerts on abnormal activity (CPU, memory, hitches, hangs). |
| `push.templates` | `[]` | Your own push templates (`PushTemplate(id:name:payload:)`, payload is APNs JSON). |
| `push.attachmentURLKeyPaths` | `["fcm_options.image", "imageUrl", "image", "attachment-url", "media-url"]` | Where to look for an attachment URL in `userInfo`. |
| `push.recordsIncomingPushes` | `true` | Records real pushes into the history. |
| `storage.appGroupIdentifiers` | `[]` | App Group containers shown in the file browser. |
| `storage.userDefaultsSuites` | `[]` | Extra UserDefaults suites shown in the editor. |
| `showsBubble` | `true` | Shows the floating bubble. |
| `opensOnShake` | `true` | Toggles donk when the device is shaken. |
| `redaction` | `nil` | Replaces the export redaction policy (see [Export redaction](#export-redaction)). |
| `tools` | all `DonkTool` cases | Tools that are started and shown: `.network`, `.rules`, `.performance`, `.inspector`, `.push`, `.storage`, `.crashes`, `.settings`. A disabled tool is neither started nor shown. |

Launcher, capture limits (max body size, log limit), bypass and hidden hosts, redaction and the breakpoint auto-resume timeout can also be changed at runtime in donk's Settings screen.

## Shipping

Nothing runs until `Donk.start` or `Donk.installCrashReporter()` is called: there are no `+load` hooks, no static initializers and no swizzling at load time. Linking donk without calling it changes nothing at runtime. What matters is that no production code path calls `start`.

- Gate every call (`Donk.start`, `Donk.installCrashReporter()`, `DonkPush.didRegister`, …) behind your debug or staging flags: `#if DEBUG`, or a custom `DONK` compilation condition set only in internal configurations.
- The agent bridge is off by default. Turn on `configuration.remote.isEnabled` only in debug builds: it opens a WebSocket to the hub address and answers read-only requests from it.
- SPM links a package into every configuration of the target that depends on it. Tuist and XcodeGen hosts usually work this way, so the donk code is in your App Store binary even when it is never called. If that is unacceptable, depend on donk only from an internal-only target or app flavor.
- These are the private or undocumented APIs donk touches, and when each one runs:
  - **Inspector:** this exists only in builds where `DEBUG` or `DONK_PRIVATE_API` is defined, and only when "Include SwiftUI elements" is turned on (it is off by default). Select mode then switches on the SwiftUI accessibility runtime through `_AXSApplicationAccessibilitySetEnabled` (looked up with `dlsym` in libAccessibility) and restores it afterwards. See [Private API flag](#private-api-flag).
  - **Push:** the Inject and Tap delivery modes build `UNNotification` / `UNNotificationResponse` objects through key-value coding. Recording incoming pushes swizzles the `UNUserNotificationCenter` delegate setter and its delegate methods (`DonkPush.start`, `recordsIncomingPushes`).
  - **Hang and crash symbolication:** `swift_demangle` and `__cxa_demangle` are looked up with `dlsym` while a report is rendered.
  - **Swizzling (public runtime API):** `NSURLSession`/`URLProtocol` registration for capture, `WKWebView` init and `setNavigationDelegate:`, and `UIWindow.motionEnded` for shake. All of these are installed by `Donk.start` (or the module's `start`), never at load.

### Private API flag

Select mode can list SwiftUI accessibility elements. To do that, DonkInspector turns on the app's accessibility runtime with the private `_AXSApplicationAccessibilitySetEnabled`, which it looks up with `dlsym` in libAccessibility.

- **When it's compiled in:** the code and its strings are compiled only when `DEBUG` or `DONK_PRIVATE_API` is defined for DonkInspector. A Release build has no trace of it unless you opt in.
- **Without it:** the setting shows as unavailable, and Select works on UIViews only.
- **Even when compiled in:** "Include SwiftUI elements" is off by default. When you turn it on, the runtime is enabled only while Select is active and restored afterwards.
- **If the app is killed during Select:** a marker in `Library/Application Support/Donk` lets the runtime be restored. This happens on the next `Donk.start`, on the first Inspector use, or when you call `DonkInspector.restoreAccessibilityIfNeeded()`.
- **Assistive tech:** donk never turns the runtime off while VoiceOver or Switch Control is running.

To enable it in internal builds that aren't `DEBUG`:

- **Tuist:** `PackageSettings(targetSettings: ["DonkInspector": ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DONK_PRIVATE_API"]])`
- **xcodebuild:** pass `OTHER_SWIFT_FLAGS='$(inherited) -DDONK_PRIVATE_API'` on the command line or in an xcconfig. Build settings on your app target don't reach SPM package targets.
- **SwiftPM:** `swift build -Xswiftc -DDONK_PRIVATE_API`

### Required reason APIs

donk uses APIs that need a declared reason in the host app's `PrivacyInfo.xcprivacy` if they ship in a build you submit:

- **File timestamp APIs:** the DonkStorage file browser reads creation and modification dates (`NSPrivacyAccessedAPICategoryFileTimestamp`, for example reason `C617.1` or `3B52.1`).
- **System boot time APIs:** DonkPerformance and DonkNetwork read `ProcessInfo.systemUptime` for timings (`NSPrivacyAccessedAPICategorySystemBootTime`, reason `35F9.1`).
- **User defaults APIs:** the DonkStorage UserDefaults editor reads and writes `UserDefaults` (`NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`; add `1C8F.1` if you inspect App Group suites).

donk ships no privacy manifest of its own. Declare these reasons in your app's manifest, or leave donk out of the submitted binary.

## Example app

```bash
cd Example && xcodegen generate && open DonkDemo.xcodeproj
```

The demo has playgrounds for every module: real HTTP traffic, an in-app gRPC echo server, a WebView page, an inspector layout, CPU/memory/hang generators, crash triggers, push templates and storage seed data. The screenshots above were taken in it.

## Documentation

- [Architecture and module contracts](docs/ARCHITECTURE.md)
- [Design system (DonkUI)](docs/DONKUI.md)
- [Crash reporter internals](docs/DONKCRASH.md)
- [gRPC integration](docs/DONKGRPC.md)
- [Agent bridge protocol (DonkRemote)](docs/DONKREMOTE.md)

## Requirements

- iOS 15+
- Swift 5.9+ (Xcode 15+)
- Swift Package Manager
- `DonkGRPC` only: grpc-swift `1.21.0..<2.0.0` and swift-protobuf `1.25+`

## License

MIT
