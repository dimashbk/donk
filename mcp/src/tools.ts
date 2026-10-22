import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import {
  HUB_VERSION,
  type AppInfoResult,
  type CrashGetResult,
  type CrashListResult,
  type NetworkGetResult,
  type NetworkListResult,
  type ScreenshotResult,
  type UITreeResult
} from './protocol.js';
import type { AppRegistry } from './registry.js';
import { renderApps, type AppReport } from './render/apps.js';
import { renderCrashDetail, renderCrashList } from './render/crashes.js';
import { formatNumber } from './render/format.js';
import { renderNetworkDetail, renderNetworkList } from './render/network.js';
import { renderUITree } from './render/ui.js';

export const SERVER_INSTRUCTIONS = [
  'donk-hub reads what the donk debugger captures inside running iOS apps (debug builds on the simulator): network traffic (HTTP, gRPC, web views), crash reports, the live UI tree and screenshots.',
  '- Start with donk_apps: it lists the connected apps with their session prefix, bundleID, simulatorUDID and capture stats.',
  '- Every other tool takes an optional `app` (session prefix of 8+ characters, bundleID or simulatorUDID). Omit it when exactly one app is connected.',
  '- Entry and crash ids can be shortened to their first 8 characters.',
  '- Data is redacted by the app before it leaves the device (headers, bodies, cURL/grpcurl); masked values are intentional, not bugs.',
  '- Phase 1 is read-only: nothing these tools do changes app behavior.',
  '- simulatorUDID pairs donk data with simulator control tools (xcrun simctl, simulator MCP servers). donk_ui_tree frames are in points in the screen coordinate space that simulator tap tools use, and donk_screenshot at scale 1 has one pixel per point, so coordinates carry over directly.',
  '- Typical flows: donk_network_list (filter with query/status/kinds) then donk_network_get <id>; donk_ui_tree with match to find a control and its frame; donk_crash_list then donk_crash_get <id>.'
].join('\n');

const appArg = z
  .string()
  .optional()
  .describe('Target app: session (or 8+ char prefix), bundleID, or simulatorUDID from donk_apps. Omit when exactly one app is connected.');

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false } as const;

export interface ToolContext {
  registry: AppRegistry;
}

function text(value: string): CallToolResult {
  return { content: [{ type: 'text', text: value }] };
}

function failure(error: unknown): CallToolResult {
  const message = error instanceof Error ? error.message : String(error);
  return { content: [{ type: 'text', text: message }], isError: true };
}

function params(args: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (key !== 'app' && key !== 'match' && value !== undefined) result[key] = value;
  }
  return result;
}

async function guarded(run: () => Promise<CallToolResult>): Promise<CallToolResult> {
  try {
    return await run();
  } catch (error) {
    return failure(error);
  }
}

async function call<T>(ctx: ToolContext, args: Record<string, unknown>, method: string): Promise<T> {
  const connection = ctx.registry.resolve(typeof args.app === 'string' ? args.app : undefined);
  return connection.request<T>(method, params(args));
}

