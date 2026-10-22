import { WebSocket, type RawData } from 'ws';
import {
  AppErrorCode,
  HUB_VERSION,
  SUPPORTED_PROTOCOLS,
  type HelloParams,
  type JsonRpcError,
  type JsonRpcId,
  type JsonRpcMessage
} from './protocol.js';
import { appSummaryLine, type AppSnapshot } from './render/apps.js';
import { formatTime, shortId } from './render/format.js';

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
}

export const silentLogger: Logger = { info() {}, warn() {} };

export const consoleLogger: Logger = {
  info: (message) => console.error(`[donk-hub] ${message}`),
  warn: (message) => console.error(`[donk-hub] warning: ${message}`)
};

export interface RegistryOptions {
  requestTimeoutMs?: number;
  pingIntervalMs?: number;
  maxMissedPongs?: number;
  helloTimeoutMs?: number;
  retentionMs?: number;
  logger?: Logger;
}

export const CLOSE_REJECTED = 4000;
export const CLOSE_REPLACED = 4001;

const CODE_NAMES: Record<number, string> = {
  [AppErrorCode.invalidRequest]: 'invalid request',
  [AppErrorCode.methodNotFound]: 'unknown method',
  [AppErrorCode.invalidParams]: 'invalid params',
  [AppErrorCode.notFound]: 'not found',
  [AppErrorCode.unavailable]: 'unavailable',
  [AppErrorCode.ambiguous]: 'ambiguous id prefix'
};

export class HubError extends Error {
  override name = 'HubError';
}

export class AppRequestError extends Error {
  override name = 'AppRequestError';

  constructor(
    readonly method: string,
    readonly code: number,
    readonly appMessage: string,
    readonly data?: unknown
  ) {
    const codeName = CODE_NAMES[code];
    super(`${appMessage} (app error ${code}${codeName ? ` ${codeName}` : ''})`);
  }
}

interface Pending {
  method: string;
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer: NodeJS.Timeout;
}

export function appLabel(hello: HelloParams): string {
  return `${hello.app.name} (${hello.app.bundleID}, ${shortId(hello.session)})`;
}

export class AppConnection {
  private seq = 0;
  private readonly pending = new Map<string, Pending>();
  private failure?: string;

  constructor(
    readonly ws: WebSocket,
    readonly hello: HelloParams,
    readonly connectedAt: Date,
    private readonly timeoutMs: number
  ) {}

  get label(): string {
    return appLabel(this.hello);
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.failure !== undefined || this.ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new HubError(`${this.label} is not connected`));
    }
    const id = String(++this.seq);
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        reject(new HubError(`${method} timed out after ${formatSeconds(this.timeoutMs)}: ${this.label} did not answer`));
      }, this.timeoutMs);
      this.pending.set(id, { method, resolve: resolve as (value: unknown) => void, reject, timer });
      this.ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }), (error) => {
        if (error) this.settle(id, undefined, new HubError(`Could not send ${method} to ${this.label}: ${error.message}`));
      });
    });
  }

  handleResponse(message: JsonRpcMessage): boolean {
    if (message.id === undefined || message.id === null) return false;
    const id = String(message.id);
    const pending = this.pending.get(id);
    if (!pending) return false;
    if (message.error) {
      const error = message.error as Partial<JsonRpcError>;
      this.settle(id, undefined, new AppRequestError(pending.method, Number(error.code ?? 0), String(error.message ?? 'Unknown app error'), error.data));
    } else {
      this.settle(id, message.result ?? null);
    }
    return true;
  }

  fail(reason: string): void {
    this.failure ??= reason;
    for (const [id, pending] of [...this.pending]) {
      this.settle(id, undefined, new HubError(`${reason} before answering ${pending.method}`));
    }
  }

  private settle(id: string, result: unknown, error?: Error): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    clearTimeout(pending.timer);
    if (error) pending.reject(error);
    else pending.resolve(result);
  }
}

function formatSeconds(ms: number): string {
  return ms >= 1000 ? `${Number((ms / 1000).toFixed(1))} s` : `${ms} ms`;
}

interface AppRecord {
  session: string;
  hello: HelloParams;
  connectedAt: Date;
  lastSeen: Date;
  disconnectedAt?: Date;
  connection?: AppConnection;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function helloProblem(params: unknown): string | undefined {
  if (!isObject(params)) return 'hello params must be an object';
  if (typeof params.protocol !== 'number') return 'hello.protocol must be a number';
  if (typeof params.session !== 'string' || params.session.trim() === '') return 'hello.session must be a non-empty string';
  if (!isObject(params.app) || typeof params.app.bundleID !== 'string' || typeof params.app.name !== 'string') {
    return 'hello.app must include name and bundleID';
  }
  if (params.device !== undefined && !isObject(params.device)) return 'hello.device must be an object';
  if (params.capabilities !== undefined && !Array.isArray(params.capabilities)) return 'hello.capabilities must be an array';
  return undefined;
}

function decode(data: RawData): string {
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8');
  return Buffer.from(data).toString('utf8');
}

function closeReason(text: string): string {
  let reason = text;
  while (Buffer.byteLength(reason) > 120) reason = reason.slice(0, -1);
  return reason;
}

export class AppRegistry {
  private readonly records = new Map<string, AppRecord>();
  private readonly sockets = new Set<WebSocket>();
  private readonly requestTimeoutMs: number;
  private readonly pingIntervalMs: number;
  private readonly maxMissedPongs: number;
  private readonly helloTimeoutMs: number;
  private readonly retentionMs: number;
  private readonly logger: Logger;
  appURL = 'ws://127.0.0.1:7337/app';

