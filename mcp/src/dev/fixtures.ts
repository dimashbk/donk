import {
  AppErrorCode,
  type AppInfoResult,
  type Body,
  type CrashSummary,
  type HelloParams,
  type NetworkDetail,
  type NetworkListParams,
  type NetworkListResult,
  type NetworkSummary,
  type ScreenshotResult,
  type UINode,
  type UITreeResult
} from '../protocol.js';

export class FakeAppError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown
  ) {
    super(message);
  }
}

export type Handler = (params: Record<string, unknown>) => unknown;

export const fixtureHello: HelloParams = {
  protocol: 1,
  session: '6F1C2A9B-3D4E-4F50-8A61-7B2C3D4E5F60',
  donkVersion: '0.2.3',
  app: {
    name: 'Freedom Business',
    bundleID: 'kz.globerce.fb',
    version: '1.17.0',
    build: '1234',
    osVersion: '26.0',
    deviceModel: 'iPhone17,1'
  },
  device: { name: 'iPhone 17 Pro', isSimulator: true, simulatorUDID: '39C8B439-5F1A-4C2D-9E3B-1A2B3C4D5E6F' },
  capabilities: ['network', 'crashes', 'ui']
};

const json = (value: unknown): Body => {
  const text = JSON.stringify(value, null, 2);
  return { contentType: 'application/json', size: Buffer.byteLength(JSON.stringify(value)), truncated: false, encoding: 'text', text };
};

const login: NetworkDetail = {
  id: 'A1F3C2D4-5B6E-4F70-8192-A3B4C5D6E7F8',
  kind: 'http',
  state: 'completed',
  origin: 'network',
  method: 'POST',
  title: '/v1/auth/login',
  url: 'https://api.example.com/v1/auth/login',
  host: 'api.example.com',
  status: '200',
  statusCategory: 'success',
  startedAt: '2026-10-22T09:41:05.123Z',
  durationMs: 182.4,
  requestSize: 64,
  responseSize: 41,
  pinned: false,
  request: {
    url: 'https://api.example.com/v1/auth/login',
    method: 'POST',
    headers: [
      { name: 'Content-Type', value: 'application/json' },
      { name: 'Accept-Language', value: 'ru' },
      { name: 'X-Device-Id', value: '••••' }
    ],
    body: json({ phone: '+7 700 ••• •• 12', password: '••••' })
  },
  response: {
    statusCode: 200,
    headers: [
      { name: 'Content-Type', value: 'application/json; charset=utf-8' },
      { name: 'Set-Cookie', value: '••••' }
    ],
    body: json({ token: '••••', expiresIn: 3600 })
  },
  timing: {
    startedAt: '2026-10-22T09:41:05.123Z',
    responseStartedAt: '2026-10-22T09:41:05.290Z',
    endedAt: '2026-10-22T09:41:05.305Z',
    durationMs: 182.4,
    protocol: 'h2',
    remoteAddress: '93.184.216.34',
    reusedConnection: false
  },
  curl: "curl -X POST 'https://api.example.com/v1/auth/login' \\\n  -H 'Content-Type: application/json' \\\n  -H 'Accept-Language: ru' \\\n  -H 'X-Device-Id: ••••' \\\n  --data-raw '{\"phone\":\"+7 700 ••• •• 12\",\"password\":\"••••\"}'"
};

