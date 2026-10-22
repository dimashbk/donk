import { request } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { afterEach } from 'vitest';
import { FakeApp, type FakeAppOptions } from '../src/dev/fakeAppClient.js';
import { startHub, type Hub, type HubOptions } from '../src/hub.js';

const cleanups: Array<() => Promise<unknown>> = [];

afterEach(async () => {
  while (cleanups.length) {
    const cleanup = cleanups.pop();
    await cleanup?.().catch(() => {});
  }
});

export async function testHub(options: HubOptions = {}): Promise<Hub> {
  const hub = await startHub({ port: 0, ...options });
  cleanups.push(() => hub.close());
  return hub;
}

export async function mcpClient(hub: Hub, name = 'test-agent'): Promise<Client> {
  const client = new Client({ name, version: '1.0.0' });
  await client.connect(new StreamableHTTPClientTransport(new URL(hub.mcpURL)));
  cleanups.push(() => client.close());
  return client;
}

export async function fakeApp(hub: Hub, options: Omit<FakeAppOptions, 'url'> = {}): Promise<FakeApp> {
  const app = await FakeApp.connect({ url: hub.appURL, ...options });
  cleanups.push(() => app.terminate());
  return app;
}

export function trackApp(app: FakeApp): FakeApp {
  cleanups.push(() => app.terminate());
  return app;
}

export async function callTool(client: Client, name: string, args: Record<string, unknown> = {}): Promise<CallToolResult> {
  return (await client.callTool({ name, arguments: args })) as CallToolResult;
}

export function textOf(result: CallToolResult): string {
  return result.content
    .flatMap((item) => (item.type === 'text' ? [item.text] : []))
    .join('\n');
}

export async function waitFor(condition: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('waitFor timed out');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

export function rawRequest(
  hub: Hub,
  options: { method: string; path: string; headers?: Record<string, string>; body?: string }
): Promise<{ status: number; body: string; headers: Record<string, string | string[] | undefined> }> {
  return new Promise((resolve, reject) => {
    const req = request(
      { host: '127.0.0.1', port: hub.port, method: options.method, path: options.path, headers: options.headers, setHost: !options.headers?.Host },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8'), headers: res.headers }));
      }
    );
    req.on('error', reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}
