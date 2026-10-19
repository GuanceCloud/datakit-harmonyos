'use strict';

const path = require('path');
const { OhosPluginId } = require('@ohos/hvigor-ohos-plugin');

/**
 * Returns the HAP-level Hvigor plugin used to instrument console/HiLog calls,
 * cold-launch lifecycle boundaries, Session Replay page roots and Web bindings before
 * ArkTS compilation.
 *
 * This package intentionally contains build tooling only. Applications still
 * need their matching runtime HARs to receive instrumented calls. The Replay
 * transform self-disables when @guancecloud/ft_session_replay is absent.
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