const getAccount: NetworkDetail = {
  id: 'B7E2D9A0-1C3B-4D5E-9F60-718293A4B5C6',
  kind: 'grpc',
  state: 'failed',
  origin: 'network',
  method: 'UNARY',
  title: 'AccountService/GetAccount',
  url: 'grpc://api.example.com/bank.v1.AccountService/GetAccount',
  host: 'api.example.com',
  status: 'UNAVAILABLE',
  statusCategory: 'serverError',
  startedAt: '2026-10-22T09:41:06.010Z',
  durationMs: 341.2,
  requestSize: 12,
  responseSize: 0,
  error: 'connection reset',
  pinned: true,
  request: {
    url: 'grpc://api.example.com/bank.v1.AccountService/GetAccount',
    method: 'POST',
    headers: [{ name: 'content-type', value: 'application/grpc' }]
  },
  errorInfo: { domain: 'NSPOSIXErrorDomain', code: 54, message: 'connection reset' },
  timing: { startedAt: '2026-10-22T09:41:06.010Z', endedAt: '2026-10-22T09:41:06.351Z', durationMs: 341.2 },
  grpc: {
    service: 'bank.v1.AccountService',
    method: 'GetAccount',
    statusCode: 14,
    statusName: 'UNAVAILABLE',
    statusMessage: 'upstream connect error or disconnect/reset before headers',
    path: '/bank.v1.AccountService/GetAccount',
    callType: 'unary',
    timeoutSec: 30,
    requestMetadata: [
      { name: 'authorization', value: '••••' },
      { name: 'x-request-id', value: '5d0c7a4e' }
    ],
    responseHeaders: [],
    trailers: [
      { name: 'grpc-status', value: '14' },
      { name: 'grpc-message', value: 'upstream connect error or disconnect/reset before headers' }
    ],
    sentMessageCount: 1,
    receivedMessageCount: 0,
    droppedMessageCount: 0,
    messages: [
      {
        direction: 'sent',
        timestamp: '2026-10-22T09:41:06.012Z',
        typeName: 'bank.v1.GetAccountRequest',
        size: 12,
        json: '{\n  "accountId": "KZ12-0042"\n}'
      }
    ]
  },
  grpcurl:
    "grpcurl -H 'authorization: ••••' -H 'x-request-id: 5d0c7a4e' -d '{\"accountId\":\"KZ12-0042\"}' api.example.com:443 bank.v1.AccountService/GetAccount"
};

const accounts: NetworkDetail = {
  id: 'C4D5E6F7-0819-4A2B-8C3D-4E5F60718293',
  kind: 'http',
  state: 'completed',
  origin: 'network',
  method: 'GET',
  title: '/v1/accounts',
  url: 'https://api.example.com/v1/accounts?page=1',
  host: 'api.example.com',
  status: '500',
  statusCategory: 'serverError',
  startedAt: '2026-10-22T09:41:06.250Z',
  durationMs: 1243.7,
  requestSize: 0,
  responseSize: 48,
  pinned: false,
  request: {
    url: 'https://api.example.com/v1/accounts?page=1',
    method: 'GET',
    headers: [
      { name: 'Authorization', value: '••••' },
      { name: 'Accept', value: 'application/json' }
    ]
  },
  response: {
    statusCode: 500,
    headers: [{ name: 'Content-Type', value: 'application/json' }],
    body: json({ error: 'internal', message: 'Счёт временно недоступен', traceId: '7f3a9c' })
  },
  timing: {
    startedAt: '2026-10-22T09:41:06.250Z',
    responseStartedAt: '2026-10-22T09:41:07.480Z',
    endedAt: '2026-10-22T09:41:07.494Z',
    durationMs: 1243.7,
    protocol: 'h2',
    remoteAddress: '93.184.216.34',
    reusedConnection: true
  },
  curl: "curl 'https://api.example.com/v1/accounts?page=1' \\\n  -H 'Authorization: ••••' \\\n  -H 'Accept: application/json'"
};

