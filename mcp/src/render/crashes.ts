import type { CrashGetResult, CrashListResult, CrashSummary } from '../protocol.js';
import { clip, formatDateTime, shortId, timeZoneLabel } from './format.js';

function buildLabel(report: CrashSummary): string | undefined {
  if (!report.appVersion) return undefined;
  return report.appBuild ? `v${report.appVersion} (${report.appBuild})` : `v${report.appVersion}`;
}

export function renderCrashLine(report: CrashSummary): string {
  const parts = [shortId(report.id), formatDateTime(report.date), report.kind ?? '-', report.title ?? '-'];
  let line = parts.join(' ');
  if (report.reason) line += ` — ${clip(report.reason, 160)}`;
  const meta = [buildLabel(report), report.osVersion ? `iOS ${report.osVersion}` : undefined].filter(Boolean);
  if (meta.length) line += ` · ${meta.join(' · ')}`;
  return line;
}

export function renderCrashList(result: CrashListResult): string {
  const reports = result.reports ?? [];
  if (reports.length === 0) return 'No crash reports.';
  const lines = reports.map(renderCrashLine);
  lines.push('', `${reports.length} ${reports.length === 1 ? 'report' : 'reports'} · times ${timeZoneLabel()}`);
  return lines.join('\n');
}

export function renderCrashDetail(result: CrashGetResult): string {
  const report = result.report;
  const lines = [[report.id, report.kind, `${formatDateTime(report.date)} ${timeZoneLabel()}`].filter(Boolean).join(' · ')];
  if (report.title) lines.push(report.title);
  if (report.reason) lines.push(`reason: ${report.reason}`);
  const meta = [buildLabel(report), report.osVersion ? `iOS ${report.osVersion}` : undefined].filter(Boolean);
  if (meta.length) lines.push(`app ${meta.join(' · ')}`);
  lines.push('', report.text ?? '(no report text)');
  return lines.join('\n');
}
