import { WebSocket } from 'ws';
import { AppErrorCode, type AppInfo, type DeviceInfo, type HelloParams, type JsonRpcMessage } from '../protocol.js';
import { FakeAppError, fixtureHandlers, fixtureHello, type Handler } from './fixtures.js';

export interface FakeAppOptions {
  url: string;
  hello?: Partial<Omit<HelloParams, 'app' | 'device'>> & { app?: Partial<AppInfo>; device?: Partial<DeviceInfo> };
  handlers?: Record<string, Handler>;
  autoPong?: boolean;
  log?: (line: string) => void;
}

export interface CloseInfo {
  code: number;
  reason: string;
}

export interface ReceivedRequest {
  id: string;
  method: string;
  params: Record<string, unknown>;
}

export class FakeApp {
  readonly hello: HelloParams;
  readonly requests: ReceivedRequest[] = [];
  readonly closed: Promise<CloseInfo>;
  welcome?: { protocol: number; hub: string };
  rejectedReason?: string;
  private readonly ws: WebSocket;
  private readonly handlers: Record<string, Handler>;
  private readonly log: (line: string) => void;
  private readonly requestListeners: Array<(request: ReceivedRequest) => void> = [];

  static async connect(options: FakeAppOptions): Promise<FakeApp> {
    const app = new FakeApp(options);
    await app.ready;
    return app;
  }

  readonly ready: Promise<void>;

  constructor(options: FakeAppOptions) {
    const override = options.hello ?? {};
    this.hello = {
      ...fixtureHello,
      ...override,
      app: { ...fixtureHello.app, ...override.app },
      device: { ...fixtureHello.device, ...override.device }
    };
    this.handlers = { ...fixtureHandlers({ hello: this.hello }), ...options.handlers };
    this.log = options.log ?? (() => {});
    this.ws = new WebSocket(options.url, { autoPong: options.autoPong ?? true, perMessageDeflate: false });

    this.closed = new Promise<CloseInfo>((resolve) => {
      this.ws.on('close', (code, reason) => resolve({ code, reason: reason.toString('utf8') }));
    });

    this.ready = new Promise<void>((resolve, reject) => {
      this.ws.on('open', () => this.send({ jsonrpc: '2.0', method: 'hello', params: this.hello }));
      this.ws.on('error', (error) => reject(error));
      this.ws.on('message', (data) => {
        let message: JsonRpcMessage;
        try {
          message = JSON.parse(data.toString()) as JsonRpcMessage;
        } catch {
          return;
        }
        if (message.method === 'welcome') {
          this.welcome = message.params as { protocol: number; hub: string };
          resolve();
          return;
        }
        if (message.method === 'rejected') {
          this.rejectedReason = String((message.params as { reason?: unknown } | undefined)?.reason ?? '');
          reject(new Error(`rejected: ${this.rejectedReason}`));
          return;
        }
        if (message.method && message.id !== undefined && message.id !== null) {
          void this.handleRequest({ id: String(message.id), method: message.method, params: (message.params ?? {}) as Record<string, unknown> });
        }
      });
      void this.closed.then(({ code, reason }) => reject(new Error(`closed before welcome: ${code} ${reason}`)));
    });
    this.ready.catch(() => {});
  }

  get session(): string {
    return this.hello.session;
  }

  get readyState(): number {
    return this.ws.readyState;
  }

  onRequest(listener: (request: ReceivedRequest) => void): void {
    this.requestListeners.push(listener);
  }

  nextRequest(method?: string): Promise<ReceivedRequest> {
    return new Promise((resolve) => {
      this.requestListeners.push((request) => {
        if (!method || request.method === method) resolve(request);
      });
    });
  }

  close(code = 1000, reason = ''): Promise<CloseInfo> {
    if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) this.ws.close(code, reason);
    return this.closed;
  }

  terminate(): Promise<CloseInfo> {
    this.ws.terminate();
    return this.closed;
  }

  private send(message: object): void {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(message));
  }

  private async handleRequest(request: ReceivedRequest): Promise<void> {
    this.requests.push(request);
    for (const listener of this.requestListeners) listener(request);
    this.log(`← ${request.method} ${JSON.stringify(request.params)}`);
    const handler = this.handlers[request.method];
    if (!handler) {
      this.send({ jsonrpc: '2.0', id: request.id, error: { code: AppErrorCode.methodNotFound, message: `Unknown method ${request.method}` } });
      return;
    }
    try {
      const result = await handler(request.params);
      this.send({ jsonrpc: '2.0', id: request.id, result });
    } catch (error) {
      const code = error instanceof FakeAppError ? error.code : -32603;
      const message = error instanceof Error ? error.message : String(error);
      this.log(`  error ${code}: ${message}`);
      this.send({ jsonrpc: '2.0', id: request.id, error: { code, message } });
    }
  }
}
