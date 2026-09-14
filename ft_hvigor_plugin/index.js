'use strict';

const path = require('path');
const { OhosPluginId } = require('@ohos/hvigor-ohos-plugin');

/**
 * Returns the HAP-level Hvigor plugin used to instrument console/HiLog calls
 * and cold-launch lifecycle boundaries before ArkTS compilation.
 *
 * This package intentionally contains build tooling only. Applications still
 * need @guancecloud/ft_sdk at runtime to receive the instrumented log calls.
 */
function ftConsoleLogPlugin() {
  return {
    pluginId: 'guance-console-log-compiler',
    apply(node) {
      const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN);
      const sourceTransformHostPath = path.join(__dirname, 'hvigorCompile', 'ft-source-transform-host.ts');
      hapContext.loadCompilePlugin(sourceTransformHostPath);
    }
  };
}

module.exports = {
  ftConsoleLogPlugin
};
