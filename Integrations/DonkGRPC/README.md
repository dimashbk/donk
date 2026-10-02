# DonkGRPC

A grpc-swift 1.x `ClientInterceptor` that feeds donk's network inspector. Every RPC becomes one live entry with its metadata, a timeline of sent and received messages (rendered as JSON, with protobuf text format as a fallback), trailers and the final status. Map Local, Rewrite and Breakpoint rules work for gRPC calls too.

DonkGRPC is a separate package so that apps without gRPC never fetch grpc-swift, and apps that already link grpc-swift keep a single copy. It only uses the public `DonkCore` API.

- grpc-swift `1.21.0..<2.0.0` (NIO and NIOTransportServices channels both work)
- swift-protobuf `1.25.0` or later
- iOS 15+

## Adding it

### As a local package

The package refers to the root donk package by path (`../..`), so both must come from the same checkout, for example a git submodule at `Vendor/donk`:

```swift
dependencies: [
    .package(path: "Vendor/donk"),
    .package(path: "Vendor/donk/Integrations/DonkGRPC"),
],
targets: [
    .target(name: "Networking", dependencies: [
        .product(name: "Donk", package: "Donk"),
        .product(name: "DonkGRPC", package: "DonkGRPC"),
    ]),
]
```

In Xcode or XcodeGen, add both folders as local packages. `Example/project.yml` does exactly that.

### By copying the sources

Copy `Sources/DonkGRPC` into the module that already owns your gRPC clients and add the `DonkCore` product of donk to that module. The sources need `GRPC`, `SwiftProtobuf`, `NIOCore` and `NIOHPACK`, which a grpc-swift client module already links. Keep the files together and don't edit them, so that updating is a plain copy.

## Wiring the interceptor

Return donk's interceptor from every method of your generated interceptor factory:

```swift
import DonkGRPC
import GRPC

final class AccountInterceptors: Bank_V1_AccountServiceClientInterceptorFactoryProtocol {
    private let host = "api.example.com:443"

    func makeGetAccountInterceptors() -> [ClientInterceptor<Bank_V1_GetAccountRequest, Bank_V1_Account>] {
        DonkGRPC.interceptors(host: host, after: [AuthInterceptor(), RetryInterceptor()])
    }

    func makeWatchEventsInterceptors() -> [ClientInterceptor<Bank_V1_WatchRequest, Bank_V1_Event>] {
        DonkGRPC.interceptors(host: host)
    }
}
```

- **Pass the host.** An interceptor can't see `:authority`, so the factory has to name it. It's used for the entry URL (`grpc://host/package.Service/Method`), for rule matching and for bypass hosts. Use the same string you connect to, with or without a port.
- **Put donk last.** grpc-swift orders interceptors from the application (first) to the transport (last). `interceptors(host:after:)` appends donk's interceptor after your own, so donk records exactly what goes over the wire, for example the `authorization` header your auth interceptor adds, and its rules see your final metadata.
- **Make new instances per call.** Factory methods are called once per RPC. Return a fresh array every time and don't cache interceptors.

`DonkGRPCOptions` lets you change rendering and limits, and points the interceptor at other stores (useful in tests):

```swift
var options = DonkGRPCOptions(
    preserveProtoFieldNames: true,
    bypassHosts: ["metrics.example.com"]
)
options.maxRenderBacklogMessages = 128
let interceptors: [ClientInterceptor<Request, Response>] = DonkGRPC.interceptors(host: host, options: options)
```

| Option | Default | Meaning |
|---|---|---|
| `preserveProtoFieldNames`, `alwaysPrintEnumsAsInts` | `false` | JSON rendering style |
| `anyTypeRegistry` | `[]` | `google.protobuf.Any` payload types, see below |
| `isRulesEnabled` | `true` | `false` records calls but never applies rules |
| `maxRenderedMessageSize` | 1 MB | larger messages are recorded with their size only |
| `maxRawMessageSize` | 64 KB | raw protobuf bytes are kept for messages up to this size |
| `maxRenderBacklogMessages`, `maxRenderBacklogBytes` | 256, 4 MB | per-call render queue, see below |
| `bypassHosts` | `[]` | hosts that are never recorded, on top of the bypass list in donk's settings |
| `store`, `ruleStore`, `breakpointCenter`, `settingsStore` | shared instances | where entries go and where rules and settings come from |