const subscribe: NetworkDetail = {
  id: 'D8C7B6A5-9483-4726-B150-F4E3D2C1B0A9',
  kind: 'grpc',
  state: 'completed',
  origin: 'network',
  method: 'SERVER STREAM',
  title: 'NotificationService/Subscribe',
  url: 'grpc://push.example.com/bank.v1.NotificationService/Subscribe',
  host: 'push.example.com',
  status: 'OK',
  statusCategory: 'success',
  startedAt: '2026-10-22T09:41:06.900Z',
  durationMs: 5320,
  requestSize: 8,
  responseSize: 214,
  pinned: false,
  request: {
    url: 'grpc://push.example.com/bank.v1.NotificationService/Subscribe',
    method: 'POST',
    headers: [{ name: 'content-type', value: 'application/grpc' }]
  },
  timing: { startedAt: '2026-10-22T09:41:06.900Z', endedAt: '2026-10-22T09:41:12.220Z', durationMs: 5320, protocol: 'h2' },
  grpc: {
    service: 'bank.v1.NotificationService',
    method: 'Subscribe',
    statusCode: 0,
    statusName: 'OK',
    path: '/bank.v1.NotificationService/Subscribe',
    callType: 'serverStreaming',
    requestMetadata: [{ name: 'authorization', value: '••••' }],
    responseHeaders: [{ name: 'content-type', value: 'application/grpc' }],
    trailers: [{ name: 'grpc-status', value: '0' }],
    sentMessageCount: 1,
    receivedMessageCount: 3,
    droppedMessageCount: 0,
    messages: [
      { direction: 'sent', timestamp: '2026-10-22T09:41:06.902Z', typeName: 'bank.v1.SubscribeRequest', size: 8, json: '{\n  "topics": ["payments"]\n}' },
      { direction: 'received', timestamp: '2026-10-22T09:41:07.950Z', typeName: 'bank.v1.Notification', size: 71, json: '{\n  "id": "n1",\n  "title": "Платёж получен"\n}' },
      { direction: 'received', timestamp: '2026-10-22T09:41:09.100Z', typeName: 'bank.v1.Notification', size: 70, textFormat: 'id: "n2" title: "Payment sent"' },
      { direction: 'received', timestamp: '2026-10-22T09:41:12.200Z', typeName: 'bank.v1.Notification', size: 73, json: '{\n  "id": "n3",\n  "title": "Card blocked"\n}' }
    ]
  },
  grpcurl: "grpcurl -H 'authorization: ••••' -d '{\"topics\":[\"payments\"]}' push.example.com:443 bank.v1.NotificationService/Subscribe"
};

const logo: NetworkDetail = {
  id: 'E1E2E3E4-F5A6-47B8-89CA-DBECFD0E1F20',
  kind: 'http',
  state: 'completed',
  origin: 'mocked',
  rule: 'Logo stub',
  method: 'GET',
  title: '/img/logo.png',
  url: 'https://cdn.example.com/img/logo.png',
  host: 'cdn.example.com',
  status: '200',
  statusCategory: 'success',
  startedAt: '2026-10-22T09:41:07.400Z',
  durationMs: 3.2,
  requestSize: 0,
  responseSize: 18432,
  pinned: false,
  request: { url: 'https://cdn.example.com/img/logo.png', method: 'GET', headers: [{ name: 'Accept', value: 'image/*' }] },
  response: {
    statusCode: 200,
    headers: [{ name: 'Content-Type', value: 'image/png' }],
    body: { contentType: 'image/png', size: 18432, truncated: false, encoding: 'binary', image: true }
  },
  timing: { startedAt: '2026-10-22T09:41:07.400Z', endedAt: '2026-10-22T09:41:07.403Z', durationMs: 3.2 },
  curl: "curl 'https://cdn.example.com/img/logo.png' \\\n  -H 'Accept: image/*'"
};

const faq: NetworkDetail = {
  id: 'F9A8B7C6-D5E4-4F30-A2B1-C0D9E8F7A6B5',
  kind: 'webView',
  state: 'completed',
  origin: 'network',
  method: 'GET',
  title: '/api/faq',
  url: 'https://help.example.com/api/faq?lang=ru',
  host: 'help.example.com',
  status: '200',
  statusCategory: 'success',
  startedAt: '2026-10-22T09:41:08.020Z',
  durationMs: 96.5,
  requestSize: 0,
  responseSize: 4096,
  pinned: false,
  request: { url: 'https://help.example.com/api/faq?lang=ru', method: 'GET', headers: [{ name: 'Accept', value: '*/*' }] },
  response: {
    statusCode: 200,
    headers: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }],
    body: { contentType: 'text/html', size: 4096, truncated: true, encoding: 'text', text: '<!doctype html><html><head><title>FAQ</title></head><body><h1>Вопросы и ответы</h1>' }
  },
  timing: { startedAt: '2026-10-22T09:41:08.020Z', endedAt: '2026-10-22T09:41:08.116Z', durationMs: 96.5 },
  web: { pageURL: 'https://help.example.com/faq', initiator: 'fetch', captureLevel: 'full' },
  curl: "curl 'https://help.example.com/api/faq?lang=ru' \\\n  -H 'Accept: */*'"
};

