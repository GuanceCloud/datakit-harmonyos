/**
 * Guance compiler source-transform host.
 *
 * Hvigor reads ArkTS source while creating its type-checking program, before
 * normal Rollup transforms run. This host owns that single read hook and
 * composes feature transforms in a deterministic order. Feature modules must
 * only transform source; they must not patch the file system themselves.
 */

import {
  isApplicationArkTsSource,
  transformConsoleLogSource
} from './ft-console-log-transform';
import { transformColdLaunchSource } from './ft-cold-launch-transform';
import { transformSessionReplaySource } from './ft-session-replay-transform';
import { transformWebReplaySource } from './ft-web-replay-transform';
import { SourceDiagnosticReporter, SourceTransformDiagnostic } from './ft-transform-context';

declare const require: {
  main: {
    require(moduleName: string): any;
  };
};

type TypeScriptApi = any;
type SourceReader = (fileName: string) => string | undefined;
type SourceTransform = (ts: TypeScriptApi, fileName: string, code: string, readSource?: SourceReader,
  reportDiagnostic?: SourceDiagnosticReporter) => string;

interface CompilePluginContext {
  share: {
    projectConfig: {
      etsLoaderPath: string;
    };
  };
}

interface SourceTransformDefinition {
  id: string;
  prefix: string;
  feature: string;
  transform: SourceTransform;
}

interface SharedSourceTransformRegistry {
  originalReadFile: (fileName: string, options?: any) => any;
  buffer: any;
  transforms: Map<string, (fileName: string, code: string) => string>;
  owners: Map<object, Map<string, (fileName: string, code: string) => string>>;
  reportedDiagnostics: Set<string>;
}

const SOURCE_TRANSFORM_REGISTRY_KEY = '__guanceHvigorSourceTransformRegistry';
const SOURCE_TRANSFORMS: SourceTransformDefinition[] = [
  { id: 'guance-console-log-transform', prefix: 'GuanceLog', feature: 'console-log', transform: transformConsoleLogSource },
  { id: 'guance-cold-launch-transform', prefix: 'GuanceColdLaunch', feature: 'cold-launch', transform: transformColdLaunchSource },
  { id: 'guance-session-replay-root-transform', prefix: 'GuanceReplay', feature: 'session-replay-root', transform: transformSessionReplaySource },
  { id: 'guance-web-replay-transform', prefix: 'GuanceWebReplay', feature: 'web-replay', transform: transformWebReplaySource }
];

const registrations: Array<{ fileSystem: any; owner: object; context: CompilePluginContext }> = [];

function refreshTransforms(registry: SharedSourceTransformRegistry): void {
  registry.transforms.clear();
  registry.owners.forEach(transforms => transforms.forEach((transform, id) => registry.transforms.set(id, transform)));
}

function createDiagnosticReporter(registry: SharedSourceTransformRegistry, ts: TypeScriptApi,
  readSource: SourceReader, definition: SourceTransformDefinition):
  (diagnostic: SourceTransformDiagnostic, inputFile: string, inputCode: string, occurrence?: number) => void {
  let logger: { warn(message: string): void } | undefined;
  return (diagnostic: SourceTransformDiagnostic, inputFile: string, inputCode: string, occurrence = 0): void => {
    // Earlier transforms can insert imports or wrappers. Recheck only failed
    // pages against the on-disk source so clickable locations refer to app code.
    const originalCode = readSource(diagnostic.fileName);
    if (diagnostic.reason !== 'transform-exception' && diagnostic.fileName === inputFile &&
      originalCode !== undefined && originalCode !== inputCode) {
      const originalDiagnostics: SourceTransformDiagnostic[] = [];
      try {
        definition.transform(ts, diagnostic.fileName, originalCode, readSource, candidate => {
          if (candidate.reason === diagnostic.reason &&
            (candidate.message === diagnostic.message || candidate.reason === 'parse-error')) originalDiagnostics.push(candidate);
        });
      } catch (_) {
        // Location mapping is diagnostic-only and must not change build behavior.
      }
      diagnostic = originalDiagnostics[occurrence] ?? { ...diagnostic,
        message: `${diagnostic.message} (Location refers to in-memory transformed source.)` };
    }
    const key = `${definition.id}:${JSON.stringify(diagnostic)}`;
    if (registry.reportedDiagnostics.has(key)) return;
    registry.reportedDiagnostics.add(key);
    const message = `[GuanceBuild][${definition.prefix}] ${diagnostic.fileName}:${diagnostic.line}:${diagnostic.column}: ` +
      `feature=${definition.feature}; reason=${diagnostic.reason}; ${diagnostic.message}`;
    if (!logger) {
      try {
        logger = require.main.require('@ohos/hvigor').HvigorLogger.getLogger(definition.prefix);
      } catch (_) {
        logger = { warn: (value: string): void => console.warn(value) };
      }
    }
    logger!.warn(message);
  };
}