## `google.protobuf.Any`

Protobuf JSON can only render an `Any` whose type is registered. Register the types your messages carry once, at startup:

```swift
DonkGRPC.register(anyTypes: [Bank_V1_CardDetails.self, Google_Rpc_ErrorInfo.self])
```

or per client through `DonkGRPCOptions(anyTypeRegistry:)`. Registration goes into swift-protobuf's global `Any` registry, so it happens lazily: the per-options registry is only applied by a call that donk actually records. A message with an unregistered `Any` falls back to protobuf text format, and its raw bytes are still kept.

## When donk is off

The interceptor decides once per call, on the call's first outbound part. It passes the whole call through untouched when any of these holds at that moment:

- donk isn't running (`DonkEnvironment.isActive` is false: before `Donk.start` and after `Donk.stop`),
- capture is paused in the debugger (`NetworkStore.isCaptureEnabled` is false),
- the host matches a bypass pattern (`bypassHosts` or donk's network settings).

Passed-through calls create no entry, resolve no rules, never pause at breakpoints, serialize nothing and register no `Any` types. Each part is handed straight to the next interceptor. A call that started while donk was off stays untouched even if donk starts later. A call that started while donk was on keeps being recorded until it ends.

Breakpoints also need someone to answer them: while no debugger UI is attached (`BreakpointCenter.hasPresenter` is false), breakpoint rules are ignored and calls never wait.

## Recording and memory

Recording happens off the gRPC event loop. On the event loop, each message is serialized once. Those bytes give the message size and the raw bytes, and a background queue decodes them for the JSON rendering. The host's message objects are never retained.

High-rate streams can't build an unbounded backlog. Each call has a render queue limited to `maxRenderBacklogMessages` messages and `maxRenderBacklogBytes` bytes. When the queue is full, the next messages aren't rendered: they're recorded as placeholders with their real size and the note `rendering skipped (backlog)`. Message counts and byte totals stay exact either way. Messages larger than both size limits retain no bytes while queued. Each entry keeps the latest 1000 messages, and `NetworkStore`'s total byte budget evicts old entries.

## Rules on streaming calls

| | Unary, server streaming | Client streaming, bidi streaming |
|---|---|---|
| Request breakpoint | Metadata and the request message are held together. Headers and body can be edited. | Metadata is sent right away so the call opens normally (many bidi clients wait for server headers before they send). The breakpoint pauses on the **first message** only. Body edits apply. Header edits are ignored because the headers are already on the wire. Later messages wait behind the paused one, in order. A call that ends without sending a message doesn't pause. |
| Respond locally at a request breakpoint | The call never reaches the server. | The already opened server stream is cancelled. Bidi gets the local response right away, client streaming once the client sends `end`. |
| Abort | The call ends with `CANCELLED` and never reaches the server. | The call ends with `CANCELLED` and the server stream is cancelled. |
| Response breakpoint | Pauses once with the headers, the message and the final status. | Client streaming: as for unary. Bidi: pauses on each received message, like server streaming. |
| Map Local | Answered after the client finishes sending. | Client streaming: answered after the client sends `end`. Bidi: answered after the **first client message** (or on `end` if it comes first). Messages sent before the mock finishes are recorded. The server is never contacted. |
| Rewrite | Applied to the metadata and every message. | Same. |

Server-streaming responses pause on every message while a response breakpoint is active, so use it with care on long-lived event streams.

## Known limitations

- Message timestamps are taken when a message is recorded, so a busy render queue can delay them by the queue length.
- After placeholders were recorded, the entry's response body can show an earlier rendered message rather than the latest one.
- Rules are resolved when a call starts. Rules added while a long-lived stream is open apply to the next call.
