/**
 * Guance Session Replay page-root compiler transform.
 *
 * ArkUI exposes a FrameNode only after a component has an ID.  The transform
 * instruments @Entry page roots in Hvigor's in-memory source, leaving customer
 * files untouched.  The generated calls are deliberately tiny: the optional
 * Replay HAR owns root selection, layout retries, privacy, and capture.
 */

import { isApplicationArkTsSource } from './ft-console-log-transform';

declare const require: any;

type TypeScriptApi = any;

interface SourceRange {
  start: number;
  end: number;
}

interface MethodRange {
  nameStart: number;
  bodyStart: number;
  bodyEnd: number;
}

interface RootExpression {
  end: number;
  idExpression: string | null;
  hasAreaChange: boolean;
  hasTouch: boolean;
  touchArgument?: SourceRange;
}

interface EntryStruct {
  bodyStart: number;
  bodyEnd: number;
}

interface Injection {
  position: number;
  content: string;
}

const REPLAY_BRIDGE_IMPORT = '@guancecloud/ft_session_replay';
const REPLAY_ROOT_TRANSFORM_MARKER = '/* guance-session-replay-root-transform:instrumented */';
const replayRuntimeAvailability: Map<string, boolean> = new Map();

function isIdentifierStart(character: string): boolean {
  return /[A-Za-z_$]/.test(character);
}

function isIdentifierPart(character: string): boolean {
  return /[A-Za-z0-9_$]/.test(character);
}

function skipTrivia(code: string, start: number, end: number): number {
  let cursor = start;
  while (cursor < end) {
    const character = code[cursor];
    if (/\s/.test(character)) {
      cursor++;
      continue;
    }
    if (character === '/' && code[cursor + 1] === '/') {
      const lineEnd = code.indexOf('\n', cursor + 2);
      cursor = lineEnd < 0 ? end : lineEnd + 1;
      continue;
    }
    if (character === '/' && code[cursor + 1] === '*') {
      const commentEnd = code.indexOf('*/', cursor + 2);
      cursor = commentEnd < 0 ? end : commentEnd + 2;
      continue;
    }
    break;
  }
  return cursor;
}

function skipString(code: string, start: number, end: number): number {
  const quote = code[start];
  let cursor = start + 1;
  while (cursor < end) {
    if (code[cursor] === '\\') {
      cursor += 2;
      continue;
    }
    if (code[cursor] === quote) {
      return cursor + 1;
    }
    cursor++;
  }
  return end;
}

/** Finds a closing delimiter while ignoring comments and string literals. */
function findMatching(code: string, open: number, end: number, openChar: string, closeChar: string): number {
  let depth = 0;
  let cursor = open;
  while (cursor < end) {
    const character = code[cursor];
    if (character === '"' || character === '\'' || character === '`') {
      cursor = skipString(code, cursor, end);
      continue;
    }
    if (character === '/' && code[cursor + 1] === '/') {
      const lineEnd = code.indexOf('\n', cursor + 2);
      cursor = lineEnd < 0 ? end : lineEnd + 1;
      continue;
    }
    if (character === '/' && code[cursor + 1] === '*') {
      const commentEnd = code.indexOf('*/', cursor + 2);
      cursor = commentEnd < 0 ? end : commentEnd + 2;
      continue;
    }
    if (character === openChar) {
      depth++;
    } else if (character === closeChar) {
      depth--;
      if (depth === 0) {
        return cursor;
      }
    }
    cursor++;
  }
  return -1;
}

function readIdentifier(code: string, start: number, end: number): SourceRange | null {
  if (start >= end || !isIdentifierStart(code[start])) {
    return null;
  }
  let cursor = start + 1;
  while (cursor < end && isIdentifierPart(code[cursor])) {
    cursor++;
  }
  return { start, end: cursor };
}

function lineIndentation(code: string, position: number): string {
  const lineStart = code.lastIndexOf('\n', position) + 1;
  const match = code.slice(lineStart, position).match(/^\s*/);
  return match === null ? '' : match[0];
}

function lineStart(code: string, position: number): number {
  return code.lastIndexOf('\n', position) + 1;
}

function collectIdentifiers(code: string): Set<string> {
  const identifiers = new Set<string>();
  const expression = /\b[A-Za-z_$][A-Za-z0-9_$]*\b/g;
  let match: RegExpExecArray | null;
  while ((match = expression.exec(code)) !== null) {
    identifiers.add(match[0]);
  }
  return identifiers;
}

