import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { ftConsoleLogPlugin } from '@cloudcare/hvigor-ohos-plugin';

export default {
    system: hapTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins: [ftConsoleLogPlugin()]
}
