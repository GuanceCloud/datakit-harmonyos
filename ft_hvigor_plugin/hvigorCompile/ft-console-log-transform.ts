/**
 * Guance console-log compiler plugin.
 *
 * Hvigor creates the ArkTS type-checking program before normal Rollup
 * transform hooks run. This plugin therefore rewrites only the in-memory
 * application source read by that program. Application files on disk are
 * never changed.
 */

import { hasRuntimeDependency, SourceReader } from './ft-transform-context';
import { createLexicalResolver } from './ft-lexical-scope';

type TypeScriptApi = any;

interface TransformCandidate {
  start: number;
  end: number;
  calleeEnd: number;
  delegate: string;
  level: string;
  source: 'console' | 'hilog';
  callArguments: SourceRange[];
  needsStatementSeparator: boolean;
}

interface SourceRange {
  start: number;
  end: number;
  spread: boolean;
}

const HILOG_MODULES: string[] = ['@ohos.hilog', '@kit.PerformanceAnalysisKit'];
const CONSOLE_LEVELS: string[] = ['log', 'debug', 'info', 'warn', 'error', 'trace'];
const HILOG_LEVELS: string[] = ['debug', 'info', 'warn', 'error', 'fatal'];
const BRIDGE_IMPORT = '@guancecloud/ft_sdk/Index';
// Hvigor can read a source file through more than one compiler layer in an
// incremental/daemon build. Keep a marker in the in-memory result so a later
// reader does not wrap the original console/HiLog call a second time.
const TRANSFORM_MARKER = '/* guance-console-log-transform:instrumented */';

export function isApplicationArkTsSource(id: string): boolean {
  const normalizedId = id.replace(/\\/g, '/');
  return (normalizedId.endsWith('.ets') || normalizedId.endsWith('.ts')) &&
    normalizedId.includes('/src/main/ets/') && !normalizedId.includes('/oh_modules/') &&
    !normalizedId.includes('/ft_sdk/src/main/ets/');
}

function visit(ts: TypeScriptApi, node: any, visitor: (current: any) => void): void {
  visitor(node);
  ts.forEachChild(node, (child: any) => visit(ts, child, visitor));
}

function collectIdentifierNames(ts: TypeScriptApi, sourceFile: any): Set<string> {
  const identifiers = new Set<string>();
  visit(ts, sourceFile, (node: any) => {
    if (ts.isIdentifier(node)) {
      identifiers.add(node.text);
    }
  });
  return identifiers;
}

function collectHiLogBindings(ts: TypeScriptApi, sourceFile: any): Map<string, any> {
  const bindings = new Map<string, any>();
  sourceFile.statements.forEach((statement: any) => {
    if (!ts.isImportDeclaration(statement) || !statement.moduleSpecifier ||
      !ts.isStringLiteral(statement.moduleSpecifier) ||
      !HILOG_MODULES.includes(statement.moduleSpecifier.text) || !statement.importClause || statement.importClause.isTypeOnly) {
      return;
    }

    const importClause = statement.importClause;
    if (importClause.name) {
      bindings.set(importClause.name.text, importClause);
    }
    if (!importClause.namedBindings) {
      return;
    }
    if (ts.isNamespaceImport(importClause.namedBindings)) {
      bindings.set(importClause.namedBindings.name.text, importClause.namedBindings);
      return;
    }
    importClause.namedBindings.elements.forEach((element: any) => {
      const importedName = element.propertyName ? element.propertyName.text : element.name.text;
      if (importedName === 'hilog' && !element.isTypeOnly) {
        bindings.set(element.name.text, element);
      }
    });
  });
  return bindings;
}

function needsStatementSeparator(ts: TypeScriptApi, node: any): boolean {
  const statement = node.parent;
  if (!ts.isExpressionStatement(statement)) {
    return false;
  }
  const container = statement.parent;
  // Only statement lists accept a leading empty statement. In an unbraced
  // if/loop body it would replace the body; inside an expression it is invalid.
  return ts.isSourceFile(container) || ts.isBlock(container) || ts.isModuleBlock(container) ||
    ts.isCaseClause(container) || ts.isDefaultClause(container);
}

