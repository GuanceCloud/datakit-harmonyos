/** Shared, source-module-specific guards for compiler transforms. */
declare const require: any;

export type SourceReader = (fileName: string) => string | undefined;

export interface SourceTransformDiagnostic {
  fileName: string;
  line: number;
  column: number;
  reason: string;
  message: string;
}

export type SourceDiagnosticReporter = (diagnostic: SourceTransformDiagnostic) => void;

export function reportSourceDiagnostic(source: any, position: number, reason: string, message: string,
  reporter?: SourceDiagnosticReporter): void {
  if (!reporter) return;
  const location = source.getLineAndCharacterOfPosition(position);
  reporter({ fileName: source.fileName, line: location.line + 1, column: location.character + 1, reason, message });
}

/** Parse declarative child blocks without treating enum members as components. */
export function parseApplicationSource(ts: any, id: string, code: string, preliminary?: any): any {
  const source = preliminary ?? ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true,
    ts.ScriptKind.ETS ?? ts.ScriptKind.TS);
  if (!id.endsWith('.ets') || typeof ts.isStructDeclaration !== 'function' ||
    typeof ts.isEtsComponentExpression !== 'function') return source;
  const names = new Set<string>();
  const visit = (node: any): void => {
    if ((ts.isCallExpression(node) || ts.isEtsComponentExpression(node)) && ts.isIdentifier(node.expression)) {
      names.add(node.expression.text);
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  const components = Array.from(names).filter(name => !['ForEach', 'LazyForEach', 'Repeat'].includes(name));
  return ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, { ets: {
    components,
    render: { method: ['build', 'pageTransition'], decorator: ['Builder', 'LocalBuilder'] },
    extend: { decorator: ['Extend', 'AnimatableExtend'], components: components.map(name =>
      ({ name, type: `${name}Attribute`, instance: `${name}Instance` })) },
    styles: { decorator: 'Styles', component: { name: 'Common', type: 'T', instance: 'CommonInstance' }, property: 'stateStyles' },
    concurrent: { decorator: 'Concurrent' },
    customComponent: 'CustomComponent',
    syntaxComponents: { paramsUICallback: ['ForEach', 'LazyForEach'],
      attrUICallback: [{ name: 'Repeat', attributes: ['each', 'template'] }] }
  } });
}

export function reportSourceParseError(ts: any, source: any, reporter?: SourceDiagnosticReporter): boolean {
  if (source.parseDiagnostics.length === 0) return false;
  const diagnostic = source.parseDiagnostics[0];
  const remaining = source.parseDiagnostics.length - 1;
  reportSourceDiagnostic(source, diagnostic.start ?? 0, 'parse-error',
    `TS${diagnostic.code}: ${ts.flattenDiagnosticMessageText(diagnostic.messageText, ' ')}${
      remaining > 0 ? ` (${remaining} additional parse errors)` : ''}`, reporter);
  return true;
}

export function objectProperty(ts: any, object: any, name: string): any | undefined {
  if (!object || !ts.isObjectLiteralExpression(object)) return undefined;
  const matches = object.properties.filter((item: any) => ts.isPropertyAssignment(item) &&
    (ts.isIdentifier(item.name) || ts.isStringLiteral(item.name)) && item.name.text === name);
  return matches.length > 0 ? matches[matches.length - 1].initializer : undefined;
}

/** Read JSON5 as data syntax, without evaluating package contents. */
export function hasRuntimeDependency(ts: any, id: string, packageName: string, readSource?: SourceReader): boolean {
  const normalized = id.replace(/\\/g, '/');
  const sourceIndex = normalized.lastIndexOf('/src/main/ets/');
  if (sourceIndex < 0) return false;
  const packagePath = normalized.slice(0, sourceIndex) + '/oh-package.json5';
  try {
    const nodeRequire = require.main && typeof require.main.require === 'function'
      ? require.main.require.bind(require.main) : require;
    const code = readSource ? readSource(packagePath) : nodeRequire('fs').readFileSync(packagePath, 'utf8');
    if (typeof code !== 'string') return false;
    const parsed = ts.createSourceFile(packagePath, `const __package = ${code}`,
      ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    if (parsed.parseDiagnostics.length > 0 || parsed.statements.length !== 1 ||
      !ts.isVariableStatement(parsed.statements[0])) return false;
    const root = parsed.statements[0].declarationList.declarations[0].initializer;
    const dependency = objectProperty(ts, objectProperty(ts, root, 'dependencies'), packageName);
    // Runtime imports require an explicit dependency in the owning module.
    // Do not inherit the entry/root module's dependencies or match comments/devDependencies.
    return !!dependency && ts.isStringLiteral(dependency) && dependency.text.trim().length > 0;
  } catch (_) {
    return false;
  }
}
