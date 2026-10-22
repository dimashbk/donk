import { describe, expect, it } from 'vitest';
import { fixtureEntries, fixtureTree, toSummary } from '../src/dev/fixtures.js';
import type { NetworkDetail, NetworkSummary, UITreeResult } from '../src/protocol.js';
import { clip, formatBytes, formatDuration } from '../src/render/format.js';
import { renderBody, renderNetworkDetail, renderNetworkLine, renderNetworkList } from '../src/render/network.js';
import { nodeMatches, renderNodeLine, renderUITree } from '../src/render/ui.js';

const summary = (overrides: Partial<NetworkSummary> = {}): NetworkSummary => ({
  id: '12345678-ABCD-4EF0-8123-456789ABCDEF',
  kind: 'http',
  method: 'GET',
  title: '/v1/items',
  host: 'api.example.com',
  status: '404',
  statusCategory: 'clientError',
  startedAt: '2026-10-22T09:41:05.007Z',
  durationMs: 12.6,
  ...overrides
});

describe('network list lines', () => {
  it('uses `<id8> <HH:mm:ss.SSS> <METHOD> <status> <duration> <title> <host>`', () => {
    expect(renderNetworkLine(summary())).toBe('12345678 09:41:05.007 GET 404 13ms /v1/items api.example.com');
  });

  it('marks in-flight, modified, pinned and failed entries', () => {
    expect(renderNetworkLine(summary({ durationMs: undefined, status: '…' }))).toBe('12345678 09:41:05.007 GET … - /v1/items api.example.com');
    expect(renderNetworkLine(summary({ origin: 'rewritten', rule: 'Prod → stage' }))).toContain(' [rewritten: Prod → stage]');
    expect(renderNetworkLine(summary({ origin: 'breakpoint' }))).toContain(' [breakpoint]');
    expect(renderNetworkLine(summary({ pinned: true }))).toMatch(/ \[pinned\]$/);
    const error = 'The network connection was lost. '.repeat(10);
    const line = renderNetworkLine(summary({ error }));
    expect(line).toContain(' ! The network connection was lost.');
    expect(line.endsWith('…')).toBe(true);
    expect(line.length).toBeLessThan(200);
  });

  it('falls back to url and dashes for missing fields', () => {
    const line = renderNetworkLine({ id: 'ABCDEF01-0000', kind: 'http', url: 'https://x.test/a' });
    expect(line).toBe('ABCDEF01 --:--:--.--- - - - https://x.test/a -');
  });

  it('prints full ids when two entries on a page share the first 8 characters', () => {
    const text = renderNetworkList({
      total: 3,
      entries: [summary({ id: 'AAAAAAAA-1111' }), summary({ id: 'AAAAAAAA-2222' }), summary({ id: 'BBBBBBBB-3333' })]
    });
    const ids = text.split('\n').slice(0, 3).map((line) => line.split(' ')[0]);
    expect(ids).toEqual(['AAAAAAAA-1111', 'AAAAAAAA-2222', 'BBBBBBBB']);
  });

  it('explains empty pages', () => {
    expect(renderNetworkList({ total: 0, entries: [] })).toBe('No captured entries match.');
    expect(renderNetworkList({ total: 12, entries: [] })).toBe('No entries on this page (total 12).');
  });

  it('formats durations and sizes compactly', () => {
    expect([0.42, 3.25, 182.4, 999.6, 1243.7, 12_345, 61_000, 119_700, 3_725_000].map(formatDuration)).toEqual([
      '0.4ms',
      '3.3ms',
      '182ms',
      '1s',
      '1.24s',
      '12.3s',
      '1m01s',
      '2m00s',
      '62m05s'
    ]);
    expect(formatDuration(undefined)).toBe('-');
    expect([0, 1023, 1024, 18_432, 5_120_000].map((bytes) => formatBytes(bytes))).toEqual(['0 B', '1023 B', '1 KB', '18 KB', '4.9 MB']);
    expect(clip('a  b\n c', 10)).toBe('a b c');
  });
});

describe('bodies and truncation markers', () => {
  it('renders text bodies and marks truncation', () => {
    expect(renderBody({ contentType: 'application/json', size: 2_097_152, truncated: true, encoding: 'text', text: '{"a":' })).toEqual([
      'body: application/json, 2 MB',
      '{"a":',
      '[truncated; original 2 MB; a larger maxBodyBytes (up to 1048576) may show more]'
    ]);
    expect(renderBody({ contentType: 'text/plain', size: 5, truncated: false, encoding: 'text', text: 'hello' })).toEqual(['body: text/plain, 5 B', 'hello']);
  });

  it('renders binary, empty and missing bodies', () => {
    expect(renderBody({ contentType: 'application/octet-stream', size: 2048, encoding: 'binary' })).toEqual(['body: binary, application/octet-stream, 2 KB']);
    expect(renderBody({ contentType: 'image/jpeg', size: 4096, encoding: 'binary', image: true })).toEqual(['body: binary, image/jpeg, 4 KB, image']);
    expect(renderBody({ size: 0, encoding: 'text', text: '' })).toEqual(['(empty body)']);
    expect(renderBody(undefined)).toEqual(['(no body)']);
  });

  it('marks truncated gRPC messages and dropped messages', () => {
    const entry = structuredClone(fixtureEntries.find((item) => item.kind === 'grpc' && item.state === 'completed')) as NetworkDetail;
    entry.grpc!.droppedMessageCount = 2;
    entry.grpc!.receivedMessageCount = 5;
    entry.grpc!.messages = [{ direction: 'received', timestamp: '2026-10-22T09:41:07.950Z', typeName: 'bank.v1.Notification', size: 9000, json: '{"id":', truncated: true }];
    const text = renderNetworkDetail(entry);
    expect(text).toContain('messages: 1 sent, 5 received, 2 dropped by donk (showing newest 1; raise maxMessages for more)');
    expect(text).toContain('+1.05s ← received bank.v1.Notification 8.8 KB\n{"id":\n[truncated; a larger maxBodyBytes (up to 1048576) may show more]');
  });

  it('keeps summaries free of detail-only fields', () => {
    const grpc = toSummary(fixtureEntries.find((item) => item.kind === 'grpc')!);
    expect(Object.keys(grpc)).not.toContain('request');
    expect(grpc.grpc).toEqual({ service: 'bank.v1.NotificationService', method: 'Subscribe', statusCode: 0, statusName: 'OK', messages: 4 });
  });
});