function collectCandidates(ts: TypeScriptApi, sourceFile: any, code: string): TransformCandidate[] {
  const candidates: TransformCandidate[] = [];
  const hiLogBindings = collectHiLogBindings(ts, sourceFile);
  const resolve = createLexicalResolver(ts, sourceFile);

  visit(ts, sourceFile, (node: any) => {
    if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression)) {
      return;
    }
    const delegate = node.expression.expression;
    if (!ts.isIdentifier(delegate)) {
      return;
    }
    const delegateName = delegate.text;
    const level = node.expression.name.text;
    const start = node.getStart(sourceFile);
    const end = node.end;
    const calleeEnd = node.expression.end;
    if (start < 0 || end > code.length || calleeEnd < start || calleeEnd > end) {
      return;
    }

    const callArguments: SourceRange[] = node.arguments.map((argument: any) => ({
      start: argument.getStart(sourceFile),
      end: argument.end,
      spread: ts.isSpreadElement(argument)
    }));
    const statementSeparator = needsStatementSeparator(ts, node);
    if (delegateName === 'console' && !resolve(delegate, delegateName) && CONSOLE_LEVELS.includes(level)) {
      candidates.push({ start, end, calleeEnd, delegate: delegateName, level, source: 'console', callArguments,
        needsStatementSeparator: statementSeparator });
      return;
    }
    if (hiLogBindings.has(delegateName) && resolve(delegate, delegateName) === hiLogBindings.get(delegateName) &&
      HILOG_LEVELS.includes(level) && (callArguments.length >= 3 || callArguments.some(argument => argument.spread))) {
      candidates.push({ start, end, calleeEnd, delegate: delegateName, level, source: 'hilog', callArguments,
        needsStatementSeparator: statementSeparator });
    }
  });
  return candidates;
}

function selectBridgeName(identifiers: Set<string>): string {
  const baseName = '__ftConsoleLogBridge';
  let bridgeName = baseName;
  let suffix = 1;
  while (identifiers.has(bridgeName)) {
    bridgeName = `${baseName}${suffix}`;
    suffix++;
  }
  return bridgeName;
}

function isNestedIn(candidate: TransformCandidate, parent: TransformCandidate): boolean {
  return parent !== candidate && parent.start <= candidate.start && parent.end >= candidate.end;
}

function renderCandidates(code: string, candidates: TransformCandidate[], bridgeName: string,
  rangeStart: number, rangeEnd: number): string {
  const inRange = candidates.filter((candidate: TransformCandidate) =>
    candidate.start >= rangeStart && candidate.end <= rangeEnd);
  const directCandidates = inRange.filter((candidate: TransformCandidate) =>
    !inRange.some((parent: TransformCandidate) => isNestedIn(candidate, parent)));
  if (directCandidates.length === 0) {
    return code.slice(rangeStart, rangeEnd);
  }

  const descending = directCandidates.sort((left: TransformCandidate, right: TransformCandidate) =>
    right.start - left.start);
  let cursor = rangeEnd;
  let output = '';
  for (const candidate of descending) {
    output = renderCandidate(code, candidates, bridgeName, candidate) + code.slice(candidate.end, cursor) + output;
    cursor = candidate.start;
  }
  return code.slice(rangeStart, cursor) + output;
}