const profile: NetworkDetail = {
  id: '0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9',
  kind: 'http',
  state: 'pending',
  origin: 'network',
  method: 'GET',
  title: '/v1/profile',
  url: 'https://api.example.com/v1/profile',
  host: 'api.example.com',
  status: '…',
  statusCategory: 'pending',
  startedAt: '2026-10-22T09:41:09.555Z',
  requestSize: 0,
  responseSize: 0,
  pinned: false,
  request: { url: 'https://api.example.com/v1/profile', method: 'GET', headers: [{ name: 'Authorization', value: '••••' }] },
  timing: { startedAt: '2026-10-22T09:41:09.555Z' },
  curl: "curl 'https://api.example.com/v1/profile' \\\n  -H 'Authorization: ••••'"
};

export const fixtureEntries: NetworkDetail[] = [profile, faq, logo, subscribe, accounts, getAccount, login];

const DETAIL_ONLY = ['request', 'response', 'errorInfo', 'timing', 'web', 'curl', 'grpcurl'] as const;

export function toSummary(entry: NetworkDetail): NetworkSummary {
  const summary: Record<string, unknown> = { ...entry };
  for (const key of DETAIL_ONLY) delete summary[key];
  if (entry.grpc) {
    const { service, method, statusCode, statusName, statusMessage, sentMessageCount, receivedMessageCount } = entry.grpc;
    const messages = (sentMessageCount ?? 0) + (receivedMessageCount ?? 0);
    summary.grpc = { service, method, statusCode, statusName, ...(statusMessage ? { statusMessage } : {}), messages };
  }
  return summary as unknown as NetworkSummary;
}

export const fixtureCrashes: Array<CrashSummary & { text: string }> = [
  {
    id: 'C0FFEE00-1234-4ABC-8DEF-0123456789AB',
    date: '2026-10-21T18:02:11.480Z',
    kind: 'signal',
    title: 'EXC_BAD_ACCESS (SIGSEGV)',
    reason: 'KERN_INVALID_ADDRESS at 0x0000000000000010',
    appVersion: '1.17.0',
    appBuild: '1233',
    osVersion: '26.0',
    text: [
      'Incident Identifier: C0FFEE00-1234-4ABC-8DEF-0123456789AB',
      'Hardware Model:      iPhone17,1',
      'Process:             FreedomBusiness [4242]',
      'Version:             1.17.0 (1233)',
      'OS Version:          iOS 26.0',
      '',
      'Exception Type:  EXC_BAD_ACCESS (SIGSEGV)',
      'Exception Codes: KERN_INVALID_ADDRESS at 0x0000000000000010',
      '',
      'Thread 0 Crashed:',
      '0   FreedomBusiness   0x0000000100a1b2c4 AccountsViewModel.reload() + 148',
      '1   FreedomBusiness   0x0000000100a1a010 AccountsViewController.viewWillAppear(_:) + 64',
      '2   UIKitCore         0x00000001a2b3c4d0 -[UIViewController _setViewAppearState:isAnimating:] + 652'
    ].join('\n')
  },
  {
    id: 'C1DEC0DE-5678-4DEF-9ABC-FEDCBA987654',
    date: '2026-10-20T11:15:42.007Z',
    kind: 'exception',
    title: 'NSInvalidArgumentException',
    reason: '-[__NSCFNumber length]: unrecognized selector sent to instance 0x8f3c',
    appVersion: '1.16.2',
    appBuild: '1201',
    osVersion: '26.0',
    text: [
      'Exception: NSInvalidArgumentException',
      'Reason: -[__NSCFNumber length]: unrecognized selector sent to instance 0x8f3c',
      '',
      'Last Exception Backtrace:',
      '0   CoreFoundation    __exceptionPreprocess + 164',
      '1   libobjc.A.dylib   objc_exception_throw + 88',
      '2   FreedomBusiness   ProfileFormatter.format(_:) + 212'
    ].join('\n')
  }
];

const loginButton: UINode = {
  class: 'UIButton',
  frame: { x: 16, y: 620, width: 343, height: 52 },
  id: 'login.button',
  label: 'Войти',
  text: 'Войти',
  traits: ['button'],
  interactive: true,
  hidden: false,
  alpha: 1
};

