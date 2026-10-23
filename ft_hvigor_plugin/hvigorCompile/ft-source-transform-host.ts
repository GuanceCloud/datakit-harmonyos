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

declare const require: {
  main: {
    require(moduleName: string): any;
  };
};

type TypeScriptApi = any;
type SourceReader = (fileName: string) => string | undefined;
type SourceTransform = (ts: TypeScriptApi, fileName: string, code: string, readSource?: SourceReader) => string;

interface CompilePluginContext {
  share: {
    projectConfig: {
      etsLoaderPath: string;
    };
  };
}

interface SourceTransformDefinition {
  id: string;
  transform: SourceTransform;
}

interface SharedSourceTransformRegistry {
  originalReadFile: (fileName: string, options?: any) => any;
  buffer: any;
  transforms: Map<string, (fileName: string, code: string) => string>;
  owners: Map<object, Map<string, (fileName: string, code: string) => string>>;
}

const SOURCE_TRANSFORM_REGISTRY_KEY = '__guanceHvigorSourceTransformRegistry';
const SOURCE_TRANSFORMS: SourceTransformDefinition[] = [
  { id: 'guance-console-log-transform', transform: transformConsoleLogSource },
  { id: 'guance-cold-launch-transform', transform: transformColdLaunchSource },
  { id: 'guance-session-replay-root-transform', transform: transformSessionReplaySource },
  { id: 'guance-web-replay-transform', transform: transformWebReplaySource }
];

const registrations: Array<{ fileSystem: any; owner: object; context: CompilePluginContext }> = [];

function refreshTransforms(registry: SharedSourceTransformRegistry): void {
  registry.transforms.clear();
  registry.owners.forEach(transforms => transforms.forEach((transform, id) => registry.transforms.set(id, transform)));
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
      owners: new Map()
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
  const owner = {};
  const transforms = new Map<string, (fileName: string, code: string) => string>();
  SOURCE_TRANSFORMS.forEach((definition: SourceTransformDefinition) => {
    transforms.set(definition.id, (fileName: string, code: string) =>
      definition.transform(ts, fileName, code, readSource));
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
