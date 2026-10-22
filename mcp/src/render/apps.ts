import type { AppInfo, AppInfoResult, DeviceInfo, HelloParams } from '../protocol.js';
import { formatAgo, formatBytes, formatTime, formatUptime, shortId, timeZoneLabel } from './format.js';

export interface AppSnapshot {
  session: string;
  hello: HelloParams;
  connectedAt: Date;
  lastSeen: Date;
  disconnectedAt?: Date;
  connected: boolean;
}

export interface AppReport {
  app: AppSnapshot;
  info?: AppInfoResult;
  infoError?: string;
}

function appTitle(app: AppInfo): string {
  const version = app.version ? ` ${app.version}${app.build ? ` (${app.build})` : ''}` : '';
  return `${app.name}${version}`;
}

function deviceLine(device: DeviceInfo, app: AppInfo): string {
  const parts = [device.name ?? 'unknown device'];
  if (device.isSimulator) parts.push(device.simulatorUDID ? `simulator ${device.simulatorUDID}` : 'simulator');
  else if (device.isSimulator === false) parts.push('device');
  if (app.osVersion) parts.push(`iOS ${app.osVersion}`);
  if (app.deviceModel) parts.push(app.deviceModel);
  return parts.join(' · ');
}

export function appSummaryLine(hello: HelloParams): string {
  const parts = [shortId(hello.session), hello.app.bundleID, appTitle(hello.app)];
  if (hello.device.name) parts.push(hello.device.name);
  if (hello.device.simulatorUDID) parts.push(`simulator ${hello.device.simulatorUDID}`);
  return parts.join('  ');
}

function statsLines(info: AppInfoResult): string[] {
  const lines: string[] = [];
  const network = info.network;
  if (network) {
    const parts = [network.captureEnabled === false ? 'capture off' : 'capture on'];
    if (network.entries !== undefined) parts.push(`${network.entries} entries`);
    if (network.totalBytes !== undefined) parts.push(formatBytes(network.totalBytes));
    if (network.limit !== undefined) parts.push(`limit ${network.limit}`);
    if (info.rules) parts.push(`rules ${info.rules.enabled ? 'on' : 'off'} (${info.rules.active ?? 0} active)`);
    lines.push(`network: ${parts.join(' · ')}`);
  }
  if (info.crashes) {
    lines.push(info.crashes.installed === false ? 'crashes: DonkCrash not installed' : `crashes: ${info.crashes.reports ?? 0} reports`);
  }
  return lines;
}

function renderApp(report: AppReport, now: Date): string[] {
  const { app, info } = report;
  const hello = { ...app.hello, app: info?.app ?? app.hello.app, device: info?.device ?? app.hello.device };
  const state = app.connected
    ? 'connected'
    : `disconnected ${formatTime(app.disconnectedAt ?? app.lastSeen)} (${formatAgo(now.getTime() - app.lastSeen.getTime())}); tools reach it again once it reconnects`;
  const lines = [`${shortId(app.session)} ${hello.app.bundleID} — ${state}`];
  const indent = '  ';
  const donkVersion = info?.donkVersion ?? hello.donkVersion;
  lines.push(`${indent}${appTitle(hello.app)}${donkVersion ? ` · donk ${donkVersion}` : ''}`);
  lines.push(`${indent}${deviceLine(hello.device, hello.app)}`);
  const timing = [`connected ${formatTime(app.connectedAt)}`];
  const uptime = formatUptime(info?.uptimeSec);
  if (uptime) timing.push(`app uptime ${uptime}`);
  if (hello.capabilities?.length) timing.push(`capabilities ${hello.capabilities.join(', ')}`);
  lines.push(`${indent}${timing.join(' · ')}`);
  if (info) lines.push(...statsLines(info).map((line) => `${indent}${line}`));
  if (report.infoError) lines.push(`${indent}app.info failed: ${report.infoError}`);
  return lines;
}

export function renderApps(reports: AppReport[], options: { now: Date; appURL: string }): string {
  const connected = reports.filter((report) => report.app.connected);
  const disconnected = reports.filter((report) => !report.app.connected);
  if (reports.length === 0) {
    return `No apps connected. A debug build with DonkConfiguration.remote.isEnabled = true dials ${options.appURL} on launch (simulator only in phase 1).`;
  }
  const summary = [`${connected.length} connected`];
  if (disconnected.length) summary.push(`${disconnected.length} recently disconnected`);
  const lines = [`${summary.join(', ')} · times ${timeZoneLabel(options.now)}`];
  for (const report of [...connected, ...disconnected]) lines.push('', ...renderApp(report, options.now));
  if (connected.length > 1) lines.push('', 'Several apps are connected: pass app (session prefix, bundleID or simulatorUDID) to the other tools.');
  return lines.join('\n');
}