function renderCandidate(code: string, candidates: TransformCandidate[], bridgeName: string,
  candidate: TransformCandidate): string {
  const renderedArguments = candidate.callArguments.map((argument: SourceRange) =>
    renderCandidates(code, candidates, bridgeName, argument.start, argument.end));
  const statementSeparator = candidate.needsStatementSeparator ? ';' : '';
  if (candidate.callArguments.some(argument => argument.spread)) {
    // One rest binding receives the expanded values, rather than one parameter
    // per syntax argument. Array construction preserves iteration/evaluation order.
    if (candidate.source === 'console') {
      return `${statementSeparator}((...__ftConsoleArgs: Object[]): void => ${bridgeName}.console('${candidate.level}', ` +
        `(): void => ${candidate.delegate}.${candidate.level}(...(__ftConsoleArgs as string[])), ` +
        `...__ftConsoleArgs))(${renderedArguments.join(', ')})`;
    }
    const header = '__ftHiLogArgs[0] as number, __ftHiLogArgs[1] as string, __ftHiLogArgs[2] as string';
    return `${statementSeparator}((...__ftHiLogArgs: Object[]): void => { ` +
      `const __ftHiLogValues: Object[] = __ftHiLogArgs.slice(3); ` +
      `${bridgeName}.hilog('${candidate.level}', ${header}, ` +
      `(): void => ${candidate.delegate}.${candidate.level}(${header}, ...__ftHiLogValues), ` +
      `...__ftHiLogValues); })(${renderedArguments.join(', ')})`;
  }
  if (candidate.source === 'console') {
    const argumentNames = renderedArguments.map((_argument: string, index: number) => `__ftConsoleArg${index}`);
    const parameterDeclarations = argumentNames.map((name: string) => `${name}: Object`).join(', ');
    const originalCallArguments = argumentNames.map((name: string) => `${name} as string`);
    const originalCall = `${candidate.delegate}.${candidate.level}(${originalCallArguments.join(', ')})`;
    const captureArguments = argumentNames.length > 0 ? `, ${argumentNames.join(', ')}` : '';
    return `${statementSeparator}((${parameterDeclarations}): void => ${bridgeName}.console('${candidate.level}', ` +
      `(): void => ${originalCall}${captureArguments}))(${renderedArguments.join(', ')})`;
  }

  const argumentNames = renderedArguments.map((_argument: string, index: number) => {
    if (index === 0) {
      return '__ftHiLogDomain';
    }
    if (index === 1) {
      return '__ftHiLogTag';
    }
    if (index === 2) {
      return '__ftHiLogFormat';
    }
    return `__ftHiLogArg${index - 3}`;
  });
  const parameterDeclarations = argumentNames.map((name: string, index: number) => {
    if (index === 0) {
      return `${name}: number`;
    }
    if (index === 1 || index === 2) {
      return `${name}: string`;
    }
    return `${name}: Object`;
  }).join(', ');
  const originalCall = `${candidate.delegate}.${candidate.level}(${argumentNames.join(', ')})`;
  const captureArguments = argumentNames.length > 3 ? `, ${argumentNames.slice(3).join(', ')}` : '';
  return `${statementSeparator}((${parameterDeclarations}): void => ${bridgeName}.hilog('${candidate.level}', ` +
    `${argumentNames[0]}, ${argumentNames[1]}, ${argumentNames[2]}, (): void => ${originalCall}` +
    `${captureArguments}))(${renderedArguments.join(', ')})`;
}

function findImportInsertionOffset(ts: TypeScriptApi, sourceFile: any): number {
  let offset = 0;
  sourceFile.statements.forEach((statement: any) => {
    if (ts.isImportDeclaration(statement)) {
      offset = statement.end;
    }
  });
  return offset;
}

export function transformConsoleLogSource(ts: TypeScriptApi, id: string, code: string, readSource?: SourceReader): string {
  if (!isApplicationArkTsSource(id) || code.includes(TRANSFORM_MARKER) ||
    !hasRuntimeDependency(ts, id, '@guancecloud/ft_sdk', readSource)) {
    return code;
  }
  const sourceFile = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const candidates = collectCandidates(ts, sourceFile, code);
  if (candidates.length === 0) {
    return code;
  }

  const bridgeName = selectBridgeName(collectIdentifierNames(ts, sourceFile));
  const transformedCode = renderCandidates(code, candidates, bridgeName, 0, code.length);
  const insertionOffset = findImportInsertionOffset(ts, sourceFile);
  const transformedInsertionOffset = renderCandidates(code, candidates, bridgeName, 0, insertionOffset).length;
  const bridgeImport = `\n${TRANSFORM_MARKER}\n` +
    `import { FTConsoleLogBridge as ${bridgeName} } from '${BRIDGE_IMPORT}';\n` +
    `${bridgeName}.markCompilerPluginInstalled();\n`;
  return transformedCode.slice(0, transformedInsertionOffset) + bridgeImport +
    transformedCode.slice(transformedInsertionOffset);
}