const loginScreen: UINode = {
  class: 'UILayoutContainerView',
  frame: { x: 0, y: 0, width: 402, height: 874 },
  interactive: false,
  alpha: 1,
  viewController: 'UINavigationController',
  children: [
    {
      class: 'UIView',
      frame: { x: 0, y: 0, width: 402, height: 874 },
      viewController: 'LoginViewController',
      alpha: 1,
      children: [
        { class: 'UILabel', frame: { x: 16, y: 120, width: 370, height: 34 }, text: 'Вход', traits: ['header', 'staticText'], alpha: 1 },
        {
          class: 'UIStackView',
          frame: { x: 16, y: 400, width: 370, height: 120 },
          alpha: 1,
          children: [
            {
              class: 'UITextField',
              frame: { x: 16, y: 400, width: 370, height: 52 },
              id: 'login.phone',
              text: 'Телефон',
              placeholder: true,
              interactive: true,
              alpha: 1
            },
            {
              class: 'UITextField',
              frame: { x: 16, y: 468, width: 370, height: 52 },
              id: 'login.password',
              text: '••••',
              interactive: true,
              alpha: 1
            }
          ]
        },
        loginButton,
        {
          class: 'UIButton',
          frame: { x: 16, y: 688, width: 343, height: 44 },
          id: 'login.register',
          text: 'Регистрация',
          traits: ['button', 'notEnabled'],
          interactive: true,
          alpha: 0.5
        },
        {
          class: '_UIHostingView',
          frame: { x: 16, y: 748, width: 370, height: 44 },
          alpha: 1,
          children: [
            { class: 'AXElement', frame: { x: 140, y: 758, width: 122, height: 24 }, label: 'Забыли пароль?', traits: ['link'], interactive: true }
          ]
        },
        { class: 'UIScrollView', frame: { x: 0, y: 800, width: 402, height: 74 }, alpha: 1, childrenOmitted: 14 }
      ]
    }
  ]
};

export const fixtureTree: UITreeResult = {
  screen: { width: 402, height: 874, scale: 3 },
  topViewController: 'LoginViewController',
  controllers: {
    class: 'UINavigationController',
    children: [{ class: 'LoginViewController', title: 'Вход' }]
  },
  windows: [
    {
      class: 'UIWindow',
      frame: { x: 0, y: 0, width: 402, height: 874 },
      level: 0,
      isKey: true,
      root: {
        class: 'UIWindow',
        frame: { x: 0, y: 0, width: 402, height: 874 },
        alpha: 1,
        children: [loginScreen]
      }
    },
    {
      class: 'UITextEffectsWindow',
      frame: { x: 0, y: 0, width: 402, height: 874 },
      level: 1,
      isKey: false,
      root: {
        class: 'UITextEffectsWindow',
        frame: { x: 0, y: 0, width: 402, height: 874 },
        alpha: 1,
        children: [{ class: 'UIInputSetContainerView', frame: { x: 0, y: 0, width: 402, height: 874 }, alpha: 1 }]
      }
    }
  ],
  nodeCount: 14,
  truncated: false
};

export const fixtureScreenshotPNG =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

export function fixtureAppInfo(hello: HelloParams = fixtureHello): AppInfoResult {
  return {
    app: hello.app,
    device: hello.device,
    ...(hello.donkVersion ? { donkVersion: hello.donkVersion } : {}),
    session: hello.session,
    uptimeSec: 812.4,
    network: { captureEnabled: true, entries: fixtureEntries.length, totalBytes: 5_120_000, limit: 1000 },
    rules: { enabled: true, active: 1 },
    crashes: { installed: true, reports: fixtureCrashes.length }
  };
}

function findById<T extends { id: string }>(items: T[], id: unknown, what: string): T {
  if (typeof id !== 'string' || id.length < 8) {
    throw new FakeAppError(AppErrorCode.invalidParams, 'id must be the full id or a prefix of at least 8 characters');
  }
  const needle = id.toUpperCase();
  const matches = items.filter((item) => item.id.toUpperCase().startsWith(needle));
  const [match] = matches;
  if (matches.length > 1) throw new FakeAppError(AppErrorCode.ambiguous, `Id prefix ${id} matches ${matches.length} ${what}s`);
  if (!match) throw new FakeAppError(AppErrorCode.notFound, `No ${what} with id ${id}`);
  return match;
}

function clampNumber(value: unknown, fallback: number, min: number, max: number): number {
  const number = typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  return Math.min(max, Math.max(min, number));
}