export function createMcpServer(ctx: ToolContext): McpServer {
  const server = new McpServer({ name: 'donk-hub', version: HUB_VERSION }, { instructions: SERVER_INSTRUCTIONS });

  server.registerTool(
    'donk_apps',
    {
      title: 'Connected donk apps',
      description:
        'List apps connected to donk-hub (and ones that disconnected in the last few minutes): session prefix, app name, bundleID, version/build, device, simulatorUDID, connection time and capture stats (network entries, rules, crash reports). Call this first; use the session prefix, bundleID or simulatorUDID as `app` in other tools when several apps are connected.',
      inputSchema: {},
      annotations: readOnly
    },
    async () =>
      guarded(async () => {
        const snapshots = ctx.registry.snapshots();
        const reports = await Promise.all(
          snapshots.map(async (snapshot): Promise<AppReport> => {
            const connection = snapshot.connected ? ctx.registry.connection(snapshot.session) : undefined;
            if (!connection) return { app: snapshot };
            try {
              return { app: snapshot, info: await connection.request<AppInfoResult>('app.info') };
            } catch (error) {
              return { app: snapshot, infoError: error instanceof Error ? error.message : String(error) };
            }
          })
        );
        return text(renderApps(reports, { now: new Date(), appURL: ctx.registry.appURL }));
      })
  );

  server.registerTool(
    'donk_network_list',
    {
      title: 'List captured network entries',
      description:
        'List captured network entries (HTTP, gRPC, web view), newest first. One line per entry: `<id8> <HH:mm:ss.SSS> <METHOD> <status> <duration> <title> <host>` plus tags like [mocked: rule], [pinned] and `! <error>`. The footer has the total matching count and a `before` cursor for the next (older) page. Use donk_network_get with an id for headers, bodies and gRPC messages.',
      inputSchema: {
        app: appArg,
        query: z
          .string()
          .optional()
          .describe(
            'Search like the donk search field: whitespace-separated terms, all must match, case-insensitive substring over URL, method, status, error, gRPC path/status, headers, bodies (first 256 KB) and gRPC messages. Example: "accounts 500".'
          ),
        kinds: z.array(z.enum(['http', 'grpc', 'webView'])).optional().describe('Only these entry kinds.'),
        hosts: z.array(z.string()).optional().describe('Only these hosts, exact match (e.g. ["api.example.com"]).'),
        status: z
          .array(z.enum(['pending', 'success', 'redirect', 'clientError', 'serverError', 'failure']))
          .optional()
          .describe('Only these status categories. gRPC non-OK codes count as clientError/serverError; transport errors are failure.'),
        onlyModified: z.boolean().optional().describe('Only entries changed by donk rules or breakpoints (mocked, rewritten, breakpoint).'),
        onlyPinned: z.boolean().optional().describe('Only entries pinned in the donk UI.'),
        limit: z.number().int().min(1).max(500).optional().describe('Page size, 1-500 (default 50).'),
        before: z.string().optional().describe('Cursor: return only entries older than this entry id (use the `before=` value from the previous page footer).')
      },
      annotations: readOnly
    },
    async (args) => guarded(async () => text(renderNetworkList(await call<NetworkListResult>(ctx, args, 'network.list'))))
  );

  server.registerTool(
    'donk_network_get',
    {
      title: 'Network entry details',
      description:
        'Show one captured network entry in full: URL, status, timing, error, request and response headers and bodies (pretty JSON when possible), gRPC metadata/trailers and message timeline, and a ready-to-run cURL or grpcurl command. Bodies and gRPC messages are cut at maxBodyBytes and marked [truncated].',
      inputSchema: {
        app: appArg,
        id: z.string().min(8).describe('Entry id from donk_network_list: the full id or a unique prefix of at least 8 characters.'),
        maxBodyBytes: z
          .number()
          .int()
          .min(1024)
          .max(1_048_576)
          .optional()
          .describe('Cap for each body and each gRPC message text, in bytes, 1024-1048576 (default 65536).'),
        maxMessages: z.number().int().min(0).max(1000).optional().describe('How many of the newest gRPC messages to include, 0-1000 (default 50).')
      },
      annotations: readOnly
    },
    async (args) => guarded(async () => text(renderNetworkDetail((await call<NetworkGetResult>(ctx, args, 'network.get')).entry)))
  );

  server.registerTool(
    'donk_crash_list',
    {
      title: 'List crash reports',
      description:
        'List crash reports captured by DonkCrash, newest first: `<id8> <date> <kind> <title> — <reason> · <app version> · <iOS>`. Fails with "unavailable" when DonkCrash is not installed in the app. Use donk_crash_get for the full report.',
      inputSchema: {
        app: appArg,
        limit: z.number().int().min(1).max(200).optional().describe('How many reports, 1-200 (default 20).')
      },
      annotations: readOnly
    },
    async (args) => guarded(async () => text(renderCrashList(await call<CrashListResult>(ctx, args, 'crashes.list'))))
  );

  server.registerTool(
    'donk_crash_get',
    {
      title: 'Crash report',
      description: 'Show one crash report in full (the same text DonkCrash exports: exception, threads, backtraces, binary images).',
      inputSchema: {
        app: appArg,
        id: z.string().min(8).describe('Report id from donk_crash_list: the full id or a unique prefix of at least 8 characters.')
      },
      annotations: readOnly
    },
    async (args) => guarded(async () => text(renderCrashDetail(await call<CrashGetResult>(ctx, args, 'crashes.get'))))
  );

  server.registerTool(
    'donk_ui_tree',
    {
      title: 'UI view tree',
      description:
        'Dump the live view hierarchy of the foreground scene, one node per line, indented by depth: `UIButton "Войти" #login.button (16,620 343×52) [tap]` = class, visible text, #accessibilityIdentifier, frame (x,y width×height in screen points, the space simulator tap tools use), flags ([tap] = interactive, plus accessibility traits). Also shows the view controller hierarchy. Pass `match` to keep only the branches leading to nodes whose class, id, label or text contains it; this is the cheapest way to find one control.',
      inputSchema: {
        app: appArg,
        match: z
          .string()
          .optional()
          .describe('Case-insensitive filter on class, accessibilityIdentifier, accessibilityLabel and text; keeps matching nodes and their ancestors only.'),
        maxDepth: z.number().int().min(0).max(256).optional().describe('Maximum depth, 0-256 (default 40); deeper children are counted, not listed.'),
        includeHidden: z.boolean().optional().describe('Include hidden views (isHidden or alpha < 0.01) and their subtrees (default false).'),
        maxNodes: z.number().int().min(1).max(20_000).optional().describe('Stop after this many nodes, 1-20000 (default 3000); the output says when it was truncated.')
      },
      annotations: readOnly
    },
    async (args) => guarded(async () => text(renderUITree(await call<UITreeResult>(ctx, args, 'ui.tree'), args.match)))
  );

  server.registerTool(
    'donk_screenshot',
    {
      title: 'App screenshot',
      description:
        "Capture the app's windows as an image (donk's own windows excluded), drawn like the donk inspector snapshot. At scale 1 one pixel equals one point, so positions match donk_ui_tree frames and simulator tap coordinates.",
      inputSchema: {
        app: appArg,
        scale: z.number().min(0.25).max(3).optional().describe('Pixels per point, 0.25-3 (default 1). Use 0.5 to save tokens, 2-3 for fine detail.'),
        format: z.enum(['jpeg', 'png']).optional().describe('Image format (default jpeg).'),
        quality: z.number().min(0).max(1).optional().describe('JPEG quality 0-1 (default 0.7).')
      },
      annotations: readOnly
    },
    async (args) =>
      guarded(async () => {
        const shot = await call<ScreenshotResult>(ctx, args, 'ui.screenshot');
        const scale = args.scale ?? 1;
        const size = shot.width !== undefined && shot.height !== undefined ? `${formatNumber(shot.width)}×${formatNumber(shot.height)} px, ` : '';
        return {
          content: [
            { type: 'image', data: shot.data, mimeType: shot.mimeType },
            { type: 'text', text: `${size}${formatNumber(scale)} px per point; divide pixel coordinates by ${formatNumber(scale)} to get points.` }
          ]
        };
      })
  );

  return server;
}
