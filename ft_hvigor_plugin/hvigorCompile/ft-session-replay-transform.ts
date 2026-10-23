/**
 * Guance Session Replay page-root compiler transform.
 *
 * ArkUI exposes a FrameNode only after a component has an ID.  The transform
 * instruments @Entry page roots in Hvigor's in-memory source, leaving customer
 * files untouched.  The generated calls are deliberately tiny: the optional
 * Replay HAR owns root selection, layout retries, privacy, and capture.
 */

import { isApplicationArkTsSource } from './ft-console-log-transform';
import { hasRuntimeDependency, SourceReader } from './ft-transform-context';
import { allocateName as selectUniqueName } from './ft-generated-names';

type TypeScriptApi = any;

interface SourceRange {
  start: number;
  end: number;
}

interface MethodRange {
  nameStart: number;
  memberStart: number;
  node: any;
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
  bodyEnd: number;
  methods: Map<string, MethodRange>;
}

interface Injection {
  position: number;
  content: string;
}

const REPLAY_BRIDGE_IMPORT = '@guancecloud/ft_session_replay';
const REPLAY_ROOT_TRANSFORM_MARKER = '/* guance-session-replay-root-transform:instrumented */';

function lineIndentation(code: string, position: number): string {
  const lineStart = code.lastIndexOf('\n', position) + 1;
  const match = code.slice(lineStart, position).match(/^\s*/);
  return match === null ? '' : match[0];
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

function findImportInsertionOffset(ts: TypeScriptApi, id: string, code: string): number {
  const sourceFile = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true,
    ts.ScriptKind.ETS ?? ts.ScriptKind.TS);
  let offset = 0;
  sourceFile.statements.forEach((statement: any): void => {
    if (ts.isImportDeclaration(statement)) {
      offset = statement.end;
    }
  });
  return offset;
}

/** Structs, decorators and members must come from the ArkTS parser, never text matches. */
function collectEntryStructs(ts: TypeScriptApi, source: any): EntryStruct[] {
  const entries: EntryStruct[] = [];
  source.statements.forEach((node: any) => {
    if (!ts.isStructDeclaration(node)) return;
    const decorators = ts.getDecorators ? ts.getDecorators(node) || [] : node.decorators || [];
    const isEntry = decorators.some((decorator: any) => {
      const expression = ts.isCallExpression(decorator.expression)
        ? decorator.expression.expression : decorator.expression;
      return ts.isIdentifier(expression) && expression.text === 'Entry';
    });
    if (!isEntry) return;
    const methods = new Map<string, MethodRange>();
    node.members.forEach((member: any) => {
      if (ts.isMethodDeclaration(member) && member.body && ts.isIdentifier(member.name)) {
        methods.set(member.name.text, { nameStart: member.name.getStart(source),
          memberStart: member.getStart(source), node: member,
          bodyStart: member.body.getStart(source), bodyEnd: member.body.end - 1 });
      }
    });
    entries.push({ bodyEnd: node.end - 1, methods });
  });
  return entries;
}

function componentChain(ts: TypeScriptApi, expression: any): { base: any; modifiers: any[] } {
  const modifiers: any[] = [];
  let base = expression;
  while (ts.isCallExpression(base) && ts.isPropertyAccessExpression(base.expression)) {
    modifiers.unshift(base);
    base = base.expression.expression;
  }
  return { base, modifiers };
}

function argumentRange(source: any, call: any): SourceRange {
  // Include comments and newlines before the closing parenthesis when reusing an argument.
  return { start: call.arguments.pos, end: call.getLastToken(source).getStart(source) };
}

