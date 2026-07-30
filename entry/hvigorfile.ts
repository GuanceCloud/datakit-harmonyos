import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { hapTasks, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

const consoleLogCompilerPlugin: HvigorPlugin = {
  pluginId: 'guance-console-log-compiler',
  apply(node: HvigorNode): void {
    const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
    hapContext.loadCompilePlugin('./hvigorCompile/ft-console-log-transform.ts');
  }
};

export default {
    system: hapTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins: [consoleLogCompilerPlugin]
}
