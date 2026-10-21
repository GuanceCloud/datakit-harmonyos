/**
 * Guance cold-launch compiler plugin.
 *
 * The plugin injects cold-launch boundaries into Ability lifecycle methods in
 * the compiler's in-memory source. Application files are never modified.
 */

declare const require: {
  main: {
    require(moduleName: string): any;
  };
};
declare const __dirname: string;

type TypeScriptApi = any;
type AbilityClassKind = 'stage' | 'ui' | 'other' | 'intent' | 'legacyIntent';

interface LaunchParameterTypes {
  want: string;
  abilityConstant: string;
  needed: boolean;
}

interface ColdLaunchInjection {
  position: number;
  content: string;
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

function collectAbilityBindings(ts: TypeScriptApi, sourceFile: any): Map<string, AbilityClassKind> {
  const bindings = new Map<string, AbilityClassKind>();
  sourceFile.statements.forEach((statement: any) => {
    if (!ts.isImportDeclaration(statement) || !statement.moduleSpecifier ||
      !ts.isStringLiteral(statement.moduleSpecifier) || !statement.importClause) {
      return;
    }
    const moduleName = statement.moduleSpecifier.text;
    if (!moduleName.startsWith('@ohos.app.ability.') && moduleName !== '@kit.AbilityKit') {
      return;
    }
    const importClause = statement.importClause;
    if (importClause.name) {
      const defaultKind = classifyAbilityBaseName(moduleName.substring(moduleName.lastIndexOf('.') + 1));
      if (defaultKind) {
        bindings.set(importClause.name.text, defaultKind);
      }
    }
    if (!importClause.namedBindings || !ts.isNamedImports(importClause.namedBindings)) {
      return;
    }
    importClause.namedBindings.elements.forEach((element: any) => {
      const importedName = element.propertyName ? element.propertyName.text : element.name.text;
      const kind = classifyAbilityBaseName(importedName);
      if (kind) {
        bindings.set(element.name.text, kind);
      }
    });
  });
  return bindings;
}

function classAbilityKind(ts: TypeScriptApi, classDeclaration: any,
  abilityBindings: Map<string, AbilityClassKind>): AbilityClassKind | null {
  if (!classDeclaration.heritageClauses) {
    return null;
  }
  for (const clause of classDeclaration.heritageClauses) {
    if (clause.token !== ts.SyntaxKind.ExtendsKeyword || clause.types.length === 0) {
      continue;
    }
    const expression = clause.types[0].expression;
    if (!ts.isIdentifier(expression)) {
      continue;
    }
    return abilityBindings.get(expression.text) || classifyAbilityBaseName(expression.text);
  }
  return null;
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
  launchTypes: LaunchParameterTypes): ColdLaunchInjection[] {
  const injections: ColdLaunchInjection[] = [];
  const abilityBindings = collectAbilityBindings(ts, sourceFile);
  const pluginVersionArgument = pluginVersion.length > 0 ? `, ${JSON.stringify(pluginVersion)}` : '';
  visit(ts, sourceFile, (node: any) => {
    if (!ts.isClassDeclaration(node)) {
      return;
    }
    const kind = classAbilityKind(ts, node, abilityBindings);
    if (!kind) {
      return;
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
        let content = `\n${indentation}${bridgeName}.recordApplicationInit(this.context${pluginVersionArgument});`;
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
    if (kind === 'stage' && !hasOnCreate) {
      const indentation = classIndentation(code, node);
      injections.push({
        position: node.end - 1,
        content: `\n${indentation}  onCreate(): void {\n` +
          `${indentation}    ${bridgeName}.recordApplicationInit(this.context${pluginVersionArgument});\n` +
          `${indentation}  }\n`
      });
    }
    if (kind === 'ui' && !hasOnCreate) {
      launchTypes.needed = true;
      const indentation = classIndentation(code, node);
      const wantName = selectIdentifierName(identifiers, '__ftLaunchWant');
      const paramName = selectIdentifierName(identifiers, '__ftLaunchParam');
      injections.push({
        position: node.end - 1,
        content: `\n${indentation}  onCreate(${wantName}: ${launchTypes.want}, ` +
          `${paramName}: ${launchTypes.abilityConstant}.LaunchParam): void {\n` +
          `${indentation}    ${bridgeName}.recordApplicationInit(this.context${pluginVersionArgument});\n` +
          `${indentation}    ${bridgeName}.recordFirstUIAbilityCreate(${paramName}, ${wantName}, this);\n` +
          `${indentation}  }\n`
      });
    }
    if (kind === 'ui') {
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
  return injections;
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

export function transformColdLaunchSource(ts: TypeScriptApi, id: string, code: string): string {
  if (!isApplicationArkTsSource(id) || code.includes(COLD_LAUNCH_TRANSFORM_MARKER)) {
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
  const injections = createColdLaunchInjections(ts, sourceFile, code, bridgeName, version, identifiers, launchTypes);
  if (injections.length === 0) {
    return code;
  }
  const insertionOffset = findImportInsertionOffset(ts, sourceFile);
  const bridgeImport = `\n${COLD_LAUNCH_TRANSFORM_MARKER}\n` +
    `import { FTColdLaunchBridge as ${bridgeName} } from '${COLD_LAUNCH_BRIDGE_IMPORT}';\n` +
    (launchTypes.needed ? `import { Want as ${launchTypes.want}, AbilityConstant as ${launchTypes.abilityConstant} } ` +
      `from '@kit.AbilityKit';\n` : '');
  const transformedCode = applyColdLaunchInjections(code, injections);
  return transformedCode.slice(0, insertionOffset) + bridgeImport + transformedCode.slice(insertionOffset);
}
