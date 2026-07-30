/**
 * Guance console-log compiler plugin.
 *
 * Hvigor creates the ArkTS type-checking program before normal Rollup
 * transform hooks run. This plugin therefore rewrites only the in-memory
 * application source read by that program. Application files on disk are
 * never changed.
 */

declare const require: {
  main: {
    require(moduleName: string): any;
  };
};

type TypeScriptApi = any;

interface CompilePluginContext {
  share: {
    projectConfig: {
      etsLoaderPath: string;
    };
  };
}

interface TransformCandidate {
  start: number;
  end: number;
  calleeEnd: number;
  delegate: string;
  level: string;
  source: 'console' | 'hilog';
  callArguments: SourceRange[];
}

interface SourceRange {
  start: number;
  end: number;
}

const HILOG_MODULES: string[] = ['@ohos.hilog', '@kit.PerformanceAnalysisKit'];
const CONSOLE_LEVELS: string[] = ['log', 'debug', 'info', 'warn', 'error', 'trace'];
const HILOG_LEVELS: string[] = ['debug', 'info', 'warn', 'error', 'fatal'];
const BRIDGE_IMPORT = '@guancecloud/ft_sdk/Index';

let patchedFileSystem: any = null;
let originalReadFile: ((fileName: string, options?: any) => any) | null = null;

function isApplicationArkTsSource(id: string): boolean {
  return (id.endsWith('.ets') || id.endsWith('.ts')) && id.includes('/src/main/ets/') &&
    !id.includes('/oh_modules/') && !id.includes('/ft_sdk/');
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

function isNameDeclaredOutsideImports(ts: TypeScriptApi, sourceFile: any, name: string): boolean {
  let declared = false;
  visit(ts, sourceFile, (node: any) => {
    if (declared || ts.isImportDeclaration(node)) {
      return;
    }
    if (ts.isVariableDeclaration(node) || ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node) ||
      ts.isParameter(node) || ts.isEnumDeclaration(node) || ts.isInterfaceDeclaration(node) ||
      ts.isTypeAliasDeclaration(node)) {
      const declarationName = node.name;
      if (declarationName && ts.isIdentifier(declarationName) && declarationName.text === name) {
        declared = true;
      }
    }
  });
  return declared;
}

function collectHiLogBindings(ts: TypeScriptApi, sourceFile: any): Set<string> {
  const bindings = new Set<string>();
  sourceFile.statements.forEach((statement: any) => {
    if (!ts.isImportDeclaration(statement) || !statement.moduleSpecifier ||
      !ts.isStringLiteral(statement.moduleSpecifier) ||
      !HILOG_MODULES.includes(statement.moduleSpecifier.text) || !statement.importClause) {
      return;
    }

    const importClause = statement.importClause;
    if (importClause.name) {
      bindings.add(importClause.name.text);
    }
    if (!importClause.namedBindings) {
      return;
    }
    if (ts.isNamespaceImport(importClause.namedBindings)) {
      bindings.add(importClause.namedBindings.name.text);
      return;
    }
    importClause.namedBindings.elements.forEach((element: any) => {
      const importedName = element.propertyName ? element.propertyName.text : element.name.text;
      if (importedName === 'hilog') {
        bindings.add(element.name.text);
      }
    });
  });
  return bindings;
}

function collectCandidates(ts: TypeScriptApi, sourceFile: any, code: string): TransformCandidate[] {
  const candidates: TransformCandidate[] = [];
  const hiLogBindings = collectHiLogBindings(ts, sourceFile);
  const consoleIsShadowed = isNameDeclaredOutsideImports(ts, sourceFile, 'console');
  const shadowedHiLogBindings = new Set<string>();
  hiLogBindings.forEach((binding: string) => {
    if (isNameDeclaredOutsideImports(ts, sourceFile, binding)) {
      shadowedHiLogBindings.add(binding);
    }
  });

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
      end: argument.end
    }));
    if (delegateName === 'console' && !consoleIsShadowed && CONSOLE_LEVELS.includes(level)) {
      candidates.push({ start, end, calleeEnd, delegate: delegateName, level, source: 'console', callArguments });
      return;
    }
    if (hiLogBindings.has(delegateName) && !shadowedHiLogBindings.has(delegateName) &&
      HILOG_LEVELS.includes(level) && callArguments.length >= 3) {
      candidates.push({ start, end, calleeEnd, delegate: delegateName, level, source: 'hilog', callArguments });
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
  if (candidate.source === 'console') {
    const argumentNames = renderedArguments.map((_argument: string, index: number) => `__ftConsoleArg${index}`);
    const parameterDeclarations = argumentNames.map((name: string) => `${name}: Object`).join(', ');
    const originalCallArguments = argumentNames.map((name: string) => `${name} as string`);
    const originalCall = `${candidate.delegate}.${candidate.level}(${originalCallArguments.join(', ')})`;
    const captureArguments = argumentNames.length > 0 ? `, ${argumentNames.join(', ')}` : '';
    return `((${parameterDeclarations}): void => ${bridgeName}.console('${candidate.level}', ` +
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
  return `((${parameterDeclarations}): void => ${bridgeName}.hilog('${candidate.level}', ` +
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

function rewriteSource(ts: TypeScriptApi, id: string, code: string): string {
  if (!isApplicationArkTsSource(id)) {
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
  const bridgeImport = `\nimport { FTConsoleLogBridge as ${bridgeName} } from '${BRIDGE_IMPORT}';\n` +
    `${bridgeName}.markCompilerPluginInstalled();\n`;
  return transformedCode.slice(0, transformedInsertionOffset) + bridgeImport +
    transformedCode.slice(transformedInsertionOffset);
}

function installSourceReader(context: CompilePluginContext): void {
  if (patchedFileSystem !== null) {
    return;
  }

  const typeScriptPath = `${context.share.projectConfig.etsLoaderPath}/node_modules/typescript`;
  const ts = require.main.require(typeScriptPath);
  const fileSystem = require.main.require('fs');
  const buffer = require.main.require('buffer');
  const readFile = fileSystem.readFileSync as (fileName: string, options?: any) => any;
  patchedFileSystem = fileSystem;
  originalReadFile = readFile;
  fileSystem.readFileSync = (fileName: string, options?: any): any => {
    const content = readFile(fileName, options);
    if (typeof fileName !== 'string' || !isApplicationArkTsSource(fileName)) {
      return content;
    }
    const code = typeof content === 'string' ? content : content.toString();
    const transformedCode = rewriteSource(ts, fileName, code);
    return typeof content === 'string' ? transformedCode : buffer.Buffer.from(transformedCode);
  };
}

function restoreSourceReader(): void {
  if (patchedFileSystem !== null && originalReadFile !== null) {
    patchedFileSystem.readFileSync = originalReadFile;
  }
  patchedFileSystem = null;
  originalReadFile = null;
}

export default {
  name: 'guance-console-log-transform',
  order: 'first',
  buildStart(this: CompilePluginContext): void {
    installSourceReader(this);
  },
  buildEnd(): void {
    restoreSourceReader();
  }
};