function installSourceReader(context: CompilePluginContext): void {
  const typeScriptPath = `${context.share.projectConfig.etsLoaderPath}/node_modules/typescript`;
  const ts = require.main.require(typeScriptPath);
  const fileSystem = require.main.require('fs');
  let registry = fileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] as SharedSourceTransformRegistry | undefined;
  if (!registry) {
    registry = {
      originalReadFile: fileSystem.readFileSync as (fileName: string, options?: any) => any,
      buffer: require.main.require('buffer'),
      transforms: new Map<string, (fileName: string, code: string) => string>(),
      owners: new Map(),
      reportedDiagnostics: new Set()
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

  const readSource: SourceReader = (fileName: string): string | undefined => {
    try {
      return registry!.originalReadFile(fileName, 'utf8').toString();
    } catch (_) {
      return undefined;
    }
  };
  // A daemon may retain a registry installed by an earlier plugin version.
  registry.reportedDiagnostics ??= new Set();
  const owner = {};
  const transforms = new Map<string, (fileName: string, code: string) => string>();
  SOURCE_TRANSFORMS.forEach((definition: SourceTransformDefinition) => {
    const reportDiagnostic = createDiagnosticReporter(registry!, ts, readSource, definition);
    transforms.set(definition.id, (fileName: string, code: string) => {
      const occurrences = new Map<string, number>();
      try {
        return definition.transform(ts, fileName, code, readSource,
          diagnostic => {
            const key = `${diagnostic.reason}:${diagnostic.message}`;
            const occurrence = occurrences.get(key) ?? 0;
            occurrences.set(key, occurrence + 1);
            reportDiagnostic(diagnostic, fileName, code, occurrence);
          });
      } catch (error) {
        try {
          reportDiagnostic({ fileName, line: 1, column: 1, reason: 'transform-exception',
            message: `Source transform failed: ${error instanceof Error ? error.message : String(error)}` }, fileName, code);
        } finally {
          // Preserve the original failure: diagnostics must never turn a broken
          // transform into a successful build or replace its exception.
          throw error;
        }
      }
    });
  });
  registry.owners.set(owner, transforms);
  refreshTransforms(registry);
  registrations.push({ fileSystem, owner, context });
}

function restoreSourceReader(context: CompilePluginContext): void {
  let index = registrations.length - 1;
  for (let candidate = registrations.length - 1; candidate >= 0; candidate--) {
    if (registrations[candidate].context === context) { index = candidate; break; }
  }
  const registration = index < 0 ? undefined : registrations.splice(index, 1)[0];
  if (!registration) return;
  const { fileSystem, owner } = registration;
  const registry = fileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] as SharedSourceTransformRegistry | undefined;
  if (registry) {
    registry.owners.delete(owner);
    refreshTransforms(registry);
    if (registry.owners.size === 0) {
      fileSystem.readFileSync = registry.originalReadFile;
      delete fileSystem[SOURCE_TRANSFORM_REGISTRY_KEY];
    }
  }
}

export default {
  name: 'guance-source-transform-host',
  order: 'first',
  buildStart(this: CompilePluginContext): void {
    installSourceReader(this);
  },
  buildEnd(this: CompilePluginContext): void {
    restoreSourceReader(this);
  }
};
