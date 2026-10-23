/** Associate every native Web with its controller without replacing application IDs or callbacks. */
import { isApplicationArkTsSource } from './ft-console-log-transform';
import { hasRuntimeDependency, SourceReader } from './ft-transform-context';
import { createLexicalResolver } from './ft-lexical-scope';
import { allocateName, collectIdentifierNames } from './ft-generated-names';

type TypeScriptApi = any;
interface Injection { position: number; content: string; }

const MARKER = '/* guance-web-replay-transform:instrumented */';
const SDK_IMPORT = '@guancecloud/ft_sdk/Index';

export function transformWebReplaySource(ts: TypeScriptApi, id: string, code: string, readSource?: SourceReader): string {
  if (!isApplicationArkTsSource(id) || code.includes(MARKER) ||
    !hasRuntimeDependency(ts, id, '@guancecloud/ft_sdk', readSource) ||
    !hasRuntimeDependency(ts, id, '@guancecloud/ft_session_replay', readSource)) return code;

  const source = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS ?? ts.ScriptKind.TS);
  const identifiers = collectIdentifierNames(ts, source);
  const constructors: any[] = [];
  const resolve = createLexicalResolver(ts, source);
  let importEnd = 0;
  const visit = (node: any): void => {
    if (ts.isImportDeclaration(node)) importEnd = Math.max(importEnd, node.end);
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'Web' &&
      node.arguments.length === 1 && !ts.isSpreadElement(node.arguments[0]) &&
      !resolve(node.expression, 'Web')) constructors.push(node);
    ts.forEachChild(node, visit);
  };
  visit(source);
  if (constructors.length === 0) return code;

  const bridge = allocateName(identifiers, '__ftWebReplayBridge');
  const injections: Injection[] = [];
  for (const constructor of constructors) {
    const options = constructor.arguments[0];
    // Keep the pair adjacent, before any app modifier expression can evaluate another Web.
    injections.push({ position: options.getStart(source), content: `${bridge}.prepare(` });
    injections.push({ position: options.end, content: ')' });
    injections.push({ position: constructor.end,
      content: `.customProperty(${bridge}.PROPERTY, ${bridge}.consumeBindingId())` });
  }
  injections.push({ position: importEnd,
    content: `\n${MARKER}\nimport { FTWebViewReplayBridge as ${bridge} } from '${SDK_IMPORT}';\n` });
  injections.sort((left, right) => right.position - left.position);
  let result = code;
  for (const injection of injections) {
    result = result.slice(0, injection.position) + injection.content + result.slice(injection.position);
  }
  return result;
}
