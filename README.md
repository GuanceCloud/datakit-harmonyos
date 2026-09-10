# GuanceCloud SDK HarmonyOS

![](https://img.shields.io/badge/dynamic/json?label=agent&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/agent/version.json&link=https://github.com/GuanceCloud/datakit-harmonyos) ![](https://img.shields.io/badge/dynamic/json?label=agent&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/native/version.json&link=https://github.com/GuanceCloud/datakit-harmonyos) ![](https://img.shields.io/badge/dynamic/json?label=min.sdk&color=green&query=$.mini_sdk&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/agent/info.json&link=https://github.com/GuanceCloud/datakit-harmonyos)

## Introduction

GuanceCloud Application Monitoring can collect metric data from HarmonyOS applications and analyze application performance, user experience, logs, and crash information in a visualized way.

## Example

This repository contains the HarmonyOS SDK source modules, including `@guancecloud/ft_sdk`, `@guancecloud/ft_sdk_ext`, and `@guancecloud/ft_native`.

## Installation

Choose the package that matches your scenario:

- `@guancecloud/ft_sdk`: core SDK for RUM, logging, tracing, and lifecycle monitoring
- `@guancecloud/ft_sdk_ext`: extension package for newer compiler/platform capabilities, built on top of `@guancecloud/ft_sdk`
- `@guancecloud/ft_native`: native crash collection module

Install with `ohpm install`:

```bash
ohpm install @guancecloud/ft_sdk
ohpm install @guancecloud/ft_sdk_ext
ohpm install @guancecloud/ft_native
```

Or use the short form `ohpm i`:

```bash
ohpm i @guancecloud/ft_sdk
ohpm i @guancecloud/ft_sdk_ext
ohpm i @guancecloud/ft_native
```

Then declare the dependency in your app `oh-package.json5` if needed:

```json5
{
  "dependencies": {
    "@guancecloud/ft_sdk": "latest",
    "@guancecloud/ft_sdk_ext": "latest",
    "@guancecloud/ft_native": "latest"
  }
}
```

`@guancecloud/ft_sdk_ext` depends on `@guancecloud/ft_sdk`. If you only need the core monitoring capability, install `@guancecloud/ft_sdk` alone.
`@guancecloud/ft_native` is optional and only needed when you want native crash monitoring. Once it is packaged with the app, `ft_sdk` initializes the native crash module internally when crash tracking is enabled.

For cold-launch phase timing, enable the Guance Hvigor compiler plugin. It
injects the required Ability lifecycle and first-frame hooks during the build,
so the host application does not add timing calls. See the module
[cold-launch timing guide](ft_sdk/README.md#cold-launch-timing).

## Bytecode HAR Integration

SDK HARs are configured to build as bytecode HARs. An application that depends on any of these packages must enable normalized OHMUrl in its root `build-profile.json5`:

```json5
{
  "app": {
    "products": [
      {
        "name": "default",
        "buildOption": {
          "strictMode": {
            "useNormalizedOHMUrl": true
          }
        }
      }
    ]
  }
}
```

Bytecode HAR requires HarmonyOS API 12 or later. Keep the dependency aliases identical to the package names in `oh-package.json5`, and use only APIs exported from each package `Index.ets`.

## Release Obfuscation

Release builds enable ArkGuard obfuscation for all SDK HAR modules. The public APIs exported through `Index.ets`, plus the native crash Node-API bridge, are retained so the obfuscated HAR remains compatible with integrating applications. Do not remove the module `consumer-rules.txt` files: Hvigor packages them as `obfuscation.txt` and applies the required keep rules when an integrating application also enables obfuscation.

## Quick Start

For most HarmonyOS applications, start with `@guancecloud/ft_sdk` and initialize it in `UIAbility.onCreate`:

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import type Want from '@ohos.app.ability.Want'
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  EnvType,
  SDKLogLevel,
  TraceType
} from '@guancecloud/ft_sdk/Index'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
      .setEnv(EnvType.PROD)
      .setServiceName('your_service_name')

    FTSDK.install(sdkConfig, this.context)

    const rumConfig = new FTRUMConfig()
      .setRumAppId('YOUR_RUM_APP_ID')
      .setEnableTraceUserView(true)
      .setEnableTraceUserAction(true)
      .setEnableTraceUserResource(true)
      .setEnableTrackAppCrash(true)

    const loggerConfig = new FTLoggerConfig().setEnableCustomLog(true)
    const traceConfig = new FTTraceConfig().setEnableAutoTrace(true).setTraceType(TraceType.DDTRACE)

    FTSDK.installRUMConfig(rumConfig)
    FTSDK.installLogConfig(loggerConfig)
    FTSDK.installTraceConfig(traceConfig)
  }
}
```

## Automatic Console and HiLog Collection

HarmonyOS collects application `console.*` and `hilog.*` calls through the standalone Guance Hvigor compiler plugin. This follows Android's `setEnableConsoleLog` model: the switch enables collection, while the build plugin supplies the instrumentation. There is no runtime monkey-patching fallback.

Install `@guancecloud/ft-hvigor-plugin` in the project-level `hvigor/hvigor-config.json5` (this is a Hvigor tool dependency, not an `oh-package.json5` runtime dependency), then register it in the application HAP module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@guancecloud/ft-hvigor-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

Then install the log configuration:

```ts
const loggerConfig = new FTLoggerConfig()
  .setEnableCustomLog(true) // Controls manual FTLogger reporting only.
  .setEnableConsoleLog(true, '[business]') // Controls auto-collected console/HiLog only.

