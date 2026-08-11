# Guance HarmonyOS Hvigor Plugin

`@guancecloud/ft-hvigor-plugin` is the build-time companion for `@guancecloud/ft_sdk`. It instruments direct `console.*` and `hilog.*` calls in a HAP module's `src/main/ets` sources. Runtime collection remains controlled by `FTLoggerConfig.setEnableConsoleLog(true)` in `@guancecloud/ft_sdk`.

## Install

This is a Hvigor tool package, so declare it in the project-level `hvigor/hvigor-config.json5` rather than a module `oh-package.json5`:

```json5
{
  "dependencies": {
    "@guancecloud/ft-hvigor-plugin": "0.1.15"
  }
}
```

For local development, a filesystem dependency is also supported:

```json5
{
  "dependencies": {
    "@guancecloud/ft-hvigor-plugin": "file:../ft_hvigor_plugin"
  }
}
```

## Enable in a HAP module

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@guancecloud/ft-hvigor-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

The plugin preserves the original console/HiLog output and does not modify application files on disk.
