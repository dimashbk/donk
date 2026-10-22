import { describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';
import { FakeApp } from '../src/dev/fakeAppClient.js';
import { FakeAppError, fixtureHello } from '../src/dev/fixtures.js';
import { CLOSE_REJECTED, CLOSE_REPLACED } from '../src/registry.js';
import { callTool, fakeApp, mcpClient, testHub, textOf, trackApp, waitFor } from './helpers.js';

const second = {
  session: '1A2B3C4D-AAAA-4BBB-8CCC-DDDDEEEEFFFF',
  app: { name: 'Example Shop', bundleID: 'com.example.shop' },
  device: { name: 'iPhone 16e', simulatorUDID: '77D1E2F3-0000-4111-8222-333344445555' }
};

function rawApp(url: string, hello: unknown): Promise<{ messages: unknown[]; code: number; reason: string }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const messages: unknown[] = [];
    ws.on('open', () => ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'hello', params: hello })));
    ws.on('message', (data) => messages.push(JSON.parse(data.toString())));
    ws.on('close', (code, reason) => resolve({ messages, code, reason: reason.toString() }));
    ws.on('error', reject);
  });
}

describe('app registry through the hub', () => {
  it('two MCP sessions see the same app concurrently', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const [a, b] = await Promise.all([mcpClient(hub, 'agent-a'), mcpClient(hub, 'agent-b')]);
    expect(hub.mcpSessionCount()).toBe(2);
    const results = await Promise.all([
      callTool(a, 'donk_apps'),
      callTool(b, 'donk_apps'),
      callTool(a, 'donk_network_list', { limit: 1 }),
      callTool(b, 'donk_crash_list')
    ]);
    for (const result of results) expect(result.isError).toBeFalsy();
    expect(textOf(results[0]!)).toContain('6F1C2A9B kz.globerce.fb — connected');
    expect(textOf(results[1]!)).toContain('6F1C2A9B kz.globerce.fb — connected');
    expect(textOf(results[2]!)).toContain('0A1B2C3D');
    expect(textOf(results[3]!)).toContain('C0FFEE00');
  });

  it('resolves app by session prefix, bundleID and simulatorUDID', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    await fakeApp(hub, { hello: second, handlers: { 'crashes.list': () => ({ reports: [] }) } });
    const client = await mcpClient(hub);

    const both = await callTool(client, 'donk_crash_list');
    expect(both.isError).toBe(true);
    expect(textOf(both)).toContain('2 apps are connected; pass app');
    expect(textOf(both)).toContain('6F1C2A9B  kz.globerce.fb  Freedom Business 1.17.0 (1234)');
    expect(textOf(both)).toContain('1A2B3C4D  com.example.shop  Example Shop');

    for (const app of ['1a2b3c4d', 'com.example.shop', '77D1E2F3-0000-4111-8222-333344445555', '77d1e2f3']) {
      expect(textOf(await callTool(client, 'donk_crash_list', { app }))).toBe('No crash reports.');
    }
    for (const app of ['6F1C2A9B-3D4E', 'KZ.GLOBERCE.FB', fixtureHello.device.simulatorUDID!]) {
      expect(textOf(await callTool(client, 'donk_crash_list', { app }))).toContain('C0FFEE00');
    }

    const short = await callTool(client, 'donk_crash_list', { app: '6F1C' });
    expect(short.isError).toBe(true);
    expect(textOf(short)).toContain('No connected app matches "6F1C". Connected apps:');

    const apps = textOf(await callTool(client, 'donk_apps'));
    expect(apps.split('\n')[0]).toBe('2 connected · times UTC');
    expect(apps).toContain('Several apps are connected');
  });

  it('reports an ambiguous selector and the no-apps case', async () => {
    const hub = await testHub();
    const client = await mcpClient(hub);
    const none = await callTool(client, 'donk_network_list');
    expect(none.isError).toBe(true);
    expect(textOf(none)).toBe(`No apps are connected to donk-hub. A debug build with DonkConfiguration.remote.isEnabled = true dials ${hub.appURL} on launch.`);
    const noneNamed = await callTool(client, 'donk_network_list', { app: 'kz.globerce.fb' });
    expect(textOf(noneNamed)).toContain('No connected app matches "kz.globerce.fb". No apps are connected');

    await fakeApp(hub);
    await fakeApp(hub, { hello: { ...second, app: { ...fixtureHello.app } } });
    const ambiguous = await callTool(client, 'donk_network_list', { app: 'kz.globerce.fb' });
    expect(ambiguous.isError).toBe(true);
    expect(textOf(ambiguous)).toContain('"kz.globerce.fb" matches 2 connected apps; pass a session prefix or simulatorUDID instead:');
    expect(textOf(await callTool(client, 'donk_network_list', { app: '1A2B3C4D' }))).toContain('total 7');
  });

  it('turns app errors into MCP tool errors with message and code', async () => {
    const hub = await testHub();
    await fakeApp(hub, {
      handlers: {
        'ui.tree': () => {
          throw new FakeAppError(-32001, 'No foreground scene');
        }
      }
    });
    const client = await mcpClient(hub);
    const missing = await callTool(client, 'donk_network_get', { id: 'DEADBEEF' });
    expect(missing.isError).toBe(true);
    expect(textOf(missing)).toBe('No network entry with id DEADBEEF (app error -32000 not found)');
    const unavailable = await callTool(client, 'donk_ui_tree');
    expect(unavailable.isError).toBe(true);
    expect(textOf(unavailable)).toBe('No foreground scene (app error -32001 unavailable)');
  });

  it('times out requests the app never answers', async () => {
    const hub = await testHub({ requestTimeoutMs: 150 });
    const app = await fakeApp(hub, { handlers: { 'crashes.list': () => new Promise(() => {}) } });
    const client = await mcpClient(hub);
    const started = Date.now();
    const result = await callTool(client, 'donk_crash_list');
    expect(Date.now() - started).toBeGreaterThanOrEqual(140);
    expect(result.isError).toBe(true);
    expect(textOf(result)).toBe('crashes.list timed out after 150 ms: Freedom Business (kz.globerce.fb, 6F1C2A9B) did not answer');
    expect(app.readyState).toBe(WebSocket.OPEN);
    expect(textOf(await callTool(client, 'donk_network_list', { limit: 1 }))).toContain('total 7');
  });

  it('rejects an unsupported protocol with close code 4000', async () => {
    const hub = await testHub();
    const outcome = await rawApp(hub.appURL, { ...fixtureHello, protocol: 2 });
    expect(outcome.code).toBe(CLOSE_REJECTED);
    expect(outcome.messages).toEqual([
      {
        jsonrpc: '2.0',
        method: 'rejected',
        params: { reason: 'Unsupported protocol 2: donk-hub 0.1.0 speaks protocol 1. Update donk or donk-hub so they match.' }
      }
    ]);
    expect(hub.registry.connections()).toHaveLength(0);

    const invalid = await rawApp(hub.appURL, { protocol: 1, app: { name: 'x' } });
    expect(invalid.code).toBe(CLOSE_REJECTED);
    expect(JSON.stringify(invalid.messages)).toContain('Invalid hello: hello.session must be a non-empty string');
  });

  it('answers hello with welcome', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    expect(app.welcome).toEqual({ protocol: 1, hub: '0.1.0' });
  });

  it('a second hello with the same session replaces the old connection', async () => {
    const hub = await testHub();
    const old = trackApp(new FakeApp({ url: hub.appURL, handlers: { 'crashes.list': () => new Promise(() => {}) } }));
    await old.ready;
    const client = await mcpClient(hub);
    const stalled = callTool(client, 'donk_crash_list');
    await old.nextRequest('crashes.list');

    const replacement = await fakeApp(hub, { handlers: { 'crashes.list': () => ({ reports: [] }) } });
    expect((await old.closed).code).toBe(CLOSE_REPLACED);
    const stalledResult = await stalled;
    expect(stalledResult.isError).toBe(true);
    expect(textOf(stalledResult)).toBe(
      'Freedom Business (kz.globerce.fb, 6F1C2A9B) was replaced by a new connection of the same session before answering crashes.list'
    );
    expect(hub.registry.connections()).toHaveLength(1);
    expect(textOf(await callTool(client, 'donk_crash_list'))).toBe('No crash reports.');
    expect(replacement.requests.map((request) => request.method)).toEqual(['crashes.list']);
    expect(textOf(await callTool(client, 'donk_apps')).split('\n')[0]).toBe('1 connected · times UTC');
  });

  it('fails pending requests when the app disconnects and keeps it visible as disconnected', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub, { handlers: { 'network.get': () => new Promise(() => {}) } });
    const client = await mcpClient(hub);
    const call = callTool(client, 'donk_network_get', { id: 'A1F3C2D4' });
    await app.nextRequest('network.get');
    await app.close(1001, 'going away');
    const result = await call;
    expect(result.isError).toBe(true);
    expect(textOf(result)).toBe('Freedom Business (kz.globerce.fb, 6F1C2A9B) disconnected (close 1001 going away) before answering network.get');

    const apps = textOf(await callTool(client, 'donk_apps'));
    expect(apps.split('\n')[0]).toBe('0 connected, 1 recently disconnected · times UTC');
    expect(apps).toMatch(/6F1C2A9B kz\.globerce\.fb — disconnected \d\d:\d\d:\d\d \(0s ago\); tools reach it again once it reconnects/);

    const routed = await callTool(client, 'donk_network_list', { app: 'kz.globerce.fb' });
    expect(routed.isError).toBe(true);
    expect(textOf(routed)).toMatch(/^Freedom Business \(kz\.globerce\.fb, 6F1C2A9B\) disconnected at \d\d:\d\d:\d\d; it reconnects by itself/);
    const implicit = await callTool(client, 'donk_network_list');
    expect(textOf(implicit)).toContain('Recently disconnected:\n  6F1C2A9B  kz.globerce.fb');
  });

  it('forgets disconnected apps after the retention period', async () => {
    const hub = await testHub({ retentionMs: 50 });
    const app = await fakeApp(hub);
    await app.close();
    await waitFor(() => hub.registry.connections().length === 0);
    expect(hub.registry.snapshots()).toHaveLength(1);
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(hub.registry.snapshots()).toHaveLength(0);
  });

  it('drops an app that misses two pongs', async () => {
    const hub = await testHub({ pingIntervalMs: 40 });
    const silent = await fakeApp(hub, { autoPong: false });
    const healthy = await fakeApp(hub, { hello: second });
    const closed = await silent.closed;
    expect(closed.code).toBe(1006);
    await waitFor(() => hub.registry.connections().length === 1);
    expect(hub.registry.connections()[0]?.hello.session).toBe(second.session);
    expect(healthy.readyState).toBe(WebSocket.OPEN);
  });

  it('answers unexpected app requests with method not found and ignores garbage', async () => {
    const hub = await testHub();
    const messages: unknown[] = [];
    const ws = new WebSocket(hub.appURL);
    await new Promise<void>((resolve) => ws.on('open', () => resolve()));
    ws.on('message', (data) => messages.push(JSON.parse(data.toString())));
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'x1', method: 'network.list' }));
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'hello', params: fixtureHello }));
    ws.send('not json');
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'x2', method: 'issues.create', params: {} }));
    await waitFor(() => messages.length === 4);
    ws.close();
    expect(messages).toEqual([
      { jsonrpc: '2.0', id: 'x1', error: { code: -32600, message: 'Send hello first' } },
      { jsonrpc: '2.0', method: 'welcome', params: { protocol: 1, hub: '0.1.0' } },
      { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } },
      { jsonrpc: '2.0', id: 'x2', error: { code: -32601, message: 'Method not found: issues.create' } }
    ]);
  });

  it('closes sockets that never say hello', async () => {
    const hub = await testHub({ helloTimeoutMs: 50 });
    const ws = new WebSocket(hub.appURL);
    const code = await new Promise<number>((resolve) => ws.on('close', (closeCode) => resolve(closeCode)));
    expect(code).toBe(1008);
  });
});