FTSDK.installLogConfig(loggerConfig)
```

The plugin rewrites direct calls in the application's `src/main/ets` sources without changing files on disk. It supports `console.log/debug/info/warn/error/trace` and `hilog.debug/info/warn/error/fatal` imported from `@ohos.hilog` or `@kit.PerformanceAnalysisKit`. Original console/HiLog output is retained. The optional prefix filters automatic collection only.

| Setup | `console` / `hilog` automatic collection | Manual `FTLogger` reporting |
| --- | --- | --- |
| Plugin installed + `setEnableConsoleLog(true)` | Enabled | Controlled by `setEnableCustomLog(...)` |
| Plugin installed + `setEnableConsoleLog(false)` | Disabled | Controlled by `setEnableCustomLog(...)` |
| Plugin absent | Disabled; the SDK emits one diagnostic after log configuration | Controlled by `setEnableCustomLog(...)` |

Without the plugin, the SDK deliberately does not pretend to collect console logs. Use `FTLogger` for manual reporting, or add the plugin when automatic coverage is required. See the [core SDK guide](ft_sdk/README.md#automatic-console-and-hilog-collection) for verification steps and HiLog privacy behavior.

## Automatic View Filtering

When automatic View tracking is enabled, Router pages and `Navigation`
destinations can be renamed or filtered with one handler. Choose whether it
applies to `ROUTER`, `NAVIGATION`, or `ALL`. Return a `HandlerView` to collect
the automatic View; return `null` to skip it. The handler receives a
source-specific context: Router Views expose the original `RouterPageInfo`,
and Navigation Views expose the original `NavDestinationSwitchInfo`. The
context includes the final normalized route segment as `viewName`. With no
handler set, the SDK keeps the default behavior and reports that final segment.

```ts
import {
  FTRUMConfig,
  FTViewTrackingContext,
  FTViewTrackingHandler,
  FTViewTrackingType,
  HandlerView
} from '@guancecloud/ft_sdk/Index'

