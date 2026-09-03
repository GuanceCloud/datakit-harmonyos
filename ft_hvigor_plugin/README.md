# Guance HarmonyOS Hvigor Plugin

`@guancecloud/ft-hvigor-plugin` is the build-time companion for `@guancecloud/ft_sdk`. It instruments direct `console.*` and `hilog.*` calls and injects cold-launch lifecycle tracking into a HAP module's `src/main/ets` sources. Runtime log collection remains controlled by `FTLoggerConfig.setEnableConsoleLog(true)` in `@guancecloud/ft_sdk`.

## Install

This is a Hvigor tool package, so declare it in the project-level `hvigor/hvigor-config.json5` rather than a module `oh-package.json5`:

```json5
{
  "dependencies": {
    "@guancecloud/ft-hvigor-plugin": "0.1.17-alpha01"
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

The plugin preserves the original console/HiLog output and does not modify application files on disk. It injects cold-launch application initialization into Ability `onCreate()` methods, first-UIAbility creation into `UIAbility.onCreate()`, and first-frame observation into `UIAbility.onWindowStageCreate()`. Do not add manual cold-launch timing calls to application code.