  constructor(options: RegistryOptions = {}) {
    this.requestTimeoutMs = options.requestTimeoutMs ?? 15_000;
    this.pingIntervalMs = options.pingIntervalMs ?? 20_000;
    this.maxMissedPongs = options.maxMissedPongs ?? 2;
    this.helloTimeoutMs = options.helloTimeoutMs ?? 10_000;
    this.retentionMs = options.retentionMs ?? 10 * 60_000;
    this.logger = options.logger ?? silentLogger;
  }

  attach(ws: WebSocket, remote = 'unknown'): void {
    this.sockets.add(ws);
    let connection: AppConnection | undefined;
    let awaitingPong = false;
    let missedPongs = 0;

    const send = (message: object) => {
      if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
    };
    const sendError = (id: JsonRpcId, code: number, message: string) => send({ jsonrpc: '2.0', id, error: { code, message } });
    const reject = (reason: string) => {
      this.logger.warn(`rejected app from ${remote}: ${reason}`);
      send({ jsonrpc: '2.0', method: 'rejected', params: { reason } });
      ws.close(CLOSE_REJECTED, closeReason(reason));
    };
    const touch = () => {
      awaitingPong = false;
      missedPongs = 0;
      if (connection) {
        const record = this.records.get(connection.hello.session.toUpperCase());
        if (record?.connection === connection) record.lastSeen = new Date();
      }
    };

    const helloTimer = setTimeout(() => {
      if (!connection) {
        this.logger.warn(`app from ${remote} sent no hello within ${formatSeconds(this.helloTimeoutMs)}`);
        ws.close(1008, 'hello expected');
      }
    }, this.helloTimeoutMs);

    const pingTimer = setInterval(() => {
      if (awaitingPong) missedPongs += 1;
      if (missedPongs >= this.maxMissedPongs) {
        this.logger.warn(`${connection?.label ?? `app from ${remote}`} missed ${missedPongs} pings; dropping it`);
        ws.terminate();
        return;
      }
      awaitingPong = true;
      if (ws.readyState === WebSocket.OPEN) ws.ping();
    }, this.pingIntervalMs);

    const handleHello = (params: unknown) => {
      const problem = helloProblem(params);
      if (problem) return reject(`Invalid hello: ${problem}`);
      const hello = params as unknown as HelloParams;
      hello.device = hello.device ?? {};
      if (!SUPPORTED_PROTOCOLS.includes(hello.protocol)) {
        return reject(`Unsupported protocol ${hello.protocol}: donk-hub ${HUB_VERSION} speaks protocol ${SUPPORTED_PROTOCOLS.join(', ')}. Update donk or donk-hub so they match.`);
      }
      clearTimeout(helloTimer);
      const key = hello.session.toUpperCase();
      const existing = this.records.get(key)?.connection;
      if (existing) {
        existing.fail(`${existing.label} was replaced by a new connection of the same session`);
        existing.ws.close(CLOSE_REPLACED, 'replaced by a new connection');
        this.logger.info(`${existing.label} reconnected; replacing the old connection`);
      }
      const now = new Date();
      connection = new AppConnection(ws, hello, now, this.requestTimeoutMs);
      this.records.set(key, { session: hello.session, hello, connectedAt: now, lastSeen: now, connection });
      send({ jsonrpc: '2.0', method: 'welcome', params: { protocol: hello.protocol, hub: HUB_VERSION } });
      if (!existing) this.logger.info(`${connection.label} connected from ${remote}`);
    };

    ws.on('pong', touch);

    ws.on('message', (data) => {
      touch();
      let message: unknown;
      try {
        message = JSON.parse(decode(data));
      } catch {
        sendError(null, -32700, 'Parse error');
        return;
      }
      if (!isObject(message)) {
        sendError(null, AppErrorCode.invalidRequest, 'Expected one JSON-RPC message object per frame');
        return;
      }
      const rpc = message as JsonRpcMessage;
      const hasId = rpc.id !== undefined && rpc.id !== null;
      if (!connection) {
        if (rpc.method === 'hello') handleHello(rpc.params);
        else if (hasId && rpc.method) sendError(rpc.id ?? null, AppErrorCode.invalidRequest, 'Send hello first');
        return;
      }
      if (rpc.method === undefined) {
        if (!connection.handleResponse(rpc)) this.logger.warn(`${connection.label} answered unknown request id ${String(rpc.id)}`);
        return;
      }
      if (rpc.method === 'hello') return;
      if (hasId) sendError(rpc.id ?? null, AppErrorCode.methodNotFound, `Method not found: ${rpc.method}`);
    });

    ws.on('close', (code, reason) => {
      clearTimeout(helloTimer);
      clearInterval(pingTimer);
      this.sockets.delete(ws);
      if (!connection) return;
      const detail = `close ${code}${reason.length ? ` ${reason.toString('utf8')}` : ''}`;
      const record = this.records.get(connection.hello.session.toUpperCase());
      if (record?.connection === connection) {
        const now = new Date();
        record.connection = undefined;
        record.disconnectedAt = now;
        record.lastSeen = now;
        this.logger.info(`${connection.label} disconnected (${detail})`);
      }
      connection.fail(`${connection.label} disconnected (${detail})`);
    });

    ws.on('error', (error) => {
      this.logger.warn(`socket error from ${connection?.label ?? remote}: ${error.message}`);
    });
  }