const automaticViewHandler: FTViewTrackingHandler = {
  resolveHandlerView: (context: FTViewTrackingContext): HandlerView | null => {
    if (context.viewName === 'LoginPage') {
      return null // Do not collect this automatic View
    }
    if (context.trackingType === FTViewTrackingType.ROUTER &&
      context.routerPageInfo.path.startsWith('pages/internal/')) {
      return null // Filter directly by RouterPageInfo
    }
    if (context.trackingType === FTViewTrackingType.NAVIGATION) {
      const navigationInfo = context.navigationInfo
      const from = navigationInfo.from
      if (navigationInfo.operation === NavigationOperation.POP ||
        (typeof from !== 'string' && from.name === 'CheckoutPage')) {
        return null // Filter by operation or NavDestinationSwitchInfo.from
      }
    }
    return new HandlerView(`View_${context.viewName}`)
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserView(true)
  .setViewTrackingHandler(automaticViewHandler, FTViewTrackingType.ALL)
```

`originalViewName` preserves the name supplied by ArkUI, while `viewName` is
the normalized final route segment. When `trackingType` is `ROUTER`, use
`routerPageInfo` to filter by `name`, `path`, `index`, or `state`. When it is
`NAVIGATION`, use `navigationInfo` to filter by `from`, `to`, `operation`, or
the destination `param`, `navigationId`, and `navDestinationId`.

## Automatic Action Filtering

When automatic Action tracking is enabled, configure
`FTRUMConfig.setActionTrackingHandler(...)` to filter click Actions.
The handler is called for each automatically tracked user operation. Return
`null` to skip collection; return `undefined` to continue through the SDK's
original automatic Action collection path, including name, properties,
position, and View association.

```ts
import {
  ActionEventWrapper,
  FTActionTrackingHandler,
  FTRUMConfig
} from '@guancecloud/ft_sdk/Index'

const actionHandler: FTActionTrackingHandler = {
  resolveHandlerAction: (event: ActionEventWrapper): null | undefined => {
    // Do not collect clicks from this component.
    if (event.getSource()?.getId() === 'ignore_action_view') {
      return null
    }

    // Continue through the original automatic Action collection path.
    return undefined
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserAction(true)
  .setActionTrackingHandler(actionHandler)
```

## SDK Debug Logs

Enable internal SDK logs in debug builds, then filter HiLog/LogCat with `[FT-SDK]`:

```ts
const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDebug(true)
  .setSdkLogLevel(SDKLogLevel.D)
```

`V` and `D` show all current SDK diagnostics; `I`, `W`, and `E` progressively reduce output to those levels and above. Debug logs include the masked upload endpoint, RUM/Log/Trace configuration summaries, Resource lifecycle events, and upload results. Never enable these logs in a production build unless troubleshooting is required.

## Update the Reporting Endpoint at Runtime

After `FTSDK.install(...)`, update the active reporting endpoint without recreating the SDK:

```ts
FTSDK.setDatakitUrl('https://datakit.example.com')
FTSDK.setDatawayUrl('https://dataway.example.com', 'YOUR_CLIENT_TOKEN')
```

DataKit and Dataway modes are mutually exclusive. The endpoint must be a complete `http://` or `https://` URL; Dataway also requires a client token. The value is kept in memory only. Automatic uploads resume after a valid endpoint is set, and `FTSDK.flushSyncData()` can request an immediate upload.

## Remote Configuration and Runtime Endpoint

Enable remote configuration with `FTSDKConfig.setRemoteConfiguration(true)`. Once RUM is installed, the SDK requests `v1/env_variable` with the RUM app ID, persists a valid response, and applies supported updates. The default refresh interval is 12 hours.

```ts
const sdkConfig = FTSDKConfig.builder()
  .setRemoteConfiguration(true)

FTSDK.install(sdkConfig, this.context)
FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('YOUR_RUM_APP_ID'))

// It is also valid to supply the upload endpoint later.
FTSDK.setDatakitUrl('https://datakit.example.com')
// Or: FTSDK.setDatawayUrl('https://dataway.example.com', 'CLIENT_TOKEN')
```

Call `FTSDK.updateRemoteConfig()` for a manual interval-respecting refresh. `FTSDK.setEnableAccessDeviceID(...)` updates the runtime `device_uuid` selection between a system identifier (when available) and the SDK privacy UUID.

## Local Data Filtering

The core SDK supports Android-compatible local filtering for logging and RUM data. Filters are enabled by default and discard matching points after `LineDataModifier` and before local-cache persistence.

```ts
const filters = new Map<string, Array<string>>()
filters.set('logging', ["{ message match ['.*password.*'] }"])
filters.set('rum', ["{ source in [resource] and resource_status in ['404', '503'] }"])

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataFilters(filters)
// .setEnableDataFilter(false) disables filtering while retaining these rules.
```

Rules use the `logging` and `rum` categories and support `in`, `not in`, `match`, `not match`, `and`, and `or`. See the `ft_sdk` README for rule-field semantics and full details.
## Data Modification and Masking

`FTSDKConfig.setDataModifier(...)` masks or replaces a value by key for every raw Log, native RUM, and WebView RUM tag/field. Return `null` to leave a value unchanged. `setLineDataModifier(...)` receives the merged record and returns a patch for existing keys when a rule needs to inspect multiple values.

Configure both callbacks before `FTSDK.install(...)`. The core-package guide includes the full ArkTS example and exact patch semantics: [Data Modification and Masking](ft_sdk/README.md#data-modification-and-masking).

## Package Guide

- `@guancecloud/ft_sdk`: standard SDK initialization, RUM, logging, tracing, and common network helpers
- `@guancecloud/ft_sdk_ext`: add when you need HarmonyOS `HttpInterceptor` chain integration
- `@guancecloud/ft_native`: add when you need native crash monitoring through the implicit `libftnativecrash.so` integration

The core SDK also provides shared cache-size governance and an opt-in SQLite-to-FileStore migration path; see [Cache Governance and FileStore Migration](ft_sdk/README.md#cache-governance-and-filestore-migration).

## Native Crash Monitoring

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

Add `@guancecloud/ft_native` to the application dependencies so `libftnativecrash.so` is packaged with the app. When crash tracking is enabled, `ft_sdk` initializes the native crash module internally.

## Demo Runtime Configuration

The Demo saves startup configuration in Preferences. Values are resolved in this
order: explicit startup argument, saved value, then default. Omitted arguments
reuse saved values; an explicit empty string clears a string setting. Automatic
upload and sampling settings are also restored on the next launch.

An explicit DataKit URL selects DataKit and clears the saved Dataway URL and
token. An explicit Dataway URL selects Dataway and can reuse the saved token.
Do not supply two non-empty endpoints together. Startup logs identify value
sources and mask the token.

| Startup argument | Default when not saved / behavior |
| --- | --- |
| `datakitUrl` | Empty; DataKit upload endpoint |
| `datawayUrl`, `clientToken` | Empty; Dataway upload endpoint and token |
| `appId` | Empty; RUM application ID |
| `webViewUrl`, `traceUrl` | Empty; Demo WebView and trace request targets |
| `resourceTestUrl` | Empty; each Demo GET button uses its own fallback target |
| `autoSync` | `true`; persisted automatic upload switch |
| `logSamplingRate`, `rumSamplingRate`, `errorSamplingRate`, `traceSamplingRate` | `1`; persisted rates from `0` to `1` |
| `localDataFilterEnabled` | `true`; persisted local filtering switch |
| `localDataFilterLogRule`, `localDataFilterRumRule` | Empty; persisted filter expressions |
| `remoteConfigTestEnabled` | `false`; Demo remote-configuration debugging switch |
| `networkRouteTestEnabled`, `networkRouteTestMode`, `networkRouteTestHost` | `false`, `proxy`, empty; shared network route test configuration |

Boolean startup arguments accept `true`/`false`, `1`/`0`, or `on`/`off`.
Invalid flags and sampling rates report their parameter name before saving.

## Release Checklist

- Ensure package names, versions, descriptions, author, and license in each module `oh-package.json5` are correct before `ohpm publish`.
- Keep the published version compliant with semantic versioning.
- Verify dependency versions stay aligned. In particular, `@guancecloud/ft_sdk_ext` should depend on the same `@guancecloud/ft_sdk` version that is being released.
- Confirm the public documentation page is ready and matches the published package behavior.
- Clean local build artifacts such as `build/` and `oh_modules/` from the release package or release branch if they are not meant to be shipped.
- Recheck compatibility claims against the demo project settings before release.

## Documentation

[Documentation Center](https://docs.guance.com/real-user-monitoring/harmonyos/app-access/)
