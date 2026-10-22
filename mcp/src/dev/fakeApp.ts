import { DEFAULT_PORT } from '../hub.js';
import { FakeApp } from './fakeAppClient.js';

const USAGE = `npm run fake-app -- [--port <port>] [--url <ws url>] [--session <uuid>] [--bundle-id <id>] [--name <app name>]

Connects to a running donk-hub as a fake app with fixture data (HTTP + gRPC entries, crashes, UI tree, screenshot).
Reconnects with the app's backoff (1, 2, 4, 8, 16, 30 s) until Ctrl-C.`;

function option(argv: string[], name: string): string | undefined {
  const index = argv.indexOf(name);
  if (index >= 0) return argv[index + 1];
  const inline = argv.find((arg) => arg.startsWith(`${name}=`));
  return inline?.slice(name.length + 1);
}

const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.includes('-h')) {
  console.log(USAGE);
  process.exit(0);
}

const port = option(argv, '--port') ?? process.env.DONK_HUB_PORT ?? String(DEFAULT_PORT);
const url = option(argv, '--url') ?? `ws://127.0.0.1:${port}/app`;
const session = option(argv, '--session');
const bundleID = option(argv, '--bundle-id');
const name = option(argv, '--name');

const delays = [1, 2, 4, 8, 16, 30];
let attempt = 0;
let current: FakeApp | undefined;
let stopping = false;

const sleep = (seconds: number) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

async function run(): Promise<void> {
  while (!stopping) {
    const app = new FakeApp({
      url,
      hello: {
        ...(session ? { session } : {}),
        app: { ...(bundleID ? { bundleID } : {}), ...(name ? { name } : {}) }
      },
      log: (line) => console.log(line)
    });
    current = app;
    try {
      await app.ready;
      attempt = 0;
      console.log(`connected to ${url} as ${app.hello.app.name} (${app.hello.app.bundleID}, session ${app.session}); hub ${app.welcome?.hub ?? '?'}`);
      const closed = await app.closed;
      if (stopping) return;
      console.log(`disconnected (${closed.code}${closed.reason ? ` ${closed.reason}` : ''})`);
    } catch (error) {
      if (app.rejectedReason !== undefined) {
        console.error(`hub rejected the app: ${app.rejectedReason}`);
        process.exit(1);
      }
      if (stopping) return;
      console.log(`cannot connect to ${url}: ${error instanceof Error ? error.message : String(error)}`);
    }
    const delay = delays[Math.min(attempt, delays.length - 1)] ?? 30;
    attempt += 1;
    console.log(`retrying in ${delay} s`);
    await sleep(delay);
  }
}

const stop = () => {
  if (stopping) process.exit(0);
  stopping = true;
  void (current?.close() ?? Promise.resolve()).then(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);

void run();
