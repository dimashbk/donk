# donk

An in-app debugger for iOS. It covers network traffic (HTTP, gRPC, WebView), UI inspection, push simulation, file and UserDefaults browsing, performance monitoring and crash reports. The UI is native SwiftUI.

- **iOS 15+**, Swift 5.9+ (Xcode 15+), SPM
- No resources and no third-party dependencies: the `Donk` package resolves nothing else. The gRPC interceptor is an optional sub-package.
- Opens from a floating bubble, by shaking the device, or with `Donk.show()`

## Features

| Area | What you get |
|---|---|
| **HTTP** | Every `URLSession` request: Alamofire, `URLSession.shared`, completion handlers, async/await, uploads, SSE streaming. Full request/response with headers, bodies and real `URLSessionTaskMetrics` (protocol, TLS, timings). Search across any field, host filter, hidden hosts, cURL / HAR / text export, repeat request. Certificate pinning keeps working: auth challenges are forwarded to your session delegate. |
| **gRPC** | `DonkClientInterceptor` for grpc-swift 1.x. One live record per RPC with a message timeline for streams, metadata, trailers and status. Protobuf is rendered as JSON (text format as fallback). Exports a `grpcurl` command. |
| **WebView** | fetch/XHR/beacon with bodies, document navigations (status, headers), sub-resources via PerformanceObserver, WebSocket/EventSource connections. Each entry shows how much could be captured. An optional `isInspectable` toggle enables Safari Web Inspector. |
| **Replace** | Rules in the style of Proxyman: Map Local, Rewrite (request/response: URL, method, headers, body, find/replace, status) and Breakpoints (pause a request or response, edit it, then continue, abort or answer locally). They work for HTTP and gRPC. |
| **UI inspector** | Tap a view to see its class, size, frame, font, colors, padding to the superview and the hierarchy. Measure the distance between two views. Show the frames of all views. An adjustable grid (cell width/height, columns). An eyedropper with a loupe that copies the HEX value. |
| **Push** | Simulates a backend push with the exact payload (same `userInfo`, same keys, attachments downloaded like a Notification Service Extension would). Three delivery paths: system banner, direct delegate injection (foreground arrival or tap), and silent `didReceiveRemoteNotification`. Also `.apns` export, a history of real pushes, and templates. |
| **Storage** | A sandbox and App Group file browser with previews (text, JSON, plist, images, SQLite, QuickLook, hex) and editing. A UserDefaults editor with typed values, a Keychain viewer/editor, and cookies. |
| **Performance** | CPU (total and per thread), memory footprint vs. the system limit, FPS and hitches, main-thread hangs with stack traces, thermal state. GPU time is experimental. Charts, alerts on abnormal activity, and an FPS HUD that stays above every screen. |
| **Crashes** | Signal and NSException handlers that stay compatible with Firebase Crashlytics, symbolicated reports saved on the device, MetricKit diagnostics, unclean-exit detection. Reports can be shared as an Apple-style `.crash` text (works with `atos`) or as JSON. |

## Installation

```swift
.package(url: "https://github.com/dimashbk/donk.git", from: "0.1.0")
```

The main package has zero dependencies. Its products are `Donk` (everything) and `DonkCore` (models, stores, rules and exporters, with no UI).

### DonkGRPC (optional)

The grpc-swift 1.x interceptor lives in a standalone sub-package at `Integrations/DonkGRPC`, so apps without gRPC never fetch grpc-swift and its transitive packages, and apps that already link grpc-swift keep a single copy. It depends on the public `DonkCore` API only (grpc-swift `1.21.0..<2.0.0`, swift-protobuf `1.25+`). Two ways to use it:

- Add it as a local package from a checkout of donk (for example a git submodule): `.package(path: "Vendor/donk/Integrations/DonkGRPC")`, product `DonkGRPC`. The sub-package refers to its parent by path (`../..`), so add donk itself from the same checkout (`.package(path: "Vendor/donk")`) rather than by URL. In Xcode or XcodeGen, add both folders as local packages (see `Example/project.yml`).
- Copy `Integrations/DonkGRPC/Sources/DonkGRPC` into the module that already owns your gRPC clients and depend on the `DonkCore` product.

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

## Shipping

Nothing runs until `Donk.start` or `Donk.installCrashReporter()` is called: there are no `+load` hooks, no static initializers and no swizzling at load time. Linking donk without calling it changes nothing at runtime. What matters is that no production code path calls `start`.

- Gate every call (`Donk.start`, `Donk.installCrashReporter()`, `DonkPush.didRegister`, …) behind your debug or staging flags: `#if DEBUG`, or a custom `DONK` compilation condition set only in internal configurations.
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

The demo has playgrounds for every module: real HTTP traffic, an in-app gRPC echo server, a WebView page, an inspector layout, CPU/memory/hang generators, crash triggers, push templates and storage seed data.

## Documentation

- [Architecture and module contracts](docs/ARCHITECTURE.md)
- [Design system (DonkUI)](docs/DONKUI.md)
- [Crash reporter internals](docs/DONKCRASH.md)

## License

MIT