  private prune(): void {
    const now = Date.now();
    for (const [key, record] of this.records) {
      if (!record.connection && record.disconnectedAt && now - record.disconnectedAt.getTime() > this.retentionMs) {
        this.records.delete(key);
      }
    }
  }

  snapshots(): AppSnapshot[] {
    this.prune();
    return [...this.records.values()]
      .map((record) => ({
        session: record.session,
        hello: record.hello,
        connectedAt: record.connectedAt,
        lastSeen: record.connection ? new Date() : record.lastSeen,
        ...(record.disconnectedAt && !record.connection ? { disconnectedAt: record.disconnectedAt } : {}),
        connected: record.connection !== undefined
      }))
      .sort((a, b) => Number(b.connected) - Number(a.connected) || b.connectedAt.getTime() - a.connectedAt.getTime());
  }

  connection(session: string): AppConnection | undefined {
    return this.records.get(session.toUpperCase())?.connection;
  }

  connections(): AppConnection[] {
    return [...this.records.values()]
      .flatMap((record) => (record.connection ? [record.connection] : []))
      .sort((a, b) => b.connectedAt.getTime() - a.connectedAt.getTime());
  }

  resolve(selector?: string): AppConnection {
    const connected = this.connections();
    const wanted = selector?.trim();
    if (!wanted) {
      const [only] = connected;
      if (connected.length === 1 && only) return only;
      if (connected.length === 0) throw new HubError(this.noAppsMessage());
      throw new HubError(`${connected.length} apps are connected; pass app (session prefix, bundleID or simulatorUDID):\n${listApps(connected.map((c) => c.hello))}`);
    }
    const needle = wanted.toUpperCase();
    const matches = connected.filter((conn) => matchesSelector(conn.hello, needle));
    const [match] = matches;
    if (matches.length === 1 && match) return match;
    if (matches.length > 1) {
      throw new HubError(`"${wanted}" matches ${matches.length} connected apps; pass a session prefix or simulatorUDID instead:\n${listApps(matches.map((c) => c.hello))}`);
    }
    this.prune();
    const gone = [...this.records.values()].find((record) => !record.connection && matchesSelector(record.hello, needle));
    if (gone) {
      const when = gone.disconnectedAt ? ` at ${formatTime(gone.disconnectedAt)}` : '';
      const others = connected.length ? `\nConnected apps:\n${listApps(connected.map((c) => c.hello))}` : '';
      throw new HubError(`${appLabel(gone.hello)} disconnected${when}; it reconnects by itself while the app is running.${others}`);
    }
    if (connected.length === 0) throw new HubError(`No connected app matches "${wanted}". ${this.noAppsMessage()}`);
    throw new HubError(`No connected app matches "${wanted}". Connected apps:\n${listApps(connected.map((c) => c.hello))}`);
  }

  noAppsMessage(): string {
    const recent = this.snapshots().filter((snapshot) => !snapshot.connected);
    const base = `No apps are connected to donk-hub. A debug build with DonkConfiguration.remote.isEnabled = true dials ${this.appURL} on launch.`;
    if (!recent.length) return base;
    return `${base}\nRecently disconnected:\n${listApps(recent.map((snapshot) => snapshot.hello))}`;
  }

  close(): void {
    for (const conn of this.connections()) conn.fail(`${conn.label} disconnected (hub shutting down)`);
    for (const ws of this.sockets) {
      ws.close(1001, 'hub shutting down');
      setTimeout(() => ws.terminate(), 1000).unref();
    }
    this.sockets.clear();
  }
}

function matchesSelector(hello: HelloParams, needle: string): boolean {
  const session = hello.session.toUpperCase();
  const udid = hello.device.simulatorUDID?.toUpperCase();
  if (session === needle || hello.app.bundleID.toUpperCase() === needle || udid === needle) return true;
  if (needle.length < 8) return false;
  return session.startsWith(needle) || (udid !== undefined && udid.startsWith(needle));
}

function listApps(hellos: HelloParams[]): string {
  return hellos.map((hello) => `  ${appSummaryLine(hello)}`).join('\n');
}