function findRootExpression(ts: TypeScriptApi, source: any, code: string,
  build: MethodRange): RootExpression | null {
  const first = build.node.body.statements[0];
  if (!first || (!ts.isExpressionStatement(first) && !ts.isReturnStatement(first)) || !first.expression) return null;
  const { base, modifiers } = componentChain(ts, first.expression);
  if (!ts.isEtsComponentExpression(base) || !base.body) return null;
  let idExpression: string | null = null;
  let hasAreaChange = false;
  let hasTouch = false;
  let touchArgument: SourceRange | undefined;
  modifiers.forEach((call: any) => {
    const name = call.expression.name.text;
    const range = argumentRange(source, call);
    if (name === 'id' && call.arguments.length === 1) idExpression = code.slice(range.start, range.end);
    if (name === 'onAreaChange') hasAreaChange = true;
    if (name === 'onTouch') {
      hasTouch = true;
      if (call.arguments.length === 1) touchArgument = range;
    }
  });
  return { end: first.expression.end, idExpression, hasAreaChange, hasTouch, touchArgument };
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

function addTransitionInjections(ts: TypeScriptApi, source: any, code: string, injections: Injection[],
  entry: EntryStruct, bridgeName: string, tokenField: string, rootExpression: string): void {
  const method = entry.methods.get('pageTransition');
  if (!method) {
    const indentation = `${lineIndentation(code, entry.bodyEnd)}  `;
    injections.push({ position: entry.bodyEnd, content: `\n${indentation}pageTransition(): void {\n` +
      `${indentation}  if (${bridgeName}.defaultTransitionStarted(this.${tokenField})) {}\n${indentation}}\n` });
    return;
  }
  let nextSpec = 0;
  method.node.body.statements.forEach((statement: any) => {
    if (!ts.isExpressionStatement(statement)) return;
    const { base, modifiers } = componentChain(ts, statement.expression);
    if ((!ts.isCallExpression(base) && !ts.isEtsComponentExpression(base)) || !ts.isIdentifier(base.expression)) return;
    const name = base.expression.text;
    if (name !== 'PageTransitionEnter' && name !== 'PageTransitionExit') return;
    const entering = name === 'PageTransitionEnter';
    const callbackName = entering ? 'onEnter' : 'onExit';
    const spec = JSON.stringify(`transition-${nextSpec++}`);
    const prefix = `this.${tokenField}, ${rootExpression}, ${spec}, ${entering}`;
    let callback: SourceRange | undefined;
    modifiers.forEach((call: any) => {
      const modifierName = call.expression.name.text;
      const range = argumentRange(source, call);
      if ((modifierName === 'slide' || modifierName === 'opacity') && call.arguments.length === 1) {
        const hook = modifierName === 'slide' ? 'transitionSlide' : 'transitionOpacity';
        injections.push({ position: range.start,
          content: `${bridgeName}.${hook}(this.${tokenField}, ${spec}, ` });
        injections.push({ position: range.end, content: ')' });
      } else if (modifierName === callbackName && call.arguments.length === 1) callback = range;
    });
    if (callback) {
      injections.push({ position: callback.start, content: `${bridgeName}.wrapTransition(${prefix}, ` });
      injections.push({ position: callback.end, content: ')' });
    } else {
      injections.push({ position: statement.expression.end,
        content: `.${callbackName}((type: RouteType, progress: number) => { ${bridgeName}.transitionProgress(${prefix}, progress); })` });
    }
  });
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
  const existing = struct.methods.get(methodName);
  const call = lifecycleCall(bridgeName, tokenField, runtimeMethod, rootExpression,
    !struct.methods.has('pageTransition'));
  if (existing) {
    const indentation = `${lineIndentation(code, existing.nameStart)}  `;
    injections.push({ position: existing.bodyStart + 1, content: `\n${indentation}${call}` });
    return;
  }
  const indentation = lineIndentation(code, buildMethod.nameStart);
  injections.push({
    position: buildMethod.memberStart,
    content: `\n${indentation}${methodName}(): void {\n${indentation}  ${call}\n${indentation}}\n\n`
  });
}

/**
 * Adds an opaque root ID and page lifecycle registration to every @Entry page.
 * ArkTS nodes locate real decorators, struct members and component expressions.
 */
export function transformSessionReplaySource(ts: TypeScriptApi, id: string, code: string, readSource?: SourceReader): string {
  if (!isApplicationArkTsSource(id) || code.includes(REPLAY_ROOT_TRANSFORM_MARKER) ||
    !hasRuntimeDependency(ts, id, '@guancecloud/ft_sdk', readSource) ||
    !hasRuntimeDependency(ts, id, REPLAY_BRIDGE_IMPORT, readSource)) {
    return code;
  }

  if (typeof ts.isStructDeclaration !== 'function' || typeof ts.isEtsComponentExpression !== 'function') return code;
  // The parser needs component names to recognize declarative child blocks.
  // This superset configures parsing only; eligibility is decided by AST nodes.
  const components = Array.from(collectIdentifiers(code));
  const source = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
    { ets: {
      components,
      render: { method: ['build', 'pageTransition'], decorator: ['Builder', 'LocalBuilder'] },
      extend: { decorator: ['Extend', 'AnimatableExtend'], components: components.map(name =>
        ({ name, type: `${name}Attribute`, instance: `${name}Instance` })) },
      styles: { decorator: 'Styles', component: { name: 'Common', type: 'T', instance: 'CommonInstance' }, property: 'stateStyles' },
      concurrent: { decorator: 'Concurrent' },
      customComponent: 'CustomComponent',
      syntaxComponents: { paramsUICallback: ['ForEach', 'LazyForEach'], attrUICallback: [{ name: 'Repeat', attributes: ['each', 'template'] }] }
    } });
  if (source.parseDiagnostics.length > 0) return code;
  const entries = collectEntryStructs(ts, source);
  if (entries.length === 0) {
    return code;
  }

  const identifiers = collectIdentifiers(code);
  const bridgeName = selectUniqueName(identifiers, '__ftSessionReplayAutoRootBridge');
  const tokenField = selectUniqueName(identifiers, '__ftSessionReplayRootToken');
  const sourceKey = createSourceKey(id);
  const injections: Injection[] = [];

  entries.forEach((entry: EntryStruct): void => {
    const buildMethod = entry.methods.get('build');
    if (!buildMethod) {
      return;
    }
    const root = findRootExpression(ts, source, code, buildMethod);
    if (root === null) {
      return;
    }
    const indentation = lineIndentation(code, buildMethod.nameStart);
    injections.push({
      position: buildMethod.memberStart,
      content: `\n${indentation}private ${tokenField}: string = ${bridgeName}.createRootToken(${JSON.stringify(sourceKey)});\n\n`
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
    addTransitionInjections(ts, source, code, injections, entry, bridgeName, tokenField, rootExpression);
  });

  if (injections.length === 0) {
    return code;
  }
  const importOffset = findImportInsertionOffset(ts, id, code);
  const importStatement = `\n${REPLAY_ROOT_TRANSFORM_MARKER}\n` +
    `import { FTSessionReplayAutoRootBridge as ${bridgeName} } from '${REPLAY_BRIDGE_IMPORT}';\n`;
  injections.push({ position: importOffset, content: importStatement });
  return applyInjections(code, injections);
}
