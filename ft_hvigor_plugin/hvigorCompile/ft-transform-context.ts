/** Shared, source-module-specific guards for compiler transforms. */
declare const require: any;

export type SourceReader = (fileName: string) => string | undefined;

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
