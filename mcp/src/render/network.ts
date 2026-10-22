import type { Body, GrpcDetail, Header, NetworkDetail, NetworkListResult, NetworkSummary } from '../protocol.js';
import {
  clip,
  formatBytes,
  formatClock,
  formatDuration,
  formatOffset,
  offsetMs,
  shortId,
  timeZoneLabel
} from './format.js';

const MAX_BODY_BYTES_LIMIT = 1_048_576;

function entryTags(entry: NetworkSummary): string[] {
  const tags: string[] = [];
  if (entry.kind === 'webView') tags.push('[webView]');
  if (entry.origin && entry.origin !== 'network') {
    tags.push(entry.rule ? `[${entry.origin}: ${entry.rule}]` : `[${entry.origin}]`);
  }
  if (entry.pinned) tags.push('[pinned]');
  if (entry.error) tags.push(`! ${clip(entry.error, 100)}`);
  return tags;
}

export function renderNetworkLine(entry: NetworkSummary, id = shortId(entry.id)): string {
  const fields = [
    id,
    formatClock(entry.startedAt),
    entry.method || '-',
    entry.status || '-',
    formatDuration(entry.durationMs),
    entry.title || entry.url || '-',
    entry.host || '-',
    ...entryTags(entry)
  ];
  return fields.join(' ');
}

