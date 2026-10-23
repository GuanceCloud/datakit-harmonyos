/**
 * Guance cold-launch compiler plugin.
 *
 * The plugin injects cold-launch boundaries into Ability lifecycle methods in
 * the compiler's in-memory source. Application files are never modified.
 */

import { hasRuntimeDependency } from './ft-transform-context';

declare const require: any;
declare const __dirname: string;

type TypeScriptApi = any;
type AbilityClassKind = 'stage' | 'ui' | 'other' | 'intent' | 'legacyIntent';
type SourceReader = (fileName: string) => string | undefined;

interface AbilityClassInfo {
  kind: AbilityClassKind | null;
  applicationBase: boolean;
}

interface AbilityBase {
  kind: AbilityClassKind | null;
  declaration?: any;
}

interface LaunchParameterTypes {
  want: string;
  abilityConstant: string;
  needed: boolean;
}

interface ColdLaunchInjection {
  position: number;
  content: string;
}

interface ColdLaunchInjections {
  injections: ColdLaunchInjection[];
  hasUIAbility: boolean;
}

const COLD_LAUNCH_BRIDGE_IMPORT = '@guancecloud/ft_sdk/Index';
const COLD_LAUNCH_TRANSFORM_MARKER = '/* guance-cold-launch-transform:instrumented */';

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

function selectIdentifierName(identifiers: Set<string>, baseName: string): string {
  let bridgeName = baseName;
  let suffix = 1;
  while (identifiers.has(bridgeName)) {
    bridgeName = `${baseName}${suffix}`;
    suffix++;
  }
  identifiers.add(bridgeName);
  return bridgeName;
}

