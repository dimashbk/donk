import { describe, expect, it } from 'vitest';
import { fixtureHello, fixtureScreenshotPNG } from '../src/dev/fixtures.js';
import { SERVER_INSTRUCTIONS } from '../src/tools.js';
import { callTool, fakeApp, mcpClient, testHub, textOf } from './helpers.js';

const TOOLS = ['donk_apps', 'donk_crash_get', 'donk_crash_list', 'donk_network_get', 'donk_network_list', 'donk_screenshot', 'donk_ui_tree'];

describe('MCP tools over the real hub', () => {
  it('lists the phase 1 tools, read-only, with instructions', async () => {
    const hub = await testHub();
    const client = await mcpClient(hub);
    const { tools } = await client.listTools();
    expect(tools.map((tool) => tool.name).sort()).toEqual(TOOLS);
    for (const tool of tools) expect(tool.annotations?.readOnlyHint).toBe(true);
    const list = tools.find((tool) => tool.name === 'donk_network_list');
    expect(Object.keys(list?.inputSchema.properties ?? {})).toEqual(['app', 'query', 'kinds', 'hosts', 'status', 'onlyModified', 'onlyPinned', 'limit', 'before']);
    expect(client.getInstructions()).toBe(SERVER_INSTRUCTIONS);
    expect(SERVER_INSTRUCTIONS).toContain('Start with donk_apps');
    expect(SERVER_INSTRUCTIONS).toContain('8 characters');
    expect(SERVER_INSTRUCTIONS).toContain('redacted');
    expect(SERVER_INSTRUCTIONS).toContain('read-only');
    expect(SERVER_INSTRUCTIONS).toContain('simulatorUDID');
  });

  it('donk_apps shows the connected app and its capture stats', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_apps'));
    const lines = text.split('\n');
    expect(lines[0]).toBe('1 connected · times UTC');
    expect(lines[2]).toBe('6F1C2A9B kz.globerce.fb — connected');
    expect(lines[3]).toBe('  Freedom Business 1.17.0 (1234) · donk 0.2.3');
    expect(lines[4]).toBe('  iPhone 17 Pro · simulator 39C8B439-5F1A-4C2D-9E3B-1A2B3C4D5E6F · iOS 26.0 · iPhone17,1');
    expect(lines[5]).toMatch(/^ {2}connected \d\d:\d\d:\d\d · app uptime 13m32s · capabilities network, crashes, ui$/);
    expect(lines[6]).toBe('  network: capture on · 7 entries · 4.9 MB · limit 1000 · rules on (1 active)');
    expect(lines[7]).toBe('  crashes: 2 reports');
  });

  it('donk_apps explains how to connect when nothing is connected', async () => {
    const hub = await testHub();
    const client = await mcpClient(hub);
    const result = await callTool(client, 'donk_apps');
    expect(result.isError).toBeFalsy();
    expect(textOf(result)).toBe(
      `No apps connected. A debug build with DonkConfiguration.remote.isEnabled = true dials ${hub.appURL} on launch (simulator only in phase 1).`
    );
  });

  it('donk_network_list renders one line per entry with footer', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_network_list'));
    expect(text.split('\n')).toEqual([
      '0A1B2C3D 09:41:09.555 GET … - /v1/profile api.example.com',
      'F9A8B7C6 09:41:08.020 GET 200 97ms /api/faq help.example.com [webView]',
      'E1E2E3E4 09:41:07.400 GET 200 3.2ms /img/logo.png cdn.example.com [mocked: Logo stub]',
      'D8C7B6A5 09:41:06.900 SERVER STREAM OK 5.32s NotificationService/Subscribe push.example.com',
      'C4D5E6F7 09:41:06.250 GET 500 1.24s /v1/accounts api.example.com',
      'B7E2D9A0 09:41:06.010 UNARY UNAVAILABLE 341ms AccountService/GetAccount api.example.com [pinned] ! connection reset',
      'A1F3C2D4 09:41:05.123 POST 200 182ms /v1/auth/login api.example.com',
      '',
      'total 7, showing 7 · times UTC'
    ]);
  });

  it('donk_network_list forwards filters and shows the before cursor', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_network_list', { limit: 2, hosts: ['api.example.com'] }));
    expect(app.requests.at(-1)?.params).toEqual({ limit: 2, hosts: ['api.example.com'] });
    expect(text.split('\n').at(-1)).toBe('total 4, showing 2 · older: before=C4D5E6F7-0819-4A2B-8C3D-4E5F60718293 · times UTC');
    const next = textOf(await callTool(client, 'donk_network_list', { limit: 2, hosts: ['api.example.com'], before: 'C4D5E6F7-0819-4A2B-8C3D-4E5F60718293' }));
    expect(next.split('\n').slice(0, 2).map((line) => line.slice(0, 8))).toEqual(['B7E2D9A0', 'A1F3C2D4']);
    expect(next.split('\n').at(-1)).toBe('total 4, showing 2 · times UTC');
    const errors = textOf(await callTool(client, 'donk_network_list', { status: ['serverError'], query: 'accounts' }));
    expect(errors.split('\n')[0]).toBe('C4D5E6F7 09:41:06.250 GET 500 1.24s /v1/accounts api.example.com');
    const none = textOf(await callTool(client, 'donk_network_list', { query: 'nothing-matches-this' }));
    expect(none).toBe('No captured entries match.');
  });

  it('donk_network_get renders an HTTP entry with headers, bodies and cURL', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_network_get', { id: 'a1f3c2d4' }));
    expect(text).toContain('A1F3C2D4-5B6E-4F70-8192-A3B4C5D6E7F8 · http · POST · /v1/auth/login');
    expect(text).toContain('url: https://api.example.com/v1/auth/login');
    expect(text).toContain('status: 200 (success) · 182ms · completed · started 09:41:05.123 UTC');
    expect(text).toContain('timing: h2 · remote 93.184.216.34 · new connection · response +167ms · end +182ms');
    expect(text).toContain('## Request\nPOST https://api.example.com/v1/auth/login\nContent-Type: application/json\nAccept-Language: ru\nX-Device-Id: ••••');
    expect(text).toContain('body: application/json, 64 B\n{\n  "phone": "+7 700 ••• •• 12",\n  "password": "••••"\n}');
    expect(text).toContain('## Response\nHTTP 200\nContent-Type: application/json; charset=utf-8');
    expect(text).toContain("## cURL\ncurl -X POST 'https://api.example.com/v1/auth/login'");
    expect(text).not.toContain('[truncated');
  });

  it('donk_network_get renders a failed gRPC call with metadata, timeline and grpcurl', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_network_get', { id: 'B7E2D9A0' }));
    expect(text).toContain('B7E2D9A0-1C3B-4D5E-9F60-718293A4B5C6 · gRPC · UNARY · AccountService/GetAccount');
    expect(text).toContain('status: UNAVAILABLE (serverError) · 341ms · failed · started 09:41:06.010 UTC · pinned');
    expect(text).toContain('error: connection reset (NSPOSIXErrorDomain 54)');
    expect(text).toContain('## gRPC\n/bank.v1.AccountService/GetAccount · unary · timeout 30s');
    expect(text).toContain('grpc-status: 14 UNAVAILABLE: upstream connect error or disconnect/reset before headers');
    expect(text).toContain('request metadata:\n  authorization: ••••\n  x-request-id: 5d0c7a4e');
    expect(text).toContain('trailers:\n  grpc-status: 14');
    expect(text).toContain('messages: 1 sent, 0 received\n+2ms → sent bank.v1.GetAccountRequest 12 B\n{\n  "accountId": "KZ12-0042"\n}');
    expect(text).toContain("## grpcurl\ngrpcurl -H 'authorization: ••••'");
    expect(text).not.toContain('## Response');
  });

  it('donk_network_get passes limits and marks truncated bodies and dropped messages', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const stream = textOf(await callTool(client, 'donk_network_get', { id: 'D8C7B6A5', maxMessages: 2, maxBodyBytes: 1024 }));
    expect(app.requests.at(-1)?.params).toEqual({ id: 'D8C7B6A5', maxMessages: 2, maxBodyBytes: 1024 });
    expect(stream).toContain('messages: 1 sent, 3 received (showing newest 2; raise maxMessages for more)');
    expect(stream).toContain('+2.2s ← received bank.v1.Notification 70 B\ntextFormat: id: "n2" title: "Payment sent"');
    const web = textOf(await callTool(client, 'donk_network_get', { id: 'F9A8B7C6' }));
    expect(web).toContain('web: page https://help.example.com/faq · fetch · capture full');
    expect(web).toContain('[truncated; original 4 KB; a larger maxBodyBytes (up to 1048576) may show more]');
    const image = textOf(await callTool(client, 'donk_network_get', { id: 'E1E2E3E4' }));
    expect(image).toContain('mocked by rule "Logo stub"');
    expect(image).toContain('body: binary, image/png, 18 KB, image');
  });

  it('donk_crash_list and donk_crash_get render reports', async () => {
    const hub = await testHub();
    await fakeApp(hub);
    const client = await mcpClient(hub);
    const list = textOf(await callTool(client, 'donk_crash_list'));
    expect(list.split('\n')).toEqual([
      'C0FFEE00 2026-10-21 18:02:11 signal EXC_BAD_ACCESS (SIGSEGV) — KERN_INVALID_ADDRESS at 0x0000000000000010 · v1.17.0 (1233) · iOS 26.0',
      'C1DEC0DE 2026-10-20 11:15:42 exception NSInvalidArgumentException — -[__NSCFNumber length]: unrecognized selector sent to instance 0x8f3c · v1.16.2 (1201) · iOS 26.0',
      '',
      '2 reports · times UTC'
    ]);
    const report = textOf(await callTool(client, 'donk_crash_get', { id: 'c0ffee00' }));
    expect(report.split('\n').slice(0, 5)).toEqual([
      'C0FFEE00-1234-4ABC-8DEF-0123456789AB · signal · 2026-10-21 18:02:11 UTC',
      'EXC_BAD_ACCESS (SIGSEGV)',
      'reason: KERN_INVALID_ADDRESS at 0x0000000000000010',
      'app v1.17.0 (1233) · iOS 26.0',
      ''
    ]);
    expect(report).toContain('Thread 0 Crashed:\n0   FreedomBusiness   0x0000000100a1b2c4 AccountsViewModel.reload() + 148');
  });

  it('donk_ui_tree renders the indented tree and controllers', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_ui_tree', { maxDepth: 10 }));
    expect(app.requests.at(-1)?.params).toEqual({ maxDepth: 10 });
    expect(text.split('\n')).toEqual([
      'screen 402×874 pt @3x · top LoginViewController · 14 nodes',
      '',
      'controllers:',
      'UINavigationController',
      '  LoginViewController "Вход"',
      '',
      'windows (back to front):',
      'UIWindow level 0 key (0,0 402×874)',
      '  UILayoutContainerView vc:UINavigationController (0,0 402×874)',
      '    UIView vc:LoginViewController (0,0 402×874)',
      '      UILabel "Вход" (16,120 370×34) [header staticText]',
      '      UIStackView (16,400 370×120)',
      '        UITextField placeholder:"Телефон" #login.phone (16,400 370×52) [tap]',
      '        UITextField "••••" #login.password (16,468 370×52) [tap]',
      '      UIButton "Войти" #login.button (16,620 343×52) [tap]',
      '      UIButton "Регистрация" #login.register (16,688 343×44) [tap disabled alpha 0.5]',
      '      _UIHostingView (16,748 370×44)',
      '        AXElement label:"Забыли пароль?" (140,758 122×24) [tap link]',
      '      UIScrollView (0,800 402×74) (+14 children beyond maxDepth)',
      'UITextEffectsWindow level 1 (0,0 402×874)',
      '  UIInputSetContainerView (0,0 402×874)'
    ]);
  });

  it('donk_ui_tree match keeps only branches leading to matches and is not sent to the app', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const text = textOf(await callTool(client, 'donk_ui_tree', { match: 'войти' }));
    expect(app.requests.at(-1)?.params).toEqual({});
    expect(text.split('\n')).toEqual([
      'screen 402×874 pt @3x · top LoginViewController · 14 nodes',
      '',
      '1 node matches "войти"; showing only branches leading to them:',
      'UIWindow level 0 key (0,0 402×874)',
      '  UILayoutContainerView vc:UINavigationController (0,0 402×874)',
      '    UIView vc:LoginViewController (0,0 402×874)',
      '      UIButton "Войти" #login.button (16,620 343×52) [tap]'
    ]);
  });

  it('donk_screenshot returns MCP image content', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const result = await callTool(client, 'donk_screenshot', { scale: 0.5, format: 'png' });
    expect(app.requests.at(-1)?.params).toEqual({ scale: 0.5, format: 'png' });
    expect(result.content[0]).toEqual({ type: 'image', data: fixtureScreenshotPNG, mimeType: 'image/png' });
    expect(textOf(result)).toBe('1×1 px, 0.5 px per point; divide pixel coordinates by 0.5 to get points.');
  });

  it('rejects arguments outside the app clamps before reaching the app', async () => {
    const hub = await testHub();
    const app = await fakeApp(hub);
    const client = await mcpClient(hub);
    const result = await callTool(client, 'donk_network_list', { limit: 5000 });
    expect(result.isError).toBe(true);
    expect(app.requests.filter((request) => request.method === 'network.list')).toHaveLength(0);
  });

  it('uses the fixture session in hello', () => {
    expect(fixtureHello.session.slice(0, 8)).toBe('6F1C2A9B');
  });
});
