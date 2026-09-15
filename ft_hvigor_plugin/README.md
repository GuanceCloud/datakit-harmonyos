# Guance HarmonyOS Hvigor Plugin

[![Hvigor plugin version](https://img.shields.io/badge/dynamic/json?label=plugin&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/plugin/version.json)](https://www.npmjs.com/package/@cloudcare/hvigor-ohos-plugin)

`@cloudcare/hvigor-ohos-plugin` is the build-time companion for `@guancecloud/ft_sdk`. It instruments direct `console.*` and `hilog.*` calls and injects cold-launch lifecycle tracking into a HAP module's `src/main/ets` sources. Runtime log collection remains controlled by `FTLoggerConfig.setEnableConsoleLog(true)` in `@guancecloud/ft_sdk`.

## Install

This is a Hvigor tool package, so declare it in the project-level `hvigor/hvigor-config.json5` rather than a module `oh-package.json5`:

```json5
{
  "dependencies": {
    "@cloudcare/hvigor-ohos-plugin": "^0.1.1"
  }
}
```

## Enable in a HAP module

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@cloudcare/hvigor-ohos-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

The plugin preserves the original console/HiLog output and does not modify application files on disk. It injects its installed package version into the SDK's `sdk_pkg_info.track` tag at build time, so rebuilding after a plugin upgrade reports the matching version. It injects cold-launch application initialization into Ability `onCreate()` methods, first-UIAbility creation into `UIAbility.onCreate()`, and first-frame observation into `UIAbility.onWindowStageCreate()`. Do not add manual cold-launch timing calls to application code.

## Compatibility

The plugin is verified with Node.js 18 or newer, Hvigor and `@ohos/hvigor-ohos-plugin` 6.23.5, and HarmonyOS SDK 6.0.2 (API 22). It supports `@guancecloud/ft_sdk` `0.1.17` and later releases.

`@ohos/hvigor-ohos-plugin` is supplied by DevEco Studio's Hvigor runtime. `@guancecloud/ft_sdk` must still be declared as the application's runtime HAR dependency because the generated imports target that package.
