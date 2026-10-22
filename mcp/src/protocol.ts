export const HUB_VERSION = '0.1.0';
export const SUPPORTED_PROTOCOLS: readonly number[] = [1];

export const AppErrorCode = {
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  notFound: -32000,
  unavailable: -32001,
  ambiguous: -32002
} as const;

export interface AppInfo {
  name: string;
  bundleID: string;
  version?: string;
  build?: string;
  osVersion?: string;
  deviceModel?: string;
}

export interface DeviceInfo {
  name?: string;
  isSimulator?: boolean;
  simulatorUDID?: string;
}

export interface HelloParams {
  protocol: number;
  session: string;
  donkVersion?: string;
  app: AppInfo;
  device: DeviceInfo;
  capabilities?: string[];
}

export interface AppInfoResult {
  app?: AppInfo;
  device?: DeviceInfo;
  donkVersion?: string;
  session?: string;
  uptimeSec?: number;
  network?: { captureEnabled?: boolean; entries?: number; totalBytes?: number; limit?: number };
  rules?: { enabled?: boolean; active?: number };
  crashes?: { installed?: boolean; reports?: number };
}

export interface Header {
  name: string;
  value: string;
}

export interface GrpcSummary {
  service?: string;
  method?: string;
  statusCode?: number;
  statusName?: string;
  statusMessage?: string;
  messages?: number;
}

export interface NetworkSummary {
  id: string;
  kind: string;
  state?: string;
  origin?: string;
  rule?: string;
  method?: string;
  title?: string;
  url?: string;
  host?: string;
  status?: string;
  statusCategory?: string;
  startedAt?: string;
  durationMs?: number;
  requestSize?: number;
  responseSize?: number;
  error?: string;
  pinned?: boolean;
  grpc?: GrpcSummary;
}

export interface NetworkListParams {
  query?: string;
  kinds?: string[];
  hosts?: string[];
  status?: string[];
  onlyModified?: boolean;
  onlyPinned?: boolean;
  limit?: number;
  before?: string;
}

export interface NetworkListResult {
  total: number;
  entries: NetworkSummary[];
  nextBefore?: string;
}

export interface Body {
  contentType?: string;
  size?: number;
  truncated?: boolean;
  encoding?: string;
  text?: string;
  image?: boolean;
}

export interface GrpcMessage {
  direction: string;
  timestamp?: string;
  typeName?: string;
  size?: number;
  json?: string;
  textFormat?: string;
  truncated?: boolean;
}

export interface GrpcDetail extends Omit<GrpcSummary, 'messages'> {
  path?: string;
  callType?: string;
  timeoutSec?: number;
  requestMetadata?: Header[];
  responseHeaders?: Header[];
  trailers?: Header[];
  sentMessageCount?: number;
  receivedMessageCount?: number;
  droppedMessageCount?: number;
  messages?: GrpcMessage[];
}

export interface NetworkDetail extends Omit<NetworkSummary, 'grpc'> {
  request?: { url?: string; method?: string; headers?: Header[]; body?: Body };
  response?: { statusCode?: number; headers?: Header[]; body?: Body };
  errorInfo?: { domain?: string; code?: number; message?: string };
  timing?: {
    startedAt?: string;
    responseStartedAt?: string;
    endedAt?: string;
    durationMs?: number;
    protocol?: string;
    remoteAddress?: string;
    reusedConnection?: boolean;
  };
  grpc?: GrpcDetail;
  web?: { pageURL?: string; initiator?: string; captureLevel?: string };
  curl?: string;
  grpcurl?: string;
}

export interface NetworkGetResult {
  entry: NetworkDetail;
}

export interface CrashSummary {
  id: string;
  date?: string;
  kind?: string;
  title?: string;
  reason?: string;
  appVersion?: string;
  appBuild?: string;
  osVersion?: string;
}

export interface CrashListResult {
  reports: CrashSummary[];
}

export interface CrashGetResult {
  report: CrashSummary & { text?: string };
}

export interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface UINode {
  class: string;
  frame?: Frame;
  id?: string;
  label?: string;
  text?: string;
  placeholder?: boolean;
  value?: string;
  traits?: string[];
  interactive?: boolean;
  hidden?: boolean;
  alpha?: number;
  viewController?: string;
  childrenOmitted?: number;
  children?: UINode[];
}

export interface ControllerNode {
  class: string;
  title?: string;
  children?: ControllerNode[];
  presented?: ControllerNode;
}

export interface UIWindowNode {
  class: string;
  frame?: Frame;
  level?: number;
  isKey?: boolean;
  root?: UINode;
}

export interface UITreeResult {
  screen?: { width: number; height: number; scale?: number };
  topViewController?: string;
  controllers?: ControllerNode;
  windows: UIWindowNode[];
  nodeCount?: number;
  truncated?: boolean;
}

export interface ScreenshotResult {
  mimeType: string;
  width?: number;
  height?: number;
  data: string;
}

export type JsonRpcId = string | number | null;

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export interface JsonRpcMessage {
  jsonrpc?: string;
  id?: JsonRpcId;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: JsonRpcError;
}
