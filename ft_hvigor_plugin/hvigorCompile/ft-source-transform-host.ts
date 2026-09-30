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

declare const require: {
  main: {
    require(moduleName: string): any;
  };
};

type TypeScriptApi = any;
type SourceTransform = (ts: TypeScriptApi, fileName: string, code: string) => string;

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
}

const SOURCE_TRANSFORM_REGISTRY_KEY = '__guanceHvigorSourceTransformRegistry';
const SOURCE_TRANSFORMS: SourceTransformDefinition[] = [
  { id: 'guance-console-log-transform', transform: transformConsoleLogSource },
  { id: 'guance-cold-launch-transform', transform: transformColdLaunchSource },
  { id: 'guance-session-replay-root-transform', transform: transformSessionReplaySource }
];

let registeredFileSystem: any = null;

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

  SOURCE_TRANSFORMS.forEach((definition: SourceTransformDefinition) => {
    registry!.transforms.set(definition.id, (fileName: string, code: string) =>
      definition.transform(ts, fileName, code));
  });
  registeredFileSystem = fileSystem;
}

function restoreSourceReader(): void {
  if (registeredFileSystem === null) {
    return;
  }
  const registry = registeredFileSystem[SOURCE_TRANSFORM_REGISTRY_KEY] as SharedSourceTransformRegistry | undefined;
  if (registry) {
    SOURCE_TRANSFORMS.forEach((definition: SourceTransformDefinition) => registry!.transforms.delete(definition.id));
    if (registry.transforms.size === 0) {
      registeredFileSystem.readFileSync = registry.originalReadFile;
      delete registeredFileSystem[SOURCE_TRANSFORM_REGISTRY_KEY];
    }
  }
  registeredFileSystem = null;
}

export default {
  name: 'guance-source-transform-host',
  order: 'first',
  buildStart(this: CompilePluginContext): void {
    installSourceReader(this);
  },
  buildEnd(): void {
    restoreSourceReader();
  }
};
