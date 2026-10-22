import { describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';
import { isLocalHost, isLocalOrigin } from '../src/hub.js';
import { rawRequest, testHub } from './helpers.js';

const initialize = JSON.stringify({
  jsonrpc: '2.0',
  id: 1,
  method: 'initialize',
  params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'raw', version: '1' } }
});

const mcpHeaders = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };

describe('DNS rebinding protection', () => {
  it('accepts only localhost Host and Origin values', () => {
    expect(isLocalHost('127.0.0.1:7337')).toBe(true);
    expect(isLocalHost('localhost:7337')).toBe(true);
    expect(isLocalHost('[::1]:7337')).toBe(true);
    expect(isLocalHost('localhost')).toBe(true);
    expect(isLocalHost('evil.example.com')).toBe(false);
    expect(isLocalHost('localhost.evil.example.com:7337')).toBe(false);
    expect(isLocalHost('127.0.0.1.nip.io')).toBe(false);
    expect(isLocalHost(undefined)).toBe(false);
    expect(isLocalOrigin(undefined)).toBe(true);
    expect(isLocalOrigin('http://localhost:3000')).toBe(true);
    expect(isLocalOrigin('https://127.0.0.1')).toBe(true);
    expect(isLocalOrigin('https://evil.example.com')).toBe(false);
    expect(isLocalOrigin('null')).toBe(false);
  });

  it('rejects a foreign Host header on /mcp with 403', async () => {
    const hub = await testHub();
    const response = await rawRequest(hub, {
      method: 'POST',
      path: '/mcp',
      headers: { ...mcpHeaders, Host: 'evil.example.com' },
      body: initialize
    });
    expect(response.status).toBe(403);
    expect(JSON.parse(response.body).error.message).toContain('Invalid Host header: evil.example.com');
    expect(hub.mcpSessionCount()).toBe(0);
  });

  it('rejects a foreign Origin header on /mcp with 403', async () => {
    const hub = await testHub();
    const response = await rawRequest(hub, {
      method: 'POST',
      path: '/mcp',
      headers: { ...mcpHeaders, Host: `127.0.0.1:${hub.port}`, Origin: 'https://evil.example.com' },
      body: initialize
    });
    expect(response.status).toBe(403);
    expect(JSON.parse(response.body).error.message).toContain('Invalid Origin header');
  });

  it('accepts localhost requests and manages sessions', async () => {
    const hub = await testHub();
    const ok = await rawRequest(hub, { method: 'POST', path: '/mcp', headers: { ...mcpHeaders, Host: `localhost:${hub.port}` }, body: initialize });
    expect(ok.status).toBe(200);
    const sessionId = ok.headers['mcp-session-id'];
    expect(typeof sessionId).toBe('string');
    expect(hub.mcpSessionCount()).toBe(1);

    const unknown = await rawRequest(hub, { method: 'POST', path: '/mcp', headers: { ...mcpHeaders, 'Mcp-Session-Id': 'nope' }, body: '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' });
    expect(unknown.status).toBe(404);
    const missing = await rawRequest(hub, { method: 'POST', path: '/mcp', headers: mcpHeaders, body: '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' });
    expect(missing.status).toBe(400);
    const garbage = await rawRequest(hub, { method: 'POST', path: '/mcp', headers: mcpHeaders, body: '{' });
    expect(garbage.status).toBe(400);

    const deleted = await rawRequest(hub, {
      method: 'DELETE',
      path: '/mcp',
      headers: { 'Mcp-Session-Id': String(sessionId), 'Mcp-Protocol-Version': '2025-06-18' }
    });
    expect(deleted.status).toBe(200);
    expect(hub.mcpSessionCount()).toBe(0);
  });

  it('rejects WebSocket upgrades with a foreign Host or Origin', async () => {
    const hub = await testHub();
    const attempt = (headers: Record<string, string>) =>
      new Promise<number>((resolve, reject) => {
        const ws = new WebSocket(hub.appURL, { headers });
        ws.on('unexpected-response', (_req, res) => resolve(res.statusCode ?? 0));
        ws.on('open', () => reject(new Error('upgrade should have been refused')));
        ws.on('error', () => {});
      });
    expect(await attempt({ Host: 'evil.example.com' })).toBe(403);
    expect(await attempt({ Origin: 'https://evil.example.com' })).toBe(403);
    expect(hub.registry.connections()).toHaveLength(0);
  });

  it('serves only /mcp and /app', async () => {
    const hub = await testHub();
    expect((await rawRequest(hub, { method: 'GET', path: '/' })).status).toBe(404);
    expect((await rawRequest(hub, { method: 'GET', path: '/app' })).status).toBe(426);
    expect((await rawRequest(hub, { method: 'PUT', path: '/mcp' })).status).toBe(405);
  });

  it('listens on 127.0.0.1 only', async () => {
    const hub = await testHub();
    expect(hub.host).toBe('127.0.0.1');
    expect(hub.mcpURL).toBe(`http://127.0.0.1:${hub.port}/mcp`);
    expect(hub.appURL).toBe(`ws://127.0.0.1:${hub.port}/app`);
  });
});
