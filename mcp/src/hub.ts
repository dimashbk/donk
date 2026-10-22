import { randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo, Socket } from 'node:net';
import type { Duplex } from 'node:stream';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { WebSocketServer } from 'ws';
import { AppRegistry, silentLogger, type Logger, type RegistryOptions } from './registry.js';
import { createMcpServer } from './tools.js';

export const DEFAULT_PORT = 7337;
export const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const MAX_MCP_BODY_BYTES = 4 * 1024 * 1024;
const LOCAL_HOSTNAMES = new Set(['localhost', '127.0.0.1', '[::1]']);

export interface HubOptions extends RegistryOptions {
  port?: number;
  host?: string;
}

export interface Hub {
  readonly port: number;
  readonly host: string;
  readonly mcpURL: string;
  readonly appURL: string;
  readonly registry: AppRegistry;
  mcpSessionCount(): number;
  close(): Promise<void>;
}

interface McpSession {
  transport: StreamableHTTPServerTransport;
  server: McpServer;
}

export function isLocalHost(value: string | undefined): boolean {
  if (!value) return false;
  try {
    return LOCAL_HOSTNAMES.has(new URL(`http://${value}`).hostname);
  } catch {
    return false;
  }
}

export function isLocalOrigin(value: string | undefined): boolean {
  if (value === undefined) return true;
  try {
    const url = new URL(value);
    return (url.protocol === 'http:' || url.protocol === 'https:') && LOCAL_HOSTNAMES.has(url.hostname);
  } catch {
    return false;
  }
}

function requestProblem(req: IncomingMessage): string | undefined {
  if (!isLocalHost(req.headers.host)) return `Invalid Host header: ${req.headers.host ?? '(missing)'}; donk-hub only serves localhost`;
  if (!isLocalOrigin(req.headers.origin)) return `Invalid Origin header: ${req.headers.origin}; donk-hub only serves localhost`;
  return undefined;
}

function sendJson(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  if (res.headersSent) {
    res.end();
    return;
  }
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
  res.end(JSON.stringify(body));
}

function rpcError(code: number, message: string): unknown {
  return { jsonrpc: '2.0', error: { code, message }, id: null };
}

class BodyTooLarge extends Error {}

function readBody(req: IncomingMessage, limit: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) {
        reject(new BodyTooLarge());
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function rejectUpgrade(socket: Duplex, status: string, message: string): void {
  const body = `${message}\n`;
  socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

export async function startHub(options: HubOptions = {}): Promise<Hub> {
  const host = options.host ?? '127.0.0.1';
  const logger: Logger = options.logger ?? silentLogger;
  const registry = new AppRegistry(options);
  const sessions = new Map<string, McpSession>();
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME_BYTES, perMessageDeflate: false });

  const handleMcp = async (req: IncomingMessage, res: ServerResponse) => {
    const header = req.headers['mcp-session-id'];
    const sessionId = Array.isArray(header) ? header[0] : header;
    const existing = sessionId ? sessions.get(sessionId) : undefined;

    if (req.method === 'GET' || req.method === 'DELETE') {
      if (!sessionId) return sendJson(res, 400, rpcError(-32000, 'Bad Request: Mcp-Session-Id header is required'));
      if (!existing) return sendJson(res, 404, rpcError(-32001, 'Session not found'));
      return existing.transport.handleRequest(req, res);
    }

    if (req.method !== 'POST') {
      return sendJson(res, 405, rpcError(-32000, 'Method not allowed'), { Allow: 'GET, POST, DELETE' });
    }

    let body: unknown;
    try {
      const raw = await readBody(req, MAX_MCP_BODY_BYTES);
      body = JSON.parse(raw.toString('utf8'));
    } catch (error) {
      if (error instanceof BodyTooLarge) return sendJson(res, 413, rpcError(-32000, 'Request body too large'), { Connection: 'close' });
      return sendJson(res, 400, rpcError(-32700, 'Parse error: invalid JSON'));
    }

    if (sessionId) {
      if (!existing) return sendJson(res, 404, rpcError(-32001, 'Session not found'));
      return existing.transport.handleRequest(req, res, body);
    }
    if (!isInitializeRequest(body)) {
      return sendJson(res, 400, rpcError(-32000, 'Bad Request: No valid session ID provided'));
    }

    const server = createMcpServer({ registry });
    const transport: StreamableHTTPServerTransport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (id) => {
        sessions.set(id, { transport, server });
        logger.info(`MCP session ${id.slice(0, 8)} opened (${sessions.size} active)`);
      }
    });
    transport.onclose = () => {
      const id = transport.sessionId;
      if (id && sessions.delete(id)) logger.info(`MCP session ${id.slice(0, 8)} closed (${sessions.size} active)`);
    };
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
    if (!transport.sessionId || !sessions.has(transport.sessionId)) await server.close();
  };

  const httpServer: Server = createServer((req, res) => {
    const problem = requestProblem(req);
    if (problem) {
      logger.warn(`refused ${req.method} ${req.url}: ${problem}`);
      return sendJson(res, 403, rpcError(-32000, problem));
    }
    const path = new URL(req.url ?? '/', 'http://localhost').pathname;
    if (path === '/mcp') {
      handleMcp(req, res).catch((error: unknown) => {
        logger.warn(`MCP request failed: ${error instanceof Error ? error.message : String(error)}`);
        sendJson(res, 500, rpcError(-32603, 'Internal server error'));
      });
      return;
    }
    if (path === '/app') {
      res.writeHead(426, { 'Content-Type': 'text/plain', Upgrade: 'websocket' });
      res.end('Apps connect here over WebSocket.\n');
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('donk-hub: MCP clients use /mcp, apps use /app (WebSocket).\n');
  });

  httpServer.on('upgrade', (req: IncomingMessage, socket: Duplex, head: Buffer) => {
    socket.on('error', () => {});
    const problem = requestProblem(req);
    if (problem) {
      logger.warn(`refused WebSocket ${req.url}: ${problem}`);
      return rejectUpgrade(socket, '403 Forbidden', problem);
    }
    const path = new URL(req.url ?? '/', 'http://localhost').pathname;
    if (path !== '/app') return rejectUpgrade(socket, '404 Not Found', 'WebSocket endpoint is /app');
    const remote = `${(socket as Socket).remoteAddress ?? 'unknown'}:${(socket as Socket).remotePort ?? ''}`;
    wss.handleUpgrade(req, socket, head, (ws) => registry.attach(ws, remote));
  });

  const requestedPort = options.port ?? DEFAULT_PORT;
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => reject(error);
    httpServer.once('error', onError);
    httpServer.listen(requestedPort, host, () => {
      httpServer.off('error', onError);
      resolve();
    });
  });

  const port = (httpServer.address() as AddressInfo).port;
  const authority = host.includes(':') ? `[${host}]:${port}` : `${host}:${port}`;
  const appURL = `ws://${authority}/app`;
  const mcpURL = `http://${authority}/mcp`;
  registry.appURL = appURL;

  let closing: Promise<void> | undefined;
  const close = () => {
    closing ??= (async () => {
      await Promise.allSettled([...sessions.values()].map((session) => session.transport.close()));
      sessions.clear();
      registry.close();
      await new Promise<void>((resolve) => wss.close(() => resolve()));
      await new Promise<void>((resolve) => {
        httpServer.close(() => resolve());
        httpServer.closeAllConnections();
      });
    })();
    return closing;
  };

  return {
    port,
    host,
    mcpURL,
    appURL,
    registry,
    mcpSessionCount: () => sessions.size,
    close
  };
}
