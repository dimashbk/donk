function pad(value: number, width = 2): string {
  return String(value).padStart(width, '0');
}

function parseDate(iso?: string): Date | undefined {
  if (!iso) return undefined;
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? undefined : date;
}

export function formatClock(iso?: string): string {
  const date = parseDate(iso);
  if (!date) return '--:--:--.---';
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}.${pad(date.getMilliseconds(), 3)}`;
}

export function formatTime(date: Date): string {
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

export function formatDateTime(iso?: string): string {
  const date = parseDate(iso);
  if (!date) return iso ?? '-';
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${formatTime(date)}`;
}

export function offsetMs(from?: string, to?: string): number | undefined {
  const start = parseDate(from);
  const end = parseDate(to);
  if (!start || !end) return undefined;
  return end.getTime() - start.getTime();
}

export function timeZoneLabel(date = new Date()): string {
  const offset = -date.getTimezoneOffset();
  if (offset === 0) return 'UTC';
  const sign = offset > 0 ? '+' : '-';
  const abs = Math.abs(offset);
  return `UTC${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

function trimNumber(value: number, digits: number): string {
  return value.toFixed(digits).replace(/\.?0+$/, '');
}

export function formatDuration(ms?: number): string {
  if (ms === undefined || ms === null || !Number.isFinite(ms)) return '-';
  if (ms < 10) return `${trimNumber(ms, 1)}ms`;
  if (ms < 999.5) return `${Math.round(ms)}ms`;
  if (ms < 10_000) return `${trimNumber(ms / 1000, 2)}s`;
  if (ms < 60_000) return `${trimNumber(ms / 1000, 1)}s`;
  const total = Math.round(ms / 1000);
  return `${Math.floor(total / 60)}m${pad(total % 60)}s`;
}

export function formatOffset(ms?: number): string {
  if (ms === undefined) return '';
  return ms < 0 ? `-${formatDuration(-ms)}` : `+${formatDuration(ms)}`;
}

export function formatBytes(bytes?: number): string {
  if (bytes === undefined || bytes === null || !Number.isFinite(bytes)) return '?';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${trimNumber(bytes / 1024, 1)} KB`;
  return `${trimNumber(bytes / (1024 * 1024), 1)} MB`;
}

export function formatAgo(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${trimNumber(minutes / 60, 1)}h ago`;
}

export function formatUptime(seconds?: number): string | undefined {
  if (seconds === undefined || !Number.isFinite(seconds)) return undefined;
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours > 0) return `${hours}h${pad(minutes)}m`;
  if (minutes > 0) return `${minutes}m${pad(secs)}s`;
  return `${secs}s`;
}

export function shortId(id: string): string {
  return id.slice(0, 8);
}

export function clip(text: string, max: number): string {
  const single = text.replace(/\s+/g, ' ').trim();
  const chars = Array.from(single);
  return chars.length > max ? `${chars.slice(0, max - 1).join('')}…` : single;
}

export function quote(text: string, max = 80): string {
  return JSON.stringify(clip(text, max));
}

export function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : trimNumber(value, 1);
}