function cutText(text: string, maxBytes: number): { text: string; cut: boolean } {
  if (Buffer.byteLength(text) <= maxBytes) return { text, cut: false };
  let bytes = 0;
  let result = '';
  for (const scalar of text) {
    const size = Buffer.byteLength(scalar);
    if (bytes + size > maxBytes) break;
    bytes += size;
    result += scalar;
  }
  return { text: result, cut: true };
}

function cutBody(body: Body | undefined, maxBytes: number): Body | undefined {
  if (!body || body.text === undefined) return body;
  const { text, cut } = cutText(body.text, maxBytes);
  return { ...body, text, truncated: body.truncated || cut };
}

function listEntries(entries: NetworkDetail[], params: NetworkListParams): NetworkListResult {
  const terms = (params.query ?? '').toLowerCase().split(/\s+/).filter(Boolean);
  const hosts = new Set((params.hosts ?? []).map((host) => host.toLowerCase()));
  const filtered = entries.filter((entry) => {
    if (params.kinds?.length && !params.kinds.includes(entry.kind)) return false;
    if (hosts.size && !hosts.has((entry.host ?? '').toLowerCase())) return false;
    if (params.status?.length && !params.status.includes(entry.statusCategory ?? '')) return false;
    if (params.onlyModified && entry.origin === 'network') return false;
    if (params.onlyPinned && !entry.pinned) return false;
    const haystack = [entry.url, entry.method, entry.status, entry.error, entry.grpc?.path, entry.grpc?.statusMessage, entry.response?.body?.text]
      .filter(Boolean)
      .join('\n')
      .toLowerCase();
    return terms.every((term) => haystack.includes(term));
  });
  let start = 0;
  if (typeof params.before === 'string') {
    const cursor = findById(filtered, params.before, 'network entry');
    start = filtered.indexOf(cursor) + 1;
  }
  const limit = clampNumber(params.limit, 50, 1, 500);
  const page = filtered.slice(start, start + limit);
  const last = page[page.length - 1];
  const hasMore = start + limit < filtered.length;
  return { total: filtered.length, entries: page.map(toSummary), ...(hasMore && last ? { nextBefore: last.id } : {}) };
}

export interface FixtureData {
  hello: HelloParams;
  entries: NetworkDetail[];
  crashes: Array<CrashSummary & { text: string }>;
  tree: UITreeResult;
}

export function fixtureHandlers(data: Partial<FixtureData> = {}): Record<string, Handler> {
  const hello = data.hello ?? fixtureHello;
  const entries = data.entries ?? fixtureEntries;
  const crashes = data.crashes ?? fixtureCrashes;
  const tree = data.tree ?? fixtureTree;
  return {
    'app.info': () => fixtureAppInfo(hello),
    'network.list': (params) => listEntries(entries, params as NetworkListParams),
    'network.get': (params) => {
      const entry = findById(entries, params.id, 'network entry');
      const maxBytes = clampNumber(params.maxBodyBytes, 65_536, 1024, 1_048_576);
      const maxMessages = clampNumber(params.maxMessages, 50, 0, 1000);
      const detail: NetworkDetail = structuredClone(entry);
      if (detail.request) detail.request.body = cutBody(detail.request.body, maxBytes);
      if (detail.response) detail.response.body = cutBody(detail.response.body, maxBytes);
      if (detail.grpc?.messages) {
        detail.grpc.messages = detail.grpc.messages.slice(Math.max(0, detail.grpc.messages.length - maxMessages)).map((message) => {
          if (message.json === undefined) return message;
          const { text, cut } = cutText(message.json, maxBytes);
          return cut ? { ...message, json: text, truncated: true } : message;
        });
      }
      for (const key of Object.keys(detail) as Array<keyof NetworkDetail>) {
        if (detail[key] === undefined) delete detail[key];
      }
      return { entry: detail };
    },
    'crashes.list': (params) => {
      const limit = clampNumber(params.limit, 20, 1, 200);
      return { reports: crashes.slice(0, limit).map(({ text: _text, ...summary }) => summary) };
    },
    'crashes.get': (params) => ({ report: findById(crashes, params.id, 'crash report') }),
    'ui.tree': () => tree,
    'ui.screenshot': (): ScreenshotResult => ({ mimeType: 'image/png', width: 1, height: 1, data: fixtureScreenshotPNG })
  };
}
