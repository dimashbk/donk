#!/usr/bin/env node
import { DEFAULT_PORT, startHub } from './hub.js';
import { HUB_VERSION } from './protocol.js';
import { consoleLogger } from './registry.js';

const USAGE = `donk-hub ${HUB_VERSION}

Usage: donk-hub [--port <port>]

  --port <port>   Port on 127.0.0.1 (default ${DEFAULT_PORT}, or DONK_HUB_PORT)
  --help          Show this help
`;

function parsePort(value: string | undefined, source: string): number {
  const port = Number(value);
  if (!value || !Number.isInteger(port) || port < 0 || port > 65535) {
    console.error(`donk-hub: invalid ${source} "${value ?? ''}"`);
    process.exit(2);
  }
  return port;
}

function resolvePort(argv: string[]): number {
  let port: number | undefined;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index] ?? '';
    if (arg === '--help' || arg === '-h') {
      process.stdout.write(USAGE);
      process.exit(0);
    } else if (arg === '--port' || arg === '-p') {
      port = parsePort(argv[++index], '--port');
    } else if (arg.startsWith('--port=')) {
      port = parsePort(arg.slice('--port='.length), '--port');
    } else {
      console.error(`donk-hub: unknown argument "${arg}"\n\n${USAGE}`);
      process.exit(2);
    }
  }
  if (port !== undefined) return port;
  const env = process.env.DONK_HUB_PORT;
  return env ? parsePort(env, 'DONK_HUB_PORT') : DEFAULT_PORT;
}

async function main(): Promise<void> {
  const port = resolvePort(process.argv.slice(2));
  let hub;
  try {
    hub = await startHub({ port, logger: consoleLogger });
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === 'EADDRINUSE') {
      console.error(`donk-hub: 127.0.0.1:${port} is already in use (another donk-hub?). Pick another port with --port or DONK_HUB_PORT.`);
    } else {
      console.error(`donk-hub: ${error instanceof Error ? error.message : String(error)}`);
    }
    process.exit(1);
  }
  consoleLogger.info(`${HUB_VERSION} listening: MCP ${hub.mcpURL} · apps ${hub.appURL}`);

  let stopping = false;
  const stop = (signal: string) => {
    if (stopping) process.exit(1);
    stopping = true;
    consoleLogger.info(`${signal}: shutting down`);
    const force = setTimeout(() => process.exit(0), 3000);
    force.unref();
    hub.close().then(() => process.exit(0), () => process.exit(1));
  };
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
}

void main();