function getPluginVersion(): string {
  try {
    const fileSystem = require.main.require('fs');
    const path = require.main.require('path');
    const packagePath = path.resolve(__dirname, '..', 'package.json');
    const packageInfo = JSON.parse(fileSystem.readFileSync(packagePath, 'utf8')) as { version?: string };
    if (typeof packageInfo.version === 'string') {
      return packageInfo.version.trim();
    }
  } catch (_) {
    // Do not inject a guessed version when a custom package layout prevents
    // reading package.json. A missing entry is more accurate than fake data.
  }
  return '';
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

/** Only opt in when a readable HAP manifest explicitly has no module entry. */
function needsUIAbilityModuleFallback(ts: TypeScriptApi, id: string, readSource?: SourceReader): boolean {
  const normalized = id.replace(/\\/g, '/');
  const sourceIndex = normalized.lastIndexOf('/src/main/ets/');
  if (sourceIndex < 0) {
    return false;
  }
  const manifestPath = normalized.slice(0, sourceIndex) + '/src/main/module.json5';
  try {
    const nodeRequire = require.main && typeof require.main.require === 'function'
      ? require.main.require.bind(require.main) : require;
    const code = readSource ? readSource(manifestPath) : nodeRequire('fs').readFileSync(manifestPath, 'utf8');
    if (typeof code !== 'string') {
      return false;
    }
    // Parsing an object initializer accepts JSON5 comments, single quotes and
    // unquoted keys without mistaking nested ability srcEntry fields for Stage.
    const parsed = ts.createSourceFile(manifestPath, `const __manifest = ${code}`,
      ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    if (parsed.parseDiagnostics.length > 0 || parsed.statements.length !== 1 ||
      !ts.isVariableStatement(parsed.statements[0])) {
      return false;
    }
    const root = parsed.statements[0].declarationList.declarations[0].initializer;
    const property = (object: any, name: string): any | undefined => {
      if (!object || !ts.isObjectLiteralExpression(object)) {
        return undefined;
      }
      const matches = object.properties.filter((item: any) => ts.isPropertyAssignment(item) &&
        (ts.isIdentifier(item.name) || ts.isStringLiteral(item.name)) && item.name.text === name);
      return matches.length > 0 ? matches[matches.length - 1].initializer : undefined;
    };
    const module = property(root, 'module');
    const type = property(module, 'type');
    if (!type || !ts.isStringLiteral(type) || (type.text !== 'entry' && type.text !== 'feature')) {
      return false;
    }
    const stageEntry = property(module, 'srcEntry');
    return stageEntry === undefined || (ts.isStringLiteral(stageEntry) && stageEntry.text.trim().length === 0);
  } catch (_) {
    return false;
  }
}

function classifyAbilityBaseName(name: string): AbilityClassKind | null {
  if (name === 'InsightIntentEntryExecutor') {
    return 'intent';
  }
  if (name === 'InsightIntentExecutor') {
    return 'legacyIntent';
  }
  if (name === 'AbilityStage') {
    return 'stage';
  }
  if (name === 'UIAbility') {
    return 'ui';
  }
  if (name.endsWith('Ability') || name.endsWith('ExtensionAbility')) {
    return 'other';
  }
  return null;
}

function bindingContains(ts: TypeScriptApi, binding: any, name: string): boolean {
  if (ts.isIdentifier(binding)) {
    return binding.text === name;
  }
  return !!binding.elements && binding.elements.some((element: any) =>
    ts.isBindingElement(element) && bindingContains(ts, element.name, name));
}

function findValueDeclaration(ts: TypeScriptApi, location: any, name: string): any | null {
  for (let scope = location.parent; scope; scope = scope.parent) {
    if (ts.isClassDeclaration(scope) && scope.name && scope.name.text === name) {
      return scope;
    }
    if (ts.isFunctionLike(scope)) {
      const parameter = scope.parameters.find((item: any) => bindingContains(ts, item.name, name));
      if (parameter) {
        return parameter;
      }
    }
    for (const statement of scope.statements || []) {
      if (ts.isImportDeclaration(statement) && statement.importClause) {
        const clause = statement.importClause;
        if (clause.name && clause.name.text === name) {
          return clause;
        }
        if (clause.namedBindings) {
          if (ts.isNamespaceImport(clause.namedBindings) && clause.namedBindings.name.text === name) {
            return clause.namedBindings;
          }
          if (ts.isNamedImports(clause.namedBindings)) {
            const imported = clause.namedBindings.elements.find((item: any) => item.name.text === name);
            if (imported) {
              return imported;
            }
          }
        }
      }
      if ((ts.isClassDeclaration(statement) || ts.isFunctionDeclaration(statement) ||
        ts.isEnumDeclaration(statement) || ts.isModuleDeclaration(statement)) &&
        statement.name && statement.name.text === name) {
        return statement;
      }
      if (ts.isVariableStatement(statement)) {
        const variable = statement.declarationList.declarations.find((item: any) =>
          bindingContains(ts, item.name, name));
        if (variable) {
          return variable;
        }
      }
    }
  }
  return null;
}

/** Resolve source-visible inheritance without reading through our own transform hook. */
function createAbilityClassResolver(ts: TypeScriptApi, sourceFile: any, readSource?: SourceReader):
  (declaration: any) => AbilityClassInfo {
  const nodeRequire = require.main && typeof require.main.require === 'function'
    ? require.main.require.bind(require.main) : require;
  const path = nodeRequire('path');
  const sources = new Map<string, any | null>();
  sources.set(path.resolve(sourceFile.fileName), sourceFile);
  const classCache = new Map<any, AbilityClassInfo>();
  const resolvingClasses = new Set<any>();
  const resolvingExports = new Set<string>();
  const unknown: AbilityBase = { kind: null };

  const loadRelativeSource = (from: any, moduleName: string): any | null => {
    if (!moduleName.startsWith('.')) {
      return null;
    }
    const base = path.resolve(path.dirname(from.fileName), moduleName);
    const candidates = /\.(ets|ts)$/.test(base) ? [base] :
      [base + '.ets', base + '.ts', path.join(base, 'Index.ets'), path.join(base, 'index.ets'),
        path.join(base, 'Index.ts'), path.join(base, 'index.ts')];
    for (const fileName of candidates) {
      if (!isApplicationArkTsSource(fileName)) {
        continue;
      }
      if (!sources.has(fileName)) {
        let parsed: any | null = null;
        try {
          const code = readSource ? readSource(fileName) : nodeRequire('fs').readFileSync(fileName, 'utf8');
          if (typeof code === 'string') {
            parsed = ts.createSourceFile(fileName, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
          }
        } catch (_) {
          // A missing or unresolved source is not evidence of an Ability base.
        }
        sources.set(fileName, parsed);
      }
      if (sources.get(fileName)) {
        return sources.get(fileName);
      }
    }
    return null;
  };

  const resolveModule = (from: any, moduleName: string, exportedName: string): AbilityBase => {
    const name = exportedName === 'default' ? moduleName.slice(moduleName.lastIndexOf('.') + 1) : exportedName;
    const kind = classifyAbilityBaseName(name);
    if (moduleName === '@kit.AbilityKit' || moduleName.startsWith('@ohos.app.ability.') ||
      (kind === 'other' && (moduleName.startsWith('@kit.') || moduleName.startsWith('@ohos.')))) {
      return { kind };
    }
    const imported = loadRelativeSource(from, moduleName);
    return imported ? resolveExport(imported, exportedName) : unknown;
  };

  const resolveBinding = (declaration: any, member?: string): AbilityBase => {
    if (!declaration) {
      return unknown;
    }
    if (ts.isClassDeclaration(declaration)) {
      return { kind: resolveClass(declaration).kind, declaration };
    }
    let importDeclaration = declaration;
    while (importDeclaration && !ts.isImportDeclaration(importDeclaration)) {
      importDeclaration = importDeclaration.parent;
    }
    if (!importDeclaration || importDeclaration.importClause.isTypeOnly || declaration.isTypeOnly) {
      return unknown;
    }
    let exportedName: string;
    if (ts.isImportClause(declaration)) {
      exportedName = 'default';
    } else if (ts.isImportSpecifier(declaration)) {
      exportedName = (declaration.propertyName || declaration.name).text;
    } else if (ts.isNamespaceImport(declaration) && member) {
      exportedName = member;
    } else {
      return unknown;
    }
    return resolveModule(importDeclaration.getSourceFile(), importDeclaration.moduleSpecifier.text, exportedName);
  };

  const resolveExpression = (expression: any): AbilityBase => {
    if (ts.isIdentifier(expression)) {
      return resolveBinding(findValueDeclaration(ts, expression, expression.text));
    }
    if (ts.isPropertyAccessExpression(expression) && ts.isIdentifier(expression.expression)) {
      return resolveBinding(findValueDeclaration(ts, expression, expression.expression.text), expression.name.text);
    }
    return unknown;
  };

  const resolveExport = (source: any, name: string): AbilityBase => {
    const key = `${source.fileName}:${name}`;
    if (resolvingExports.has(key)) {
      return unknown;
    }
    resolvingExports.add(key);
    try {
      for (const statement of source.statements) {
        if (ts.isClassDeclaration(statement)) {
          const modifiers = statement.modifiers || [];
          const isDefault = modifiers.some((item: any) => item.kind === ts.SyntaxKind.DefaultKeyword);
          const isExported = modifiers.some((item: any) => item.kind === ts.SyntaxKind.ExportKeyword);
          if ((name === 'default' && isDefault) ||
            (name !== 'default' && isExported && statement.name && statement.name.text === name)) {
            return resolveBinding(statement);
          }
        }
        if (name === 'default' && ts.isExportAssignment(statement) && !statement.isExportEquals) {
          return resolveExpression(statement.expression);
        }
        if (!ts.isExportDeclaration(statement) || statement.isTypeOnly) {
          continue;
        }
        if (statement.exportClause && ts.isNamedExports(statement.exportClause)) {
          const exported = statement.exportClause.elements.find((item: any) => item.name.text === name);
          if (exported && !exported.isTypeOnly) {
            const localName = (exported.propertyName || exported.name).text;
            return statement.moduleSpecifier
              ? resolveModule(source, statement.moduleSpecifier.text, localName)
              : resolveBinding(findValueDeclaration(ts, statement, localName));
          }
        } else if (!statement.exportClause && statement.moduleSpecifier && name !== 'default') {
          const resolved = resolveModule(source, statement.moduleSpecifier.text, name);
          if (resolved.kind) {
            return resolved;
          }
        }
      }
      return unknown;
    } finally {
      resolvingExports.delete(key);
    }
  };

  const resolveClass = (declaration: any): AbilityClassInfo => {
    const cached = classCache.get(declaration);
    if (cached) {
      return cached;
    }
    if (resolvingClasses.has(declaration)) {
      return { kind: null, applicationBase: false };
    }
    resolvingClasses.add(declaration);
    let base: AbilityBase = unknown;
    for (const clause of declaration.heritageClauses || []) {
      if (clause.token === ts.SyntaxKind.ExtendsKeyword && clause.types.length > 0) {
        base = resolveExpression(clause.types[0].expression);
        break;
      }
    }
    const info: AbilityClassInfo = { kind: base.kind, applicationBase: !!base.declaration };
    resolvingClasses.delete(declaration);
    classCache.set(declaration, info);
    return info;
  };
  return resolveClass;
}

function methodIndentation(code: string, method: any): string {
  const methodStart = method.getStart();
  const lineStart = code.lastIndexOf('\n', methodStart) + 1;
  const match = code.slice(lineStart, methodStart).match(/^\s*/);
  return (match ? match[0] : '') + '  ';
}

function classIndentation(code: string, classDeclaration: any): string {
  const classStart = classDeclaration.getStart();
  const lineStart = code.lastIndexOf('\n', classStart) + 1;
  const match = code.slice(lineStart, classStart).match(/^\s*/);
  return match ? match[0] : '';
}

function blockIndentation(code: string, block: any): string {
  const blockStart = block.getStart();
  const lineStart = code.lastIndexOf('\n', blockStart) + 1;
  const match = code.slice(lineStart, blockStart).match(/^\s*/);
  return (match ? match[0] : '') + '  ';
}

function intentDecoratorString(ts: TypeScriptApi, declaration: any, field: string): string {
  const decorators = ts.canHaveDecorators && ts.canHaveDecorators(declaration)
    ? (ts.getDecorators(declaration) || []) : (declaration.decorators || []);
  for (const decorator of decorators) {
    const call = decorator.expression;
    if (!ts.isCallExpression(call) || call.arguments.length === 0 ||
      !ts.isObjectLiteralExpression(call.arguments[0])) {
      continue;
    }
    for (const property of call.arguments[0].properties) {
      if (ts.isPropertyAssignment(property) && property.name && property.name.text === field &&
        ts.isStringLiteral(property.initializer)) {
        return JSON.stringify(property.initializer.text);
      }
    }
  }
  return "''";
}

function collectWindowStageParameterNames(ts: TypeScriptApi, sourceFile: any, method: any): Set<string> {
  const names = new Set<string>();
  method.parameters.forEach((parameter: any) => {
    if (!ts.isIdentifier(parameter.name)) {
      return;
    }
    const typeText = parameter.type ? parameter.type.getText(sourceFile) : '';
    if (parameter.name.text === 'windowStage' || typeText.includes('WindowStage')) {
      names.add(parameter.name.text);
    }
  });
  return names;
}

function createFirstFrameRetryInjections(ts: TypeScriptApi, sourceFile: any, code: string,
  method: any, bridgeName: string, windowStageNames: Set<string>): ColdLaunchInjection[] {
  const injections: ColdLaunchInjection[] = [];
  visit(ts, method.body, (node: any) => {
    if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression)) {
      return;
    }
    const delegate = node.expression.expression;
    if (!ts.isIdentifier(delegate) || !windowStageNames.has(delegate.text) ||
      node.expression.name.text !== 'loadContent' || node.arguments.length === 0) {
      return;
    }
    const windowStageName = delegate.text;
    const callback = node.arguments[node.arguments.length - 1];
    if ((!ts.isArrowFunction(callback) && !ts.isFunctionExpression(callback)) || !ts.isBlock(callback.body)) {
      return;
    }
    const indentation = blockIndentation(code, callback.body);
    const errorParameter = callback.parameters.length > 0 && ts.isIdentifier(callback.parameters[0].name)
      ? callback.parameters[0].name.text : null;
    const retry = `${bridgeName}.observeFirstFrame(${windowStageName});`;
    const content = errorParameter === null
      ? `\n${indentation}${retry}`
      : `\n${indentation}if (!${errorParameter} || !${errorParameter}.code) {\n` +
        `${indentation}  ${retry}\n${indentation}}`;
    injections.push({ position: callback.body.getStart(sourceFile) + 1, content });
  });
  return injections;
}

function createColdLaunchInjections(ts: TypeScriptApi, sourceFile: any, code: string,
  bridgeName: string, pluginVersion: string, identifiers: Set<string>,
  launchTypes: LaunchParameterTypes, readSource?: SourceReader): ColdLaunchInjections {
  const injections: ColdLaunchInjection[] = [];
  let hasUIAbility = false;
  const resolveClass = createAbilityClassResolver(ts, sourceFile, readSource);
  const pluginVersionArgument = pluginVersion.length > 0 ? `, ${JSON.stringify(pluginVersion)}` : '';
  visit(ts, sourceFile, (node: any) => {
    if (!ts.isClassDeclaration(node)) {
      return;
    }
    const classification = resolveClass(node);
    const kind = classification.kind;
    if (!kind) {
      return;
    }
    if (kind === 'ui') {
      hasUIAbility = true;
    }
    let hasOnCreate = false;
    let hasOnForeground = false;
    let hasOnBackground = false;
    let hasOnNewWant = false;
    node.members.forEach((member: any) => {
      if (!ts.isMethodDeclaration(member) || !member.body || !member.name || !ts.isIdentifier(member.name)) {
        return;
      }
      const indentation = methodIndentation(code, member);
      const position = member.body.getStart(sourceFile) + 1;
      if (kind === 'intent' || kind === 'legacyIntent') {
        let mode: string | null = null;
        if (kind === 'intent' && member.name.text === 'onExecute') {
          mode = 'this.executeMode';
        } else if (kind === 'legacyIntent' && member.name.text === 'onExecuteInUIAbilityForegroundMode') {
          mode = '0';
        } else if (kind === 'legacyIntent' && member.name.text === 'onExecuteInUIAbilityBackgroundMode') {
          mode = '1';
        }
        if (mode !== null) {
          const intentName = kind === 'intent' ? intentDecoratorString(ts, node, 'intentName') :
            (member.parameters.length > 0 && ts.isIdentifier(member.parameters[0].name)
              ? member.parameters[0].name.text : "''");
          const abilityName = kind === 'intent' ? intentDecoratorString(ts, node, 'abilityName') : "''";
          injections.push({ position, content: `\n${indentation}${bridgeName}.recordInsightIntentExecute(` +
            `${mode}, ${intentName}, this.context, ${abilityName});` });
        }
        return;
      }
      if (member.name.text === 'onCreate') {
        hasOnCreate = true;
        let content = kind === 'ui' ? '' :
          `\n${indentation}${bridgeName}.recordApplicationInit(this.context${pluginVersionArgument});`;
        if (kind === 'ui') {
          const parameters = member.parameters;
          let wantName = parameters.length > 0 && ts.isIdentifier(parameters[0].name)
            ? parameters[0].name.text : 'undefined';
          let launchParamName = parameters.length > 1 && ts.isIdentifier(parameters[1].name)
            ? parameters[1].name.text : 'undefined';
          // Even an onCreate() that ignores both parameters must pass the
          // actual system reason to the SDK. Add typed optional parameters
          // to the in-memory source without changing the application's file.
          if (parameters.length < 2) {
            launchTypes.needed = true;
            const added: string[] = [];
            if (parameters.length === 0) {
              wantName = selectIdentifierName(identifiers, '__ftLaunchWant');
              added.push(`${wantName}?: ${launchTypes.want}`);
            }
            launchParamName = selectIdentifierName(identifiers, '__ftLaunchParam');
            added.push(`${launchParamName}?: ${launchTypes.abilityConstant}.LaunchParam`);
            const beforeClose = code.lastIndexOf(')', member.body.getStart(sourceFile));
            const separator = parameters.length > 0 && !parameters.hasTrailingComma ? ', ' : '';
            injections.push({ position: beforeClose, content: separator + added.join(', ') });
          }
          content += `\n${indentation}${bridgeName}.recordFirstUIAbilityCreate(${launchParamName}, ${wantName}, this);`;
        }
        injections.push({ position, content });
        return;
      }
      if (kind === 'ui' && (member.name.text === 'onForeground' || member.name.text === 'onBackground' ||
        member.name.text === 'onNewWant')) {
        if (member.name.text === 'onForeground') {
          hasOnForeground = true;
        } else if (member.name.text === 'onBackground') {
          hasOnBackground = true;
        } else {
          hasOnNewWant = true;
        }
        const hook = member.name.text === 'onForeground' ? 'recordUIAbilityForeground' :
          (member.name.text === 'onBackground' ? 'recordUIAbilityBackground' : 'recordUIAbilityNewWant');
        injections.push({ position, content: `\n${indentation}${bridgeName}.${hook}(this);` });
        return;
      }
      if (kind !== 'ui' || member.name.text !== 'onWindowStageCreate' || member.parameters.length === 0) {
        return;
      }
      const windowStageParameter = member.parameters[0];
      if (!ts.isIdentifier(windowStageParameter.name)) {
        return;
      }
      const windowStageName = windowStageParameter.name.text;
      injections.push({
        position,
        content: `\n${indentation}${bridgeName}.observeFirstFrame(${windowStageName});`
      });
    });
    if (kind === 'ui') {
      node.members.forEach((member: any) => {
        if (!ts.isMethodDeclaration(member) || !member.body) {
          return;
        }
        const windowStageNames = collectWindowStageParameterNames(ts, sourceFile, member);
        if (windowStageNames.size > 0) {
          injections.push(...createFirstFrameRetryInjections(
            ts, sourceFile, code, member, bridgeName, windowStageNames));
        }
      });
    }
    // Application bases receive their own hooks. Do not synthesize overrides
    // in subclasses that would hide inherited application lifecycle behavior.
    if (kind === 'stage' && !hasOnCreate && !classification.applicationBase) {
      const indentation = classIndentation(code, node);
      injections.push({
        position: node.end - 1,
        content: `\n${indentation}  onCreate(): void {\n` +
          `${indentation}    ${bridgeName}.recordApplicationInit(this.context${pluginVersionArgument});\n` +
          `${indentation}  }\n`
      });
    }
    if (kind === 'ui' && !hasOnCreate && !classification.applicationBase) {
      launchTypes.needed = true;
      const indentation = classIndentation(code, node);
      const wantName = selectIdentifierName(identifiers, '__ftLaunchWant');
      const paramName = selectIdentifierName(identifiers, '__ftLaunchParam');
      injections.push({
        position: node.end - 1,
        content: `\n${indentation}  onCreate(${wantName}: ${launchTypes.want}, ` +
          `${paramName}: ${launchTypes.abilityConstant}.LaunchParam): void {\n` +
          `${indentation}    ${bridgeName}.recordFirstUIAbilityCreate(${paramName}, ${wantName}, this);\n` +
          `${indentation}  }\n`
      });
    }
    if (kind === 'ui' && !classification.applicationBase) {
      const indentation = classIndentation(code, node);
      for (const [method, hook, exists] of [
        ['onForeground', 'recordUIAbilityForeground', hasOnForeground],
        ['onBackground', 'recordUIAbilityBackground', hasOnBackground],
        ['onNewWant', 'recordUIAbilityNewWant', hasOnNewWant]
      ]) {
        if (!exists) {
          injections.push({ position: node.end - 1, content: `\n${indentation}  ${method}(): void {\n` +
            `${indentation}    ${bridgeName}.${hook}(this);\n${indentation}  }\n` });
        }
      }
    }
  });
  return { injections, hasUIAbility };
}

function applyColdLaunchInjections(code: string, injections: ColdLaunchInjection[]): string {
  const contentsByPosition = new Map<number, string[]>();
  injections.forEach((injection: ColdLaunchInjection) => {
    const contents = contentsByPosition.get(injection.position) || [];
    contents.push(injection.content);
    contentsByPosition.set(injection.position, contents);
  });
  const positions = Array.from(contentsByPosition.keys()).sort((left: number, right: number) => right - left);
  let transformedCode = code;
  positions.forEach((position: number) => {
    const content = (contentsByPosition.get(position) || []).join('');
    transformedCode = transformedCode.slice(0, position) + content + transformedCode.slice(position);
  });
  return transformedCode;
}

export function transformColdLaunchSource(ts: TypeScriptApi, id: string, code: string,
  readSource?: SourceReader): string {
  if (!isApplicationArkTsSource(id) || code.includes(COLD_LAUNCH_TRANSFORM_MARKER) ||
    !hasRuntimeDependency(ts, id, '@guancecloud/ft_sdk', readSource)) {
    return code;
  }
  const sourceFile = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const identifiers = collectIdentifierNames(ts, sourceFile);
  const bridgeName = selectIdentifierName(identifiers, '__ftColdLaunchBridge');
  const launchTypes: LaunchParameterTypes = {
    want: selectIdentifierName(identifiers, '__ftLaunchWantType'),
    abilityConstant: selectIdentifierName(identifiers, '__ftLaunchAbilityConstant'),
    needed: false
  };
  const version = getPluginVersion();
  const result = createColdLaunchInjections(ts, sourceFile, code, bridgeName, version, identifiers,
    launchTypes, readSource);
  const injections = result.injections;
  const moduleFallback = result.hasUIAbility && needsUIAbilityModuleFallback(ts, id, readSource);
  if (injections.length === 0 && !moduleFallback) {
    return code;
  }
  // Keep generated imports separate from initialization calls: ArkTS requires
  // imports before other statements, while the no-Stage fallback must still
  // run before executable application code.
  const insertionOffset = moduleFallback
    ? (code.startsWith('#!') ? code.indexOf('\n') + 1 : 0)
    : findImportInsertionOffset(ts, sourceFile);
  const firstApplicationStatement = sourceFile.statements.find((statement: any) => !ts.isImportDeclaration(statement));
  const initializationOffset = moduleFallback && firstApplicationStatement
    ? firstApplicationStatement.getStart(sourceFile) : insertionOffset;
  const installBridgeName = selectIdentifierName(identifiers, '__ftColdLaunchInstallBridge');
  const sdkName = selectIdentifierName(identifiers, '__ftColdLaunchSDK');
  const bridgeImport = `\n${COLD_LAUNCH_TRANSFORM_MARKER}\n` +
    `import { FTColdLaunchBridge as ${bridgeName}, FTConsoleLogBridge as ${installBridgeName}` +
    (version.length > 0 ? `, FTSDK as ${sdkName}` : '') + ` } from '${COLD_LAUNCH_BRIDGE_IMPORT}';\n` +
    (launchTypes.needed ? `import { Want as ${launchTypes.want}, AbilityConstant as ${launchTypes.abilityConstant} } ` +
      `from '@kit.AbilityKit';\n` : '');
  const initialization = `\n${installBridgeName}.markCompilerPluginInstalled();\n` +
    (version.length > 0 ? `${sdkName}.registerHvigorPluginVersion(${JSON.stringify(version)});\n` : '') +
    (moduleFallback ? '// Application-init fallback: UIAbility module evaluation without an AbilityStage entry.\n' +
      `${bridgeName}.recordApplicationInit(undefined, ${JSON.stringify(version)});\n` : '');
  injections.push({ position: insertionOffset, content: bridgeImport });
  injections.push({ position: initializationOffset, content: initialization });
  return applyColdLaunchInjections(code, injections);
}
