import type { ControllerNode, Frame, UINode, UITreeResult, UIWindowNode } from '../protocol.js';
import { formatNumber, quote } from './format.js';

const INDENT = '  ';

export function formatFrame(frame?: Frame): string {
  if (!frame) return '';
  return `(${formatNumber(frame.x)},${formatNumber(frame.y)} ${formatNumber(frame.width)}×${formatNumber(frame.height)})`;
}

function nodeFlags(node: UINode): string[] {
  const flags: string[] = [];
  if (node.interactive) flags.push('tap');
  for (const trait of node.traits ?? []) {
    if (trait === 'button' && node.interactive) continue;
    flags.push(trait === 'notEnabled' ? 'disabled' : trait);
  }
  if (node.hidden) flags.push('hidden');
  if (node.alpha !== undefined && node.alpha < 1) flags.push(`alpha ${formatNumber(node.alpha)}`);
  return flags;
}

export function renderNodeLine(node: UINode): string {
  const parts = [node.class];
  if (node.text !== undefined && node.text !== '') {
    parts.push(node.placeholder ? `placeholder:${quote(node.text)}` : quote(node.text));
  }
  if (node.label && node.label !== node.text) parts.push(`label:${quote(node.label)}`);
  if (node.value && node.value !== node.text) parts.push(`value:${quote(node.value)}`);
  if (node.id) parts.push(`#${node.id}`);
  if (node.viewController) parts.push(`vc:${node.viewController}`);
  const frame = formatFrame(node.frame);
  if (frame) parts.push(frame);
  const flags = nodeFlags(node);
  if (flags.length) parts.push(`[${flags.join(' ')}]`);
  if (node.childrenOmitted) parts.push(`(+${node.childrenOmitted} children beyond maxDepth)`);
  return parts.join(' ');
}

export function nodeMatches(node: UINode, needle: string): boolean {
  const lower = needle.toLowerCase();
  return [node.class, node.id, node.label, node.text].some((field) => field !== undefined && field.toLowerCase().includes(lower));
}

interface Pruned {
  node: UINode;
  children: Pruned[];
}

function prune(node: UINode, needle: string | undefined, counter: { matches: number }): Pruned | undefined {
  const children: Pruned[] = [];
  for (const child of node.children ?? []) {
    const kept = prune(child, needle, counter);
    if (kept) children.push(kept);
  }
  if (!needle) return { node, children };
  const matched = nodeMatches(node, needle);
  if (matched) counter.matches += 1;
  return matched || children.length ? { node, children } : undefined;
}

function renderPruned(pruned: Pruned, depth: number, lines: string[]): void {
  lines.push(`${INDENT.repeat(depth)}${renderNodeLine(pruned.node)}`);
  for (const child of pruned.children) renderPruned(child, depth + 1, lines);
}

function renderController(node: ControllerNode, depth: number, lines: string[], prefix = ''): void {
  const title = node.title ? ` ${quote(node.title)}` : '';
  lines.push(`${INDENT.repeat(depth)}${prefix}${node.class}${title}`);
  for (const child of node.children ?? []) renderController(child, depth + 1, lines);
  if (node.presented) renderController(node.presented, depth + 1, lines, 'presented: ');
}

function windowLine(window: UIWindowNode, root?: UINode): string {
  const parts = [window.class];
  if (window.level !== undefined) parts.push(`level ${formatNumber(window.level)}`);
  if (window.isKey) parts.push('key');
  if (root?.id) parts.push(`#${root.id}`);
  const frame = formatFrame(window.frame ?? root?.frame);
  if (frame) parts.push(frame);
  if (root?.childrenOmitted) parts.push(`(+${root.childrenOmitted} children beyond maxDepth)`);
  return parts.join(' ');
}

export function renderUITree(tree: UITreeResult, match?: string): string {
  const needle = match?.trim() ? match.trim() : undefined;
  const header: string[] = [];
  if (tree.screen) {
    header.push(`screen ${formatNumber(tree.screen.width)}×${formatNumber(tree.screen.height)} pt${tree.screen.scale ? ` @${formatNumber(tree.screen.scale)}x` : ''}`);
  }
  if (tree.topViewController) header.push(`top ${tree.topViewController}`);
  if (tree.nodeCount !== undefined) header.push(`${tree.nodeCount} nodes`);
  const lines = header.length ? [header.join(' · ')] : [];
  if (tree.truncated) lines.push('[truncated at maxNodes; raise maxNodes or narrow with match]');
  const section = (...items: string[]) => lines.push(...(lines.length ? [''] : []), ...items);

  if (tree.controllers && !needle) {
    section('controllers:');
    renderController(tree.controllers, 0, lines);
  }

  const counter = { matches: 0 };
  const windowLines: string[] = [];
  for (const window of tree.windows ?? []) {
    const root = window.root ? prune(window.root, needle, counter) : undefined;
    if (needle && !root) continue;
    const merged = root !== undefined && root.node.class === window.class;
    windowLines.push(windowLine(window, merged ? root.node : undefined));
    if (!root) continue;
    if (merged) for (const child of root.children) renderPruned(child, 1, windowLines);
    else renderPruned(root, 1, windowLines);
  }

  if (needle) {
    if (counter.matches === 0) {
      section(`No nodes match ${quote(needle)} (class, id, label or text, case-insensitive).`);
      return lines.join('\n');
    }
    section(`${counter.matches} ${counter.matches === 1 ? 'node matches' : 'nodes match'} ${quote(needle)}; showing only branches leading to them:`);
  } else {
    section('windows (back to front):');
  }
  lines.push(...windowLines);
  return lines.join('\n');
}