describe('UI tree rendering', () => {
  it('renders the node line from the contract', () => {
    expect(
      renderNodeLine({
        class: 'UIButton',
        frame: { x: 16, y: 620, width: 343, height: 52 },
        id: 'login.button',
        label: 'Войти',
        text: 'Войти',
        traits: ['button'],
        interactive: true
      })
    ).toBe('UIButton "Войти" #login.button (16,620 343×52) [tap]');
    expect(renderNodeLine({ class: 'UISwitch', frame: { x: 1.25, y: 2, width: 51, height: 31 }, value: '1', label: 'Push', interactive: true, traits: ['button', 'selected'] })).toBe(
      'UISwitch label:"Push" value:"1" (1.3,2 51×31) [tap selected]'
    );
    expect(renderNodeLine({ class: 'UIView', hidden: true, alpha: 0 })).toBe('UIView [hidden alpha 0]');
  });

  it('matches class, id, label and text case-insensitively', () => {
    const node = { class: 'UITextField', id: 'login.phone', label: 'Phone', text: 'Телефон' };
    expect(nodeMatches(node, 'textfield')).toBe(true);
    expect(nodeMatches(node, 'LOGIN.PH')).toBe(true);
    expect(nodeMatches(node, 'phone')).toBe(true);
    expect(nodeMatches(node, 'телефон')).toBe(true);
    expect(nodeMatches({ class: 'UILabel', value: 'secret' }, 'secret')).toBe(false);
  });

  it('match keeps only branches leading to matches, across windows', () => {
    const text = renderUITree(fixtureTree, 'login.');
    expect(text.split('\n')).toEqual([
      'screen 402×874 pt @3x · top LoginViewController · 14 nodes',
      '',
      '4 nodes match "login."; showing only branches leading to them:',
      'UIWindow level 0 key (0,0 402×874)',
      '  UILayoutContainerView vc:UINavigationController (0,0 402×874)',
      '    UIView vc:LoginViewController (0,0 402×874)',
      '      UIStackView (16,400 370×120)',
      '        UITextField placeholder:"Телефон" #login.phone (16,400 370×52) [tap]',
      '        UITextField "••••" #login.password (16,468 370×52) [tap]',
      '      UIButton "Войти" #login.button (16,620 343×52) [tap]',
      '      UIButton "Регистрация" #login.register (16,688 343×44) [tap disabled alpha 0.5]'
    ]);
    const inputs = renderUITree(fixtureTree, 'UIInputSet');
    expect(inputs.split('\n').slice(2)).toEqual([
      '1 node matches "UIInputSet"; showing only branches leading to them:',
      'UITextEffectsWindow level 1 (0,0 402×874)',
      '  UIInputSetContainerView (0,0 402×874)'
    ]);
  });

  it('keeps a matching ancestor together with matching descendants only', () => {
    const tree: UITreeResult = {
      windows: [
        {
          class: 'UIWindow',
          root: {
            class: 'CardView',
            id: 'card',
            children: [
              { class: 'UILabel', text: 'Balance' },
              { class: 'UIView', children: [{ class: 'UILabel', text: 'card number' }] }
            ]
          }
        }
      ]
    };
    expect(renderUITree(tree, 'card').split('\n')).toEqual([
      '2 nodes match "card"; showing only branches leading to them:',
      'UIWindow',
      '  CardView #card',
      '    UIView',
      '      UILabel "card number"'
    ]);
  });

  it('says when nothing matches and when the tree was truncated', () => {
    expect(renderUITree(fixtureTree, 'zzz').split('\n').at(-1)).toBe('No nodes match "zzz" (class, id, label or text, case-insensitive).');
    expect(renderUITree({ ...fixtureTree, truncated: true }).split('\n')[1]).toBe('[truncated at maxNodes; raise maxNodes or narrow with match]');
  });

  it('renders presented controllers', () => {
    const text = renderUITree({
      windows: [],
      controllers: { class: 'UITabBarController', children: [{ class: 'HomeViewController' }], presented: { class: 'UIAlertController', title: 'Ошибка' } }
    });
    expect(text.startsWith('controllers:\n')).toBe(true);
    expect(text).toContain('controllers:\nUITabBarController\n  HomeViewController\n  presented: UIAlertController "Ошибка"');
  });
});
