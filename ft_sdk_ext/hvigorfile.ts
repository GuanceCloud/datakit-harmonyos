import { harTasks } from '@ohos/hvigor-ohos-plugin';
import { getNode } from '@ohos/hvigor';
import { execSync } from 'child_process';

const currentNode = getNode(__filename);
currentNode.afterNodeEvaluate(() => {
    execSync('node scripts/sync_version.js', { cwd: __dirname, stdio: 'inherit' });
});

export default {
    system: harTasks,
    plugins:[]
}
