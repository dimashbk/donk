# donk-hub

An MCP server that lets coding agents (Claude Code and any other MCP client) read what [donk](../README.md) captures inside a running iOS app: network traffic (HTTP, gRPC, web views), crash reports, the live UI tree and screenshots.

```
iOS app (DonkRemote) ──WebSocket /app──▶ donk-hub (this folder) ◀──MCP Streamable HTTP /mcp── agent sessions
```

The hub is one long-running process on your Mac. Apps dial it, so nothing listens on the device, and every MCP session sees the same registry of connected apps, so several agents can work with the same app at once. Phase 1 is read-only. The wire protocol is in [../docs/DONKREMOTE.md](../docs/DONKREMOTE.md).

## Run

Requires Node 20 or newer.

```sh
cd mcp
npm install
npm run build
npm start                 # 127.0.0.1:7337
npm start -- --port 7400  # or DONK_HUB_PORT=7400 npm start
```

The hub binds to `127.0.0.1` only and refuses requests whose `Host` or `Origin` is not localhost (DNS rebinding protection). During development, `npm run dev` runs it from source with tsx.

## Connect Claude Code

```sh
claude mcp add --transport http donk http://127.0.0.1:7337/mcp
```

Any MCP client with Streamable HTTP support works the same way.

## Connect an app

Enable the bridge in a debug build. The app dials `ws://127.0.0.1:7337/app` on launch, reconnects with backoff, and shows an "Agent bridge" row in donk Settings.

```swift
var configuration = DonkConfiguration()
configuration.remote.isEnabled = true
Donk.start(configuration)
```

Phase 1 covers simulator apps; they reach the hub on `127.0.0.1`.

## Tools

| tool | what it returns |
|---|---|
| `donk_apps` | connected apps (session prefix, app, version/build, device, simulator UDID, connection time) and capture stats; recently disconnected apps stay listed for 10 minutes |
| `donk_network_list` | one line per entry, `<id8> <HH:mm:ss.SSS> <METHOD> <status> <duration> <title> <host>`, then the total and a `before` cursor; filters: `query`, `kinds`, `hosts`, `status`, `onlyModified`, `onlyPinned`, `limit` |
| `donk_network_get` | request and response headers and bodies, timing, gRPC metadata and message timeline, cURL or grpcurl |
| `donk_crash_list` | one line per crash report |
| `donk_crash_get` | the full report text |
| `donk_ui_tree` | indented view tree, `UIButton "Войти" #login.button (16,620 343×52) [tap]`, plus the controller tree; `match` keeps only branches leading to matching nodes |
| `donk_screenshot` | the app's windows as an MCP image |

Every tool except `donk_apps` takes an optional `app`: a session (or an 8+ character prefix), a bundleID or a simulatorUDID. Leave it out when exactly one app is connected. Entry and crash ids can be shortened to 8 characters. Frames are in screen points, the same coordinate space simulator tap tools use. All data is redacted by the app before it leaves the device.

## Try it without a simulator

With the hub running, start a fake app that serves fixture data (HTTP and gRPC entries including failures, crash reports, a small UI tree and a tiny screenshot):

```sh
npm run fake-app
npm run fake-app -- --port 7400 --bundle-id com.example.other --session 1A2B3C4D-0000-4000-8000-000000000000
```

Then ask your agent to call `donk_apps`, or run several fake apps to see `app` resolution in action.

## Development

```sh
npm test          # vitest: end-to-end through a real hub on a random port, plus renderer unit tests
npm run typecheck # tsc over src and tests
```

`src/hub.ts` holds the HTTP server, the WebSocket upgrade and the MCP sessions; `src/registry.ts` the app registry and JSON-RPC correlation; `src/tools.ts` the MCP tools; `src/render/` the text renderers; `src/dev/` the fake app and its fixtures, which the tests reuse.
