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

Configure an `AbilityStage` as the HAP module's `srcEntry` for accurate application-initialization timing. Without an `AbilityStage`, initialization timing is approximate.

## Automatic Session Replay

When the HAP declares `@guancecloud/ft_session_replay`, the plugin automatically registers supported `@Entry` pages and tracks their visibility. Existing root IDs and callbacks are preserved. Session Replay collection is not enabled when the Replay package is absent.

When both `@guancecloud/ft_sdk` and `@guancecloud/ft_session_replay` are declared, the plugin automatically associates ArkUI `Web` components with their controllers so supported ArkWeb content is linked to the correct Replay page. No manual Web component ID or controller registration is required.

Replay initialization, sampling, privacy settings, and page-change notifications are documented in the `@guancecloud/ft_session_replay` README.

The plugin automatically captures page touch events without changing existing `onTouch` behavior. Touch coordinates are recorded only when `TouchPrivacy.SHOW` is configured.

Router page changes and explicit `PageTransitionEnter/Exit` slide and opacity animations are captured automatically. Existing transition callbacks are preserved; playback of default system transitions may be approximate.

## Build diagnostics

Search for `[GuanceBuild]` in DevEco Studio's Build output or `.hvigor/outputs/build-logs/build.log` to find instrumentation warnings. Each warning includes a feature name, source path, one-based line and column, skip reason, and explanation. These build-time warnings do not depend on `FTSDKConfig.setDebug(...)`.

| Filter | Feature | Feature-specific skip reasons |
| --- | --- | --- |
| `[GuanceLog]` | Console/HiLog collection | `unsupported-log-call`: optional calls, missing HiLog arguments, or an unusable compiler source range |
| `[GuanceColdLaunch]` | AbilityStage/UIAbility/InsightIntent lifecycle and first-frame hooks | `unresolved-ability-base`: a declared module entry's platform base cannot be resolved; `unsupported-lifecycle`: no instrumentable method/function body; `unsupported-lifecycle-parameters`: unsupported launch or WindowStage parameters |
| `[GuanceReplay]` | Session Replay `@Entry` page root registration | `unsupported-parser`, `missing-build`, `unsupported-root` |
| `[GuanceWebReplay]` | ArkWeb controller binding | `unsupported-web-call`: a `Web` call is optional, has a spread argument, or does not have exactly one options argument |

All four features report `parse-error` when a relevant source file cannot be parsed, including the first compiler diagnostic and the number of additional parse errors. Unexpected transform exceptions report `transform-exception` and retain the original build failure. When an exception has no source position, its location is the file's `1:1`.

```text
[GuanceBuild][GuanceReplay] /project/entry/src/main/ets/pages/Example.ets:12:19: feature=session-replay-root; reason=parse-error; TS1109: Expression expected.
[GuanceBuild][GuanceColdLaunch] /project/entry/src/main/ets/entryability/EntryAbility.ets:18:3: feature=cold-launch; reason=unsupported-lifecycle-parameters; onWindowStageCreate requires a named WindowStage parameter for automatic first-frame observation.
```

Warnings do not fail the build by themselves. Unsupported calls/hooks are left unchanged while other supported hooks can still be applied; a parse failure skips that feature's transformation for the file. Application files are never modified on disk. Locations refer to the original source when available; a warning explicitly identifies any location that refers to transformed source instead. Identical warnings are deduplicated per feature and source location within the active compilation.

Modules without the required runtime dependencies, files with no matching calls/classes/pages, and locally shadowed names are skipped without warnings. The plugin does not infer that an arbitrary unresolved business class is an Ability. After updating the plugin, rebuild the application so the source transforms execute again. Existing `ArkTS:WARN` compiler diagnostics remain independent of these plugin warnings.

## Compatibility

The plugin is verified with Node.js 18 or newer, Hvigor and `@ohos/hvigor-ohos-plugin` 6.23.5, and HarmonyOS SDK 6.0.2 (API 22). Console/HiLog and cold-launch instrumentation require `@guancecloud/ft_sdk` `0.1.17` or later. Automatic Session Replay additionally requires `@guancecloud/ft_sdk` `0.1.18` or later and `@guancecloud/ft_session_replay` `0.1.0` or later.

`@ohos/hvigor-ohos-plugin` is supplied by DevEco Studio's Hvigor runtime.

Each module that needs automatic collection must declare these SDK packages under `dependencies` in its own `oh-package.json5`:

- `@guancecloud/ft_sdk`: required for console/HiLog and cold-launch collection.
- `@guancecloud/ft_session_replay`: additionally required for Session Replay.

The plugin checks SDK dependencies in the `oh-package.json5` of the module that contains each source file (HAP, HAR or HSP). Declaring an SDK only in the project-root `oh-package.json5`, another module, or `devDependencies` does not enable automatic collection for that source file.

Optional logging calls such as `console?.info(...)` and `hilog.info?.(...)` are not automatically collected and produce `unsupported-log-call` warnings.