function displayIds(entries: NetworkSummary[]): string[] {
  const counts = new Map<string, number>();
  for (const entry of entries) {
    const key = shortId(entry.id).toUpperCase();
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return entries.map((entry) => ((counts.get(shortId(entry.id).toUpperCase()) ?? 0) > 1 ? entry.id : shortId(entry.id)));
}

export function renderNetworkList(result: NetworkListResult): string {
  const entries = result.entries ?? [];
  const lines: string[] = [];
  if (entries.length === 0) {
    lines.push(result.total > 0 ? `No entries on this page (total ${result.total}).` : 'No captured entries match.');
    return lines.join('\n');
  }
  const ids = displayIds(entries);
  entries.forEach((entry, index) => lines.push(renderNetworkLine(entry, ids[index])));
  const footer = [`total ${result.total}, showing ${entries.length}`];
  if (result.nextBefore) footer.push(`older: before=${result.nextBefore}`);
  footer.push(`times ${timeZoneLabel()}`);
  lines.push('', footer.join(' · '));
  return lines.join('\n');
}

function renderHeaders(headers: Header[] | undefined, indent = ''): string[] {
  return (headers ?? []).map((header) => `${indent}${header.name}: ${header.value}`);
}

export function renderBody(body: Body | undefined): string[] {
  if (!body) return ['(no body)'];
  const size = body.size ?? 0;
  if (body.encoding === 'binary') {
    const parts = ['body: binary', body.contentType, formatBytes(size), body.image ? 'image' : undefined];
    return [parts.filter(Boolean).join(', ')];
  }
  if (!body.text && size === 0) return ['(empty body)'];
  const lines = [[`body: ${body.contentType ?? 'unknown type'}`, formatBytes(size)].join(', ')];
  if (body.text !== undefined) lines.push(body.text);
  if (body.truncated) {
    lines.push(`[truncated; original ${formatBytes(size)}; a larger maxBodyBytes (up to ${MAX_BODY_BYTES_LIMIT}) may show more]`);
  }
  return lines;
}

function headerLine(entry: NetworkDetail): string {
  const kind = entry.kind === 'grpc' ? 'gRPC' : entry.kind;
  return [entry.id, kind, entry.method, entry.title].filter(Boolean).join(' · ');
}

function statusLine(entry: NetworkDetail): string {
  const status = entry.statusCategory ? `${entry.status ?? '-'} (${entry.statusCategory})` : entry.status ?? '-';
  const parts = [`status: ${status}`, formatDuration(entry.durationMs ?? entry.timing?.durationMs)];
  if (entry.state) parts.push(entry.state);
  parts.push(`started ${formatClock(entry.startedAt ?? entry.timing?.startedAt)} ${timeZoneLabel()}`);
  if (entry.origin && entry.origin !== 'network') parts.push(entry.rule ? `${entry.origin} by rule "${entry.rule}"` : entry.origin);
  if (entry.pinned) parts.push('pinned');
  return parts.join(' · ');
}

function timingLine(entry: NetworkDetail): string | undefined {
  const timing = entry.timing;
  if (!timing) return undefined;
  const parts: string[] = [];
  if (timing.protocol) parts.push(timing.protocol);
  if (timing.remoteAddress) parts.push(`remote ${timing.remoteAddress}`);
  if (timing.reusedConnection !== undefined) parts.push(timing.reusedConnection ? 'reused connection' : 'new connection');
  const start = timing.startedAt ?? entry.startedAt;
  const response = offsetMs(start, timing.responseStartedAt);
  if (response !== undefined) parts.push(`response ${formatOffset(response)}`);
  const end = offsetMs(start, timing.endedAt);
  if (end !== undefined) parts.push(`end ${formatOffset(end)}`);
  return parts.length ? `timing: ${parts.join(' · ')}` : undefined;
}

function grpcSection(grpc: GrpcDetail, startedAt?: string): string[] {
  const lines = ['## gRPC'];
  const call = [grpc.path ?? [grpc.service, grpc.method].filter(Boolean).join('/'), grpc.callType];
  if (grpc.timeoutSec !== undefined) call.push(`timeout ${grpc.timeoutSec}s`);
  lines.push(call.filter(Boolean).join(' · '));
  if (grpc.statusCode !== undefined || grpc.statusName) {
    const status = [grpc.statusCode, grpc.statusName].filter((part) => part !== undefined).join(' ');
    lines.push(`grpc-status: ${status}${grpc.statusMessage ? `: ${grpc.statusMessage}` : ''}`);
  }
  const groups: Array<[string, Header[] | undefined]> = [
    ['request metadata', grpc.requestMetadata],
    ['response headers', grpc.responseHeaders],
    ['trailers', grpc.trailers]
  ];
  for (const [title, headers] of groups) {
    if (headers && headers.length) lines.push(`${title}:`, ...renderHeaders(headers, '  '));
  }
  const messages = grpc.messages ?? [];
  const sent = grpc.sentMessageCount ?? 0;
  const received = grpc.receivedMessageCount ?? 0;
  const dropped = grpc.droppedMessageCount ?? 0;
  const counts = [`${sent} sent`, `${received} received`];
  if (dropped) counts.push(`${dropped} dropped by donk`);
  let summary = `messages: ${counts.join(', ')}`;
  if (messages.length < sent + received - dropped) summary += ` (showing newest ${messages.length}; raise maxMessages for more)`;
  lines.push(summary);
  for (const message of messages) {
    const arrow = message.direction === 'sent' ? '→ sent' : '← received';
    const head = [formatOffset(offsetMs(startedAt, message.timestamp)), arrow, message.typeName, message.size !== undefined ? formatBytes(message.size) : undefined];
    lines.push(head.filter(Boolean).join(' '));
    if (message.json !== undefined) lines.push(message.json);
    else if (message.textFormat !== undefined) lines.push(`textFormat: ${message.textFormat}`);
    if (message.truncated) lines.push(`[truncated; a larger maxBodyBytes (up to ${MAX_BODY_BYTES_LIMIT}) may show more]`);
  }
  return lines;
}

export function renderNetworkDetail(entry: NetworkDetail): string {
  const lines = [headerLine(entry)];
  const url = entry.url ?? entry.request?.url;
  if (url) lines.push(`url: ${url}`);
  lines.push(statusLine(entry));
  if (entry.errorInfo) {
    const info = entry.errorInfo;
    lines.push(`error: ${info.message ?? entry.error ?? ''} (${[info.domain, info.code].filter((part) => part !== undefined).join(' ')})`);
  } else if (entry.error) {
    lines.push(`error: ${entry.error}`);
  }
  const timing = timingLine(entry);
  if (timing) lines.push(timing);
  if (entry.requestSize !== undefined || entry.responseSize !== undefined) {
    lines.push(`size: request ${formatBytes(entry.requestSize ?? 0)} · response ${formatBytes(entry.responseSize ?? 0)}`);
  }
  if (entry.web) {
    const web = [entry.web.pageURL ? `page ${entry.web.pageURL}` : undefined, entry.web.initiator, entry.web.captureLevel ? `capture ${entry.web.captureLevel}` : undefined];
    lines.push(`web: ${web.filter(Boolean).join(' · ')}`);
  }

  if (entry.request) {
    lines.push('', '## Request', `${entry.request.method ?? entry.method ?? ''} ${entry.request.url ?? url ?? ''}`.trim());
    lines.push(...renderHeaders(entry.request.headers));
    lines.push('', ...renderBody(entry.request.body));
  }

  if (entry.response) {
    lines.push('', '## Response');
    if (entry.response.statusCode !== undefined) lines.push(`HTTP ${entry.response.statusCode}`);
    lines.push(...renderHeaders(entry.response.headers));
    lines.push('', ...renderBody(entry.response.body));
  } else if (entry.kind !== 'grpc') {
    lines.push('', '## Response', '(no response)');
  }

  if (entry.grpc) lines.push('', ...grpcSection(entry.grpc, entry.timing?.startedAt ?? entry.startedAt));
  if (entry.curl) lines.push('', '## cURL', entry.curl);
  if (entry.grpcurl) lines.push('', '## grpcurl', entry.grpcurl);
  return lines.join('\n');
}
