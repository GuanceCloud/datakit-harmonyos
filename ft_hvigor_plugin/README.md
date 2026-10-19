# Guance HarmonyOS Hvigor Plugin

[![Hvigor plugin version](https://img.shields.io/badge/dynamic/json?label=plugin&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/plugin/version.json)](https://www.npmjs.com/package/@cloudcare/hvigor-ohos-plugin)

`@cloudcare/hvigor-ohos-plugin` adds automatic console/HiLog collection, cold-launch tracking, and Session Replay support for eligible ArkUI `@Entry` pages. Application files are not modified on disk.

The plugin adds build-time instrumentation but does not enable collection by itself. Enable console/HiLog collection with `FTLoggerConfig.setEnableConsoleLog(true)`. To use Session Replay, declare `@guancecloud/ft_session_replay` and initialize `FTSessionReplay` after the core SDK and RUM; the plugin then connects supported page visibility, touch, Router transition, and ArkWeb events to Replay automatically.

## Install

This is a Hvigor tool package, so declare it in the project-level `hvigor/hvigor-config.json5` rather than a module `oh-package.json5`. Replace `<latest-version>` with the latest published version that supports the features you use, including a prerelease when needed:

```json5
{
  "dependencies": {
    "@cloudcare/hvigor-ohos-plugin": "latest"
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

The plugin preserves the original console/HiLog output, reports its installed version through `sdk_pkg_info.track`, and collects cold-launch timing automatically. Do not add manual cold-launch timing calls to application code.

## Automatic Session Replay

When the HAP declares `@guancecloud/ft_session_replay`, the plugin automatically registers supported `@Entry` pages and tracks their visibility. Existing root IDs and callbacks are preserved. Session Replay collection is not enabled when the Replay package is absent.

When both `@guancecloud/ft_sdk` and `@guancecloud/ft_session_replay` are declared, the plugin automatically associates ArkUI `Web` components with their controllers so supported ArkWeb content is linked to the correct Replay page. No manual Web component ID or controller registration is required.

Replay initialization, sampling, privacy settings, and page-change notifications are documented in the `@guancecloud/ft_session_replay` README.

The plugin automatically captures page touch events without changing existing `onTouch` behavior. Touch coordinates are recorded only when `TouchPrivacy.SHOW` is configured.

Router page changes and explicit `PageTransitionEnter/Exit` slide and opacity animations are captured automatically. Existing transition callbacks are preserved; playback of default system transitions may be approximate.

## Compatibility

The plugin is verified with Node.js 18 or newer, Hvigor and `@ohos/hvigor-ohos-plugin` 6.23.5, and HarmonyOS SDK 6.0.2 (API 22). Console/HiLog and cold-launch instrumentation require `@guancecloud/ft_sdk` `0.1.17` or later. Automatic Session Replay additionally requires `@guancecloud/ft_sdk` `0.1.18` or later and `@guancecloud/ft_session_replay` `0.1.0` or later.

`@ohos/hvigor-ohos-plugin` is supplied by DevEco Studio's Hvigor runtime. Declare `@guancecloud/ft_sdk` in the application for log and cold-launch collection, and also declare `@guancecloud/ft_session_replay` when Session Replay is required.
