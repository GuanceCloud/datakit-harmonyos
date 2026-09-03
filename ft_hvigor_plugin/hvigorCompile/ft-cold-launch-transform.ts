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

type TypeScriptApi = any;
type AbilityClassKind = 'stage' | 'ui' | 'other';

interface CompilePluginContext {
  share: {
    projectConfig: {
      etsLoaderPath: string;
    };
  };
}

interface SharedSourceTransformRegistry {
  originalReadFile: (fileName: string, options?: any) => any;
  buffer: any;
  transforms: Map<string, (fileName: string, code: string) => string>;
}

interface ColdLaunchInjection {
  position: number;
  content: string;
}

const COLD_LAUNCH_BRIDGE_IMPORT = '@guancecloud/ft_sdk/Index';
const COLD_LAUNCH_TRANSFORM_MARKER = '/* guance-cold-launch-transform:instrumented */';
const SOURCE_TRANSFORM_REGISTRY_KEY = '__guanceHvigorSourceTransformRegistry';
const TRANSFORM_ID = 'guance-cold-launch-transform';

let registeredFileSystem: any = null;

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

function selectBridgeName(identifiers: Set<string>): string {
  const baseName = '__ftColdLaunchBridge';
  let bridgeName = baseName;
  let suffix = 1;
  while (identifiers.has(bridgeName)) {
    bridgeName = `${baseName}${suffix}`;
    suffix++;
  }
  return bridgeName;
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
    if (!moduleName.startsWith('@ohos.app.ability/') && moduleName !== '@kit.AbilityKit') {
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

function createColdLaunchInjections(ts: TypeScriptApi, sourceFile: any, code: string,
  bridgeName: string): ColdLaunchInjection[] {
  const injections: ColdLaunchInjection[] = [];
  const abilityBindings = collectAbilityBindings(ts, sourceFile);
  visit(ts, sourceFile, (node: any) => {
    if (!ts.isClassDeclaration(node)) {
      return;
    }
    const kind = classAbilityKind(ts, node, abilityBindings);
    if (!kind) {
      return;
    }
    let hasOnCreate = false;
    node.members.forEach((member: any) => {
      if (!ts.isMethodDeclaration(member) || !member.body || !member.name || !ts.isIdentifier(member.name)) {
        return;
      }
      const indentation = methodIndentation(code, member);
      const position = member.body.getStart(sourceFile) + 1;
      if (member.name.text === 'onCreate') {
        hasOnCreate = true;
        let content = `\n${indentation}${bridgeName}.recordApplicationInit(this.context);`;
        if (kind === 'ui') {
          content += `\n${indentation}${bridgeName}.recordFirstUIAbilityCreate();`;
        }
        injections.push({ position, content });
        return;
      }
      if (kind !== 'ui' || member.name.text !== 'onWindowStageCreate' || member.parameters.length === 0) {
        return;
      }
      const windowStageParameter = member.parameters[0];
      if (!ts.isIdentifier(windowStageParameter.name)) {
        return;
      }
      injections.push({
        position,
        content: `\n${indentation}${bridgeName}.observeFirstFrame(${windowStageParameter.name.text});`
      });
    });
    if (kind === 'stage' && !hasOnCreate) {
      const indentation = classIndentation(code, node);
      injections.push({
        position: node.end - 1,
        content: `\n${indentation}  onCreate(): void {\n` +
          `${indentation}    ${bridgeName}.recordApplicationInit(this.context);\n` +
          `${indentation}  }\n`
      });
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

function rewriteSource(ts: TypeScriptApi, id: string, code: string): string {
  if (!isApplicationArkTsSource(id) || code.includes(COLD_LAUNCH_TRANSFORM_MARKER)) {
    return code;
  }
  const sourceFile = ts.createSourceFile(id, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const bridgeName = selectBridgeName(collectIdentifierNames(ts, sourceFile));
  const injections = createColdLaunchInjections(ts, sourceFile, code, bridgeName);
  if (injections.length === 0) {
    return code;
  }
  const insertionOffset = findImportInsertionOffset(ts, sourceFile);
  const bridgeImport = `\n${COLD_LAUNCH_TRANSFORM_MARKER}\n` +
    `import { FTColdLaunchBridge as ${bridgeName} } from '${COLD_LAUNCH_BRIDGE_IMPORT}';\n`;
  const transformedCode = applyColdLaunchInjections(code, injections);
  return transformedCode.slice(0, insertionOffset) + bridgeImport + transformedCode.slice(insertionOffset);
}

function installSourceReader(context: CompilePluginContext): void {
  if (registeredFileSystem !== null) {
    return;
  }
  const typeScriptPath = `${context.share.projectConfig.etsLoaderPath}/node_modules/typescript`;
  const ts = require.main.require(typeScriptPath);
  const fileSystem = require.main.require('fs');
  let registry = fileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] as SharedSourceTransformRegistry | undefined;
  if (!registry) {
    registry = {
      originalReadFile: fileSystem.readFileSync as (fileName: string, options?: any) => any,
      buffer: require.main.require('buffer'),
      transforms: new Map<string, (fileName: string, code: string) => string>()
    };
    fileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] = registry;
    fileSystem.readFileSync = (fileName: string, options?: any): any => {
      const content = registry!.originalReadFile(fileName, options);
      if (typeof fileName !== 'string' || !isApplicationArkTsSource(fileName)) {
        return content;
      }
      let transformedCode = typeof content === 'string' ? content : content.toString();
      registry!.transforms.forEach((transform: (id: string, code: string) => string) => {
        transformedCode = transform(fileName, transformedCode);
      });
      return typeof content === 'string' ? transformedCode : registry!.buffer.Buffer.from(transformedCode);
    };
  }
  registry.transforms.set(TRANSFORM_ID, (fileName: string, code: string) => rewriteSource(ts, fileName, code));
  registeredFileSystem = fileSystem;
}

function restoreSourceReader(): void {
  if (registeredFileSystem === null) {
    return;
  }
  const registry = registeredFileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] as SharedSourceTransformRegistry | undefined;
  if (registry) {
    registry.transforms.delete(TRANSFORM_ID);
    if (registry.transforms.size === 0) {
      registeredFileSystem.readFileSync = registry.originalReadFile;
      delete registeredFileSystem[SOURCE_TRANSFORM_REGISTRY_KEY];
    }
  }
  registeredFileSystem = null;
}

export default {
  name: 'guance-cold-launch-transform',
  order: 'first',
  buildStart(this: CompilePluginContext): void {
    installSourceReader(this);
  },
  buildEnd(): void {
    restoreSourceReader();
  }
};