function selectUniqueName(identifiers: Set<string>, base: string): string {
  let candidate = base;
  let suffix = 1;
  while (identifiers.has(candidate)) {
    candidate = `${base}${suffix}`;
    suffix++;
  }
  identifiers.add(candidate);
  return candidate;
}

/** A stable opaque source key. Do not emit customers' project paths into UI IDs. */
function createSourceKey(id: string): string {
  let hash = 0x811c9dc5;
  const normalized = id.replace(/\\/g, '/').toLowerCase();
  for (let index = 0; index < normalized.length; index++) {
    hash ^= normalized.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(36);
}

/**
 * Replay is an optional HAR. Do not make existing console/cold-launch plugin
 * consumers fail compilation by emitting an import they did not declare.
 */
function hasSessionReplayRuntime(id: string): boolean {
  const normalized = id.replace(/\\/g, '/');
  const sourceMarker = '/src/main/ets/';
  const sourceIndex = normalized.indexOf(sourceMarker);
  if (sourceIndex < 0) {
    return false;
  }
  const moduleRoot = normalized.slice(0, sourceIndex);
  const cached = replayRuntimeAvailability.get(moduleRoot);
  if (cached !== undefined) {
    return cached;
  }
  let available = false;
  try {
    const nodeRequire = require.main && typeof require.main.require === 'function'
      ? require.main.require.bind(require.main)
      : require;
    const path = nodeRequire('path');
    const fileSystem = nodeRequire('fs');
    const packagePath = path.join(moduleRoot, 'oh-package.json5');
    const packageText = fileSystem.readFileSync(packagePath, 'utf8').toString();
    available = /["']@guancecloud\/ft_session_replay["']\s*:/.test(packageText);
  } catch (_) {
    available = false;
  }
  replayRuntimeAvailability.set(moduleRoot, available);
  return available;
}

function findImportInsertionOffset(code: string): number {
  const expression = /(^|\n)\s*import\s+[\s\S]*?;(?=\s*(?:\n|$))/g;
  let offset = 0;
  let match: RegExpExecArray | null;
  while ((match = expression.exec(code)) !== null) {
    offset = match.index + match[0].length;
  }
  return offset;
}

function collectEntryStructs(code: string): EntryStruct[] {
  const entries: EntryStruct[] = [];
  const entryDecorator = /@Entry\b/g;
  let decoratorMatch: RegExpExecArray | null;
  while ((decoratorMatch = entryDecorator.exec(code)) !== null) {
    const nextDecorator = code.indexOf('@Entry', decoratorMatch.index + '@Entry'.length);
    const searchEnd = nextDecorator < 0 ? code.length : nextDecorator;
    const structExpression = /\bstruct\s+[A-Za-z_$][A-Za-z0-9_$]*\s*\{/g;
    structExpression.lastIndex = decoratorMatch.index + '@Entry'.length;
    const structMatch = structExpression.exec(code);
    if (structMatch === null || structMatch.index >= searchEnd) {
      continue;
    }
    const bodyStart = code.indexOf('{', structMatch.index);
    const bodyEnd = findMatching(code, bodyStart, code.length, '{', '}');
    if (bodyEnd < 0) {
      continue;
    }
    entries.push({ bodyStart, bodyEnd });
    entryDecorator.lastIndex = bodyEnd + 1;
  }
  return entries;
}

function findTopLevelMethod(code: string, bodyStart: number, bodyEnd: number, methodName: string): MethodRange | null {
  let cursor = bodyStart + 1;
  let depth = 0;
  while (cursor < bodyEnd) {
    const character = code[cursor];
    if (character === '"' || character === '\'' || character === '`') {
      cursor = skipString(code, cursor, bodyEnd);
      continue;
    }
    if (character === '/' && (code[cursor + 1] === '/' || code[cursor + 1] === '*')) {
      cursor = skipTrivia(code, cursor, bodyEnd);
      continue;
    }
    if (character === '{') {
      depth++;
      cursor++;
      continue;
    }
    if (character === '}') {
      depth--;
      cursor++;
      continue;
    }
    if (depth !== 0 || !isIdentifierStart(character)) {
      cursor++;
      continue;
    }
    const identifier = readIdentifier(code, cursor, bodyEnd);
    if (identifier === null) {
      cursor++;
      continue;
    }
    cursor = identifier.end;
    if (code.slice(identifier.start, identifier.end) !== methodName) {
      continue;
    }
    let afterName = skipTrivia(code, identifier.end, bodyEnd);
    if (code[afterName] !== '(') {
      continue;
    }
    const parametersEnd = findMatching(code, afterName, bodyEnd, '(', ')');
    if (parametersEnd < 0) {
      continue;
    }
    afterName = skipTrivia(code, parametersEnd + 1, bodyEnd);
    if (code[afterName] === ':') {
      afterName++;
      while (afterName < bodyEnd && code[afterName] !== '{' && code[afterName] !== ';') {
        if (code[afterName] === '"' || code[afterName] === '\'' || code[afterName] === '`') {
          afterName = skipString(code, afterName, bodyEnd);
        } else {
          afterName++;
        }
      }
    }
    afterName = skipTrivia(code, afterName, bodyEnd);
    if (code[afterName] !== '{') {
      continue;
    }
    const methodEnd = findMatching(code, afterName, bodyEnd, '{', '}');
    if (methodEnd < 0) {
      continue;
    }
    return { nameStart: identifier.start, bodyStart: afterName, bodyEnd: methodEnd };
  }
  return null;
}

function findRootExpression(code: string, buildBodyStart: number, buildBodyEnd: number): RootExpression | null {
  let cursor = skipTrivia(code, buildBodyStart + 1, buildBodyEnd);
  if (code.slice(cursor, cursor + 6) === 'return' && !isIdentifierPart(code[cursor + 6] || '')) {
    cursor = skipTrivia(code, cursor + 6, buildBodyEnd);
  }
  const component = readIdentifier(code, cursor, buildBodyEnd);
  if (component === null) {
    return null;
  }
  cursor = skipTrivia(code, component.end, buildBodyEnd);
  if (code[cursor] !== '(') {
    return null;
  }
  const argumentsEnd = findMatching(code, cursor, buildBodyEnd, '(', ')');
  if (argumentsEnd < 0) {
    return null;
  }
  cursor = skipTrivia(code, argumentsEnd + 1, buildBodyEnd);
  if (code[cursor] !== '{') {
    return null;
  }
  const childEnd = findMatching(code, cursor, buildBodyEnd, '{', '}');
  if (childEnd < 0) {
    return null;
  }
  cursor = childEnd + 1;
  let idExpression: string | null = null;
  let hasAreaChange = false;
  let hasTouch = false;
  let touchArgument: SourceRange | undefined;

  // Consume the root's chained modifiers. The next token outside that chain is
  // a sibling statement or the build-method closing brace.
  while (cursor < buildBodyEnd) {
    const modifierStart = skipTrivia(code, cursor, buildBodyEnd);
    if (code[modifierStart] !== '.') {
      break;
    }
    const modifierName = readIdentifier(code, modifierStart + 1, buildBodyEnd);
    if (modifierName === null) {
      break;
    }
    let afterModifier = skipTrivia(code, modifierName.end, buildBodyEnd);
    if (code[afterModifier] !== '(') {
      break;
    }
    const modifierEnd = findMatching(code, afterModifier, buildBodyEnd, '(', ')');
    if (modifierEnd < 0) {
      return null;
    }
    if (code.slice(modifierName.start, modifierName.end) === 'id') {
      const argument = code.slice(afterModifier + 1, modifierEnd).trim();
      if (argument.length > 0) {
        idExpression = argument;
      }
    }
    if (code.slice(modifierName.start, modifierName.end) === 'onAreaChange') {
      hasAreaChange = true;
    }
    if (code.slice(modifierName.start, modifierName.end) === 'onTouch') {
      hasTouch = true;
      touchArgument = { start: afterModifier + 1, end: modifierEnd };
    }
    cursor = modifierEnd + 1;
  }
  return { end: cursor, idExpression, hasAreaChange, hasTouch, touchArgument };
}

function applyInjections(code: string, injections: Injection[]): string {
  const grouped = new Map<number, string[]>();
  injections.forEach((injection: Injection): void => {
    const values = grouped.get(injection.position) || [];
    values.push(injection.content);
    grouped.set(injection.position, values);
  });
  const positions = Array.from(grouped.keys()).sort((left: number, right: number): number => right - left);
  let transformed = code;
  positions.forEach((position: number): void => {
    transformed = transformed.slice(0, position) + (grouped.get(position) || []).join('') + transformed.slice(position);
  });
  return transformed;
}

function addTransitionInjections(code: string, injections: Injection[], entry: EntryStruct,
  bridgeName: string, tokenField: string, rootExpression: string): void {
  const method = findTopLevelMethod(code, entry.bodyStart, entry.bodyEnd, 'pageTransition');
  if (method === null) {
    const indentation = `${lineIndentation(code, entry.bodyEnd)}  `;
    // An empty effect list keeps ArkUI's default transition. The method is
    // invoked by the real Router animation, including its outgoing page.
    injections.push({ position: entry.bodyEnd, content: `\n${indentation}pageTransition(): void {\n` +
      `${indentation}  if (${bridgeName}.defaultTransitionStarted(this.${tokenField})) {}\n${indentation}}\n` });
    return;
  }
  let cursor = method.bodyStart + 1;
  let nextSpec = 0;
  while (cursor < method.bodyEnd) {
    const character = code[cursor];
    if (character === '"' || character === '\'' || character === '`') {
      cursor = skipString(code, cursor, method.bodyEnd);
      continue;
    }
    if (character === '/' && (code[cursor + 1] === '/' || code[cursor + 1] === '*')) {
      cursor = skipTrivia(code, cursor, method.bodyEnd);
      continue;
    }
    const identifier = readIdentifier(code, cursor, method.bodyEnd);
    if (identifier === null) { cursor++; continue; }
    cursor = identifier.end;
    const name = code.slice(identifier.start, identifier.end);
    if (name !== 'PageTransitionEnter' && name !== 'PageTransitionExit') continue;
    const argumentsStart = skipTrivia(code, cursor, method.bodyEnd);
    if (code[argumentsStart] !== '(') continue;
    const argumentsEnd = findMatching(code, argumentsStart, method.bodyEnd, '(', ')');
    if (argumentsEnd < 0) continue;
    const entering = name === 'PageTransitionEnter';
    const callbackName = entering ? 'onEnter' : 'onExit';
    const spec = JSON.stringify(`transition-${nextSpec++}`);
    const prefix = `this.${tokenField}, ${rootExpression}, ${spec}, ${entering}`;
    let callback: SourceRange | undefined;
    cursor = argumentsEnd + 1;
    while (cursor < method.bodyEnd) {
      const start = skipTrivia(code, cursor, method.bodyEnd);
      if (code[start] !== '.') break;
      const modifier = readIdentifier(code, start + 1, method.bodyEnd);
      if (modifier === null) break;
      const open = skipTrivia(code, modifier.end, method.bodyEnd);
      if (code[open] !== '(') break;
      const close = findMatching(code, open, method.bodyEnd, '(', ')');
      if (close < 0) break;
      const modifierName = code.slice(modifier.start, modifier.end);
      if (modifierName === 'slide' || modifierName === 'opacity') {
        const hook = modifierName === 'slide' ? 'transitionSlide' : 'transitionOpacity';
        injections.push({ position: open + 1,
          content: `${bridgeName}.${hook}(this.${tokenField}, ${spec}, ` });
        injections.push({ position: close, content: ')' });
      } else if (modifierName === callbackName) callback = { start: open + 1, end: close };
      cursor = close + 1;
    }
    if (callback !== undefined) {
      injections.push({ position: callback.start, content: `${bridgeName}.wrapTransition(${prefix}, ` });
      injections.push({ position: callback.end, content: ')' });
    } else {
      injections.push({ position: cursor,
        content: `.${callbackName}((type: RouteType, progress: number) => { ${bridgeName}.transitionProgress(${prefix}, progress); })` });
    }
  }
}

function lifecycleCall(bridgeName: string, tokenField: string, method: 'pageShown' | 'pageHidden' | 'pageDisposed',
  rootExpression: string, observeDefaultTransition: boolean): string {
  if (method === 'pageShown') {
    return `${bridgeName}.pageShown(this.getUIContext(), this.${tokenField}, ${rootExpression}, vp2px(1), ${observeDefaultTransition});`;
  }
  return `${bridgeName}.${method}(this.${tokenField});`;
}

function addLifecycleInjection(
  code: string,
  injections: Injection[],
  struct: EntryStruct,
  buildMethod: MethodRange,
  bridgeName: string,
  tokenField: string,
  methodName: 'onPageShow' | 'onPageHide' | 'aboutToDisappear',
  runtimeMethod: 'pageShown' | 'pageHidden' | 'pageDisposed',
  rootExpression: string
): void {
  const existing = findTopLevelMethod(code, struct.bodyStart, struct.bodyEnd, methodName);
  const call = lifecycleCall(bridgeName, tokenField, runtimeMethod, rootExpression,
    findTopLevelMethod(code, struct.bodyStart, struct.bodyEnd, 'pageTransition') === null);
  if (existing !== null) {
    const indentation = `${lineIndentation(code, existing.nameStart)}  `;
    injections.push({ position: existing.bodyStart + 1, content: `\n${indentation}${call}` });
    return;
  }
  const indentation = lineIndentation(code, buildMethod.nameStart);
  injections.push({
    position: lineStart(code, buildMethod.nameStart),
    content: `${indentation}${methodName}(): void {\n${indentation}  ${call}\n${indentation}}\n\n`
  });
}

/**
 * Adds an opaque root ID and page lifecycle registration to every @Entry page.
 * The TypeScript argument is intentionally accepted for the shared transform
 * host signature; ArkTS declarative component syntax is parsed conservatively
 * here so the transform works with the compiler's ArkTS source reader.
 */
export function transformSessionReplaySource(_ts: TypeScriptApi, id: string, code: string): string {
  if (!isApplicationArkTsSource(id) || code.includes(REPLAY_ROOT_TRANSFORM_MARKER) || !hasSessionReplayRuntime(id)) {
    return code;
  }

  const entries = collectEntryStructs(code);
  if (entries.length === 0) {
    return code;
  }

  const identifiers = collectIdentifiers(code);
  const bridgeName = selectUniqueName(identifiers, '__ftSessionReplayAutoRootBridge');
  const tokenField = selectUniqueName(identifiers, '__ftSessionReplayRootToken');
  const sourceKey = createSourceKey(id);
  const injections: Injection[] = [];

  entries.forEach((entry: EntryStruct): void => {
    const buildMethod = findTopLevelMethod(code, entry.bodyStart, entry.bodyEnd, 'build');
    if (buildMethod === null) {
      return;
    }
    const root = findRootExpression(code, buildMethod.bodyStart, buildMethod.bodyEnd);
    if (root === null) {
      return;
    }
    const indentation = lineIndentation(code, buildMethod.nameStart);
    injections.push({
      position: lineStart(code, buildMethod.nameStart),
      content: `${indentation}private ${tokenField}: string = ${bridgeName}.createRootToken(${JSON.stringify(sourceKey)});\n\n`
    });

    const rootExpression = root.idExpression === null ? `this.${tokenField}` : root.idExpression;
    if (root.idExpression === null) {
      injections.push({ position: root.end, content: `.id(${rootExpression})` });
    }
    // Root area changes are ArkUI's public layout/draw boundary. Emit a
    // coalesced Replay signal there instead of installing a fixed full-tree
    // polling loop. Do not add a second modifier when an app already owns one.
    if (!root.hasAreaChange) {
      injections.push({
        position: root.end,
        content: `.onAreaChange(() => { ${bridgeName}.pageChanged(this.${tokenField}); })`
      });
    }
    // Preserve application callbacks and their event propagation behavior.
    // The bridge forwards real pointer coordinates independently of drawing.
    if (!root.hasTouch) {
      injections.push({
        position: root.end,
        content: `.onTouch((event: TouchEvent) => { ${bridgeName}.pageTouch(this.${tokenField}, event); })`
      });
    } else if (root.touchArgument !== undefined) {
      injections.push({ position: root.touchArgument.start,
        content: `${bridgeName}.wrapTouch(this.${tokenField}, ` });
      injections.push({ position: root.touchArgument.end, content: ')' });
    }
    addLifecycleInjection(code, injections, entry, buildMethod, bridgeName, tokenField,
      'onPageShow', 'pageShown', rootExpression);
    addLifecycleInjection(code, injections, entry, buildMethod, bridgeName, tokenField,
      'onPageHide', 'pageHidden', rootExpression);
    addLifecycleInjection(code, injections, entry, buildMethod, bridgeName, tokenField,
      'aboutToDisappear', 'pageDisposed', rootExpression);
    addTransitionInjections(code, injections, entry, bridgeName, tokenField, rootExpression);
  });

  if (injections.length === 0) {
    return code;
  }
  const transformed = applyInjections(code, injections);
  const importOffset = findImportInsertionOffset(code);
  const importStatement = `\n${REPLAY_ROOT_TRANSFORM_MARKER}\n` +
    `import { FTSessionReplayAutoRootBridge as ${bridgeName} } from '${REPLAY_BRIDGE_IMPORT}';\n`;
  return transformed.slice(0, importOffset) + importStatement + transformed.slice(importOffset);
}
