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
import { allocateName, collectIdentifierNames } from './ft-generated-names';

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
  generatedNames?: string[];
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
    // Retain optional calls verbatim so their receiver/method short-circuit also
    // controls argument evaluation. Nested ordinary calls remain eligible.
    if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression) ||
      (ts.isOptionalChain && ts.isOptionalChain(node))) {
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

function allocateCandidateNames(candidate: TransformCandidate, identifiers: Set<string>): string[] {
  const prefix = candidate.source === 'console' ? '__ftConsole' : '__ftHiLog';
  return ['Call', 'Args', 'Values'].map(suffix => allocateName(identifiers, prefix + suffix));
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
  const [original, args, values] = candidate.generatedNames!;
  const valueType = '(Object | null | undefined)';
  const originalType = candidate.source === 'console' ? `(...${args}: ${valueType}[]) => void` :
    `(domain: number, tag: string, format: string, ...${values}: ${valueType}[]) => void`;
  let body: string;
  if (candidate.source === 'console') {
    body = `${bridgeName}.console('${candidate.level}', (): void => ${original}(...${args}), ` +
      `...(${args} as Object[]))`;
  } else {
    const header = `${args}[0] as number, ${args}[1] as string, ${args}[2] as string`;
    body = `{ const ${values}: ${valueType}[] = ${args}.slice(3); ` +
      `${bridgeName}.hilog('${candidate.level}', ${header}, (): void => ${original}(${header}, ...${values}), ` +
      `...(${values} as Object[])); }`;
  }
  // Resolve and bind the original method before evaluating its arguments.
  // Casting only the capture array keeps compatibility with older runtime HARs;
  // null/undefined values themselves are forwarded unchanged.
  // HiLog is a platform namespace, not an ArkTS object receiver. Its exported
  // functions are static; console methods retain their receiver through bind.
  const callee = `${candidate.delegate}.${candidate.level}`;
  const captured = candidate.source === 'console' ? `${callee}.bind(${candidate.delegate})` : callee;
  const argumentsText = renderedArguments.length > 0 ? ', ' + renderedArguments.join(', ') : '';
  return `${statementSeparator}((${original}: ${originalType}, ...${args}: ${valueType}[]): void => ${body})` +
    `(${captured} as ${originalType}${argumentsText})`;
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

  const identifiers = collectIdentifierNames(ts, sourceFile);
  const bridgeName = allocateName(identifiers, '__ftConsoleLogBridge');
  candidates.forEach(candidate => { candidate.generatedNames = allocateCandidateNames(candidate, identifiers); });
  const transformedCode = renderCandidates(code, candidates, bridgeName, 0, code.length);
  const insertionOffset = findImportInsertionOffset(ts, sourceFile);
  const transformedInsertionOffset = renderCandidates(code, candidates, bridgeName, 0, insertionOffset).length;
  const bridgeImport = `\n${TRANSFORM_MARKER}\n` +
    `import { FTConsoleLogBridge as ${bridgeName} } from '${BRIDGE_IMPORT}';\n` +
    `${bridgeName}.markCompilerPluginInstalled();\n`;
  return transformedCode.slice(0, transformedInsertionOffset) + bridgeImport +
    transformedCode.slice(transformedInsertionOffset);
}
