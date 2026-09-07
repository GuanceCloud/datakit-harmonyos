# ft_sdk

Guance HarmonyOS core SDK for application monitoring, analytics, logging, and tracing.

## Introduction

`@guancecloud/ft_sdk` is the core Guance HarmonyOS SDK. It provides RUM, logging, tracing, common network tracking helpers, and related monitoring capabilities for HarmonyOS applications.
Native crash monitoring is optional and lives in `@guancecloud/ft_native`.

## Features

- Real User Monitoring (RUM)
- Log collection
- Distributed tracing
- Performance and lifecycle monitoring
- HarmonyOS application integration

## Package

- Name: `@guancecloud/ft_sdk`
- License: `Apache-2.0`

## Installation

```bash
ohpm install @guancecloud/ft_sdk
```

Short form:

```bash
ohpm i @guancecloud/ft_sdk
```

## Import

```ts
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceManager,
  FTTraceRequestContext,
  EnvType,
  SDKLogLevel,
  TraceType
} from '@guancecloud/ft_sdk/Index'
```

## Quick Start

Initialize the SDK in `UIAbility.onCreate` as early as possible:

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import type Want from '@ohos.app.ability.Want'
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceManager,
  FTTraceRequestContext,
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

### Network Resource status

Native network auto-tracking reports `resource_status=0` when no HTTP response is received (for example, timeout or connection failure). The final Resource and its associated Network Error retain this value. Zero has no `resource_status_group`; real HTTP responses retain their status and existing `2xx`/`4xx`/`5xx` grouping. The full URL path remains in `resource_url_path`; only `resource_url_path_group` normalizes numeric segments.

Following the existing SDK contract, a collected Resource generates one linked Network Error for HTTP status >=400, or for status 0 with a non-empty error stack. A manually supplied status 0 without an error stack does not alone create an Error. Auto-tracking supplies the failure message and stack (or the available platform failure description), and links both records through `resource_id`.

## Hvigor Compiler Plugin

The Guance Hvigor compiler plugin provides automatic console/HiLog collection and cold-launch lifecycle tracking. `FTLoggerConfig.setEnableConsoleLog(...)` controls automatic application-console collection; `setEnableCustomLog(...)` remains independent and controls only manual `FTLogger` calls.

### Install the Hvigor Plugin

Install `@guancecloud/ft-hvigor-plugin` in the project-level `hvigor/hvigor-config.json5`. This build-time tool package is separate from the `@guancecloud/ft_sdk` runtime HAR. Register it in the HAP module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@guancecloud/ft-hvigor-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

The plugin instruments application code in `src/main/ets` without rewriting source files on disk or SDK dependencies. It supports:

- `console.log`, `debug`, `info`, `warn`, `error`, and `trace`
- `hilog.debug`, `info`, `warn`, `error`, and `fatal` when `hilog` is imported from `@ohos.hilog` or `@kit.PerformanceAnalysisKit`
- Cold-launch boundaries in `AbilityStage`, `UIAbility`, and other Ability `onCreate()` methods; `UIAbility.onWindowStageCreate()` also receives automatic first-frame observation.

Use the same source-release version as the `@guancecloud/ft_sdk` package. The transformed call evaluates its arguments once, queues the Guance log, and keeps the original console/HiLog output.

### Configure and Verify

```ts
const loggerConfig = new FTLoggerConfig()
  .setEnableCustomLog(true) // Manual FTLogger only.
  .setEnableConsoleLog(true, '[business]') // Automatic console/HiLog only.

FTSDK.installLogConfig(loggerConfig)

console.info('[business] console example')
hilog.info(0x0000, 'Demo', '%{public}s', '[business] HiLog example')
```

Run a clean HAP build, install it on a device, and trigger both calls. Their original output must still appear in DevEco/HiLog. After upload, each generated log should have `log_source=console` or `log_source=hilog`; HiLog logs also have `domain` and `tag`. HiLog privacy is preserved: values without `%{public}` are recorded as `<private>`.

To verify the switches, repeat with `setEnableConsoleLog(false)` and confirm that no new automatic logs are uploaded. Keep `setEnableCustomLog(true)` and send an `FTLogger` log: it must still upload. Conversely, disabling `setEnableCustomLog(false)` must not affect auto-collected console/HiLog data while `setEnableConsoleLog(true)` is enabled.

If the compiler plugin is absent, automatic console/HiLog collection is unavailable even when `setEnableConsoleLog(true)` is set. The SDK emits one diagnostic when its log configuration is installed; this is intentional parity with Android's plugin prerequisite. There is no runtime interception fallback. Use `FTLogger` for manual logs, or install the plugin for automatic collection.
## Cold Launch Timing

Cold-launch durations use the monotonic
`systemDateTime.getUptime(TimeType.STARTUP, true)` clock. The SDK retains the
measured boundaries until RUM Action collection is ready, then emits exactly
one `launch_cold` Action after the first UI frame. Its `duration` spans from
the process-start boundary to the first rendered frame;
the Action timestamp remains an epoch timestamp for compatibility with the
existing data pipeline.

Enable the Guance Hvigor compiler plugin described above and keep the
`AbilityStage` file as the module `srcEntry`. The plugin injects application
initialization, first-UIAbility creation, and first-frame observation at build
time; do not call `FTSDK.recordAppApplicationInit(...)`,
`recordAppFirstUIAbilityCreate(...)`, or `recordAppFirstFrame(...)` from host
application code. API 22 and later records the real first draw. On earlier API
levels, the first-frame phase is omitted rather than approximated.

Foreground launches emit these Action Fields only when each pair of boundaries
is present and strictly increasing:

- `app_launch_type = foreground`
- `app_pre_application_init_time`: process start to application initialization
- `app_application_init_time`: application initialization to first UIAbility creation
- `app_first_frame_init_time`: first UIAbility creation to first rendered frame

At application initialization, the core first obtains and preserves the current process state from
`ApplicationContext.getRunningProcessInformation()` (foreground/active or
background). It does not depend only on `applicationStateChange`; that event
continues to correct foreground/background races. A generation-reset,
two-consecutive-turn lifecycle quiescence barrier replaces the former single
`setTimeout(0)`: first UIAbility creation, application-state changes, and
WindowStage SHOWN/ACTIVE reset the barrier before a no-UI launch can settle.
No `RUNNING_STATE_OBSERVER` appManager listener or permission is used.

For a background-originated launch, the initial snapshot must
be `background` and the quiescence barrier must complete without a UIAbility,
foreground state, or shown/active Window. The SDK records that classification
but does not emit a no-UI `launch_cold` Action. If a UIAbility is later created,
the first frame emits one Action with `app_launch_type = background` and a
duration from the process-start boundary to the first frame; a process that remains background-only emits no launch
Action. Hot-start Actions do not carry these cold-launch fields.

RUM must be initialized before the first UI frame. For AppService/push entries,
initialize it from AbilityStage or the entry itself when those processes also
need RUM data; a background-only process does not emit `launch_cold` in this
case.

The repository Demo accepts the non-persistent launch parameter
`coldStartDelayMs` (capped at 30,000 ms). For example, use `5000` on a cold
launch to delay `loadContent()` by five seconds; this safely produces a long
first-UIAbility-creation-to-first-frame/`launch_cold.duration` scenario without changing normal launches.

## Automatic View Filtering

When automatic View tracking is enabled, Router pages and `Navigation`
destinations can be independently renamed or filtered. Return a `HandlerView`
to collect the automatic View; return `null` to skip it. With no handler set,
the SDK keeps the default behavior and reports the final route segment.

```ts
import {
  FTRUMConfig,
  FTViewRouterTrackingHandler,
  FTViewNavigationTrackingHandler,
  HandlerView
} from '@guancecloud/ft_sdk/Index'

const routerHandler: FTViewRouterTrackingHandler = {
  resolveHandlerView: (routeName: string): HandlerView | null => {
    if (routeName === 'LoginPage') {
      return null // Do not collect this Router page
    }
    return new HandlerView(`Router_${routeName}`)
  }
}

const navigationHandler: FTViewNavigationTrackingHandler = {
  resolveHandlerView: (destinationName: string): HandlerView | null => {
    return destinationName === 'OrderDetail'
      ? new HandlerView('Order Detail')
      : null
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserView(true)
  .setViewRouterTrackingHandler(routerHandler)
  .setViewNavigationTrackingHandler(navigationHandler)
```

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

Enable internal SDK diagnostics in debug builds, then filter HiLog/LogCat with `[FT-SDK]`:

```ts
const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDebug(true)
  .setSdkLogLevel(SDKLogLevel.D)
```

`V` and `D` output all SDK diagnostics. `I`, `W`, and `E` only output the selected severity and higher. The diagnostics cover the masked endpoint, RUM/Log/Trace configuration, Resource lifecycle, and data upload outcomes.

## Remote Configuration and Runtime Endpoint

Remote configuration is opt-in. After RUM is installed, the SDK fetches `v1/env_variable` using the RUM app ID, caches a valid response, and applies the Android-compatible fields on the next initialization or, where supported, immediately. The default refresh interval is 12 hours.

```ts
const sdkConfig = FTSDKConfig.builder()
  .setRemoteConfiguration(true)
  .setRemoteConfigMiniUpdateInterval(43_200)

FTSDK.install(sdkConfig, this.context)
FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('YOUR_RUM_APP_ID'))

// Upload and remote-config fetching can be enabled after SDK initialization.
FTSDK.setDatakitUrl('https://datakit.example.com')
// Or: FTSDK.setDatawayUrl('https://dataway.example.com', 'CLIENT_TOKEN')
```

Use `FTSDK.updateRemoteConfig()` for an interval-respecting manual refresh, or pass `0` as the first argument to the overload to force a fetch. Switching to a valid runtime endpoint also refreshes remote configuration immediately; an in-flight response from the old endpoint is ignored. `FTSDK.setEnableAccessDeviceID(...)` can switch the runtime `device_uuid` between the system identifier (when available) and the SDK's privacy UUID.

## Update the Reporting Endpoint at Runtime

After `FTSDK.install(...)`, switch the active reporting endpoint without recreating the SDK:

```ts
// DataKit mode
FTSDK.setDatakitUrl('https://datakit.example.com')

// Dataway mode
FTSDK.setDatawayUrl('https://dataway.example.com', 'YOUR_CLIENT_TOKEN')
```

The two modes are mutually exclusive: setting a DataKit URL clears the Dataway URL and token; setting a Dataway URL clears the DataKit URL. Use a complete `http://` or `https://` URL. The new value is kept in memory only, so configure it again after an app restart if needed. Automatic upload resumes when the endpoint is valid; call `FTSDK.flushSyncData()` when you need to request an immediate upload.

## Data Filtering

Local data filtering is enabled by default. Configure rules before `FTSDK.install(...)`; a matching RUM or logging point is discarded after `LineDataModifier` runs and before the point enters the local cache.

```ts
const dataFilters = new Map<string, Array<string>>()
dataFilters.set('logging', [
  "{ source in ['df_rum_harmonyos_log'] and message match ['.*password.*'] }"
])
dataFilters.set('rum', [
  "{ source in [resource] and resource_status in ['404', '503'] }"
])

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataFilters(dataFilters)
```

- Supported categories are `logging` and `rum` (case-insensitive); other categories are ignored.
- A rule is enclosed in `{}`. Supported operators are `=`, `!=`, `in`, `not in`, `match`, and `not match`, combined with `and` / `or`. `match` uses regular expressions.
- Rule fields are resolved from tags and fields. `source`, `measurement`, and `class` refer to the Line Protocol measurement. For example, HarmonyOS custom logs use `df_rum_harmonyos_log`.
- While filtering is enabled and an endpoint is valid, the SDK also pulls remote `logging` and `rum` rules from `/v1/datakit/pull?filters=true`. Local and remote rules are combined: a point matching either is discarded. The next pull follows the server's `pull_interval`; an absent or invalid value retries in 10 seconds. A runtime endpoint switch clears rules from the old endpoint and immediately pulls rules from the new one.
- Call `.setEnableDataFilter(false)` to turn off both local and remote filtering without removing the configured rules. Call `.setDataFilters(null)` to clear local rules.
## Data Modification and Masking

Configure callbacks before `FTSDK.install(...)` to modify or mask data before it is cached and uploaded. `DataModifier` runs for every raw Log, native RUM, and WebView RUM tag/field. Return `null` to retain the original value.

`LineDataModifier` runs after SDK tags and fields have been merged. It receives one combined map and returns a patch: only returned values for existing keys are replaced. Returning `null`, an empty map, a `null` value, or an unknown key does not change the record.

```ts
import {
  DataModifier,
  DataModifierValue,
  FTSDK,
  FTSDKConfig,
  LineDataModifier
} from '@guancecloud/ft_sdk/Index'

class FieldMasker implements DataModifier {
  modify(key: string, _value: DataModifierValue): DataModifierValue | null {
    return key === 'password' || key === 'authorization' ? '[masked]' : null
  }
}

class RecordMasker implements LineDataModifier {
  modify(_measurement: string, data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    const patch = new Map<string, DataModifierValue>()
    if (data.get('message') === 'sensitive message') {
      patch.set('message', '[masked]')
    }
    return patch.size === 0 ? null : patch
  }
}

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataModifier(new FieldMasker())
  .setLineDataModifier(new RecordMasker())

FTSDK.install(sdkConfig, this.context)
```

Use `DataModifier` for global key-based rules; it is the lower-overhead option. Use `LineDataModifier` only when a decision needs multiple values in the same record. Neither callback can add, remove, or move a key between tags and fields.

## Main Exports

- `FTSDK`: SDK bootstrap entry
- `FTSDKConfig`: base SDK configuration
- `FTDataFilters`: local data-filter rule type
- `FTRUMConfig`: RUM configuration
- `FTLoggerConfig`: logger configuration
- `FTTraceConfig`: trace configuration
- `SDKLogLevel`: SDK internal log threshold
- `FTTraceContext`: generated Trace Header and RUM linking ID context
- `FTTraceHeaderHandler`: custom Trace Header context handler interface
- `FTTraceRequestContext`: current request context passed to custom Trace Header handlers
- `FTRUMGlobalManager`: RUM reporting API
- `FTLogger`: custom log API
- `FTTraceManager`: trace helper API
- `FTWebViewHandler`: WebView bridge integration API
- `createFTRCPTrackConfig` / `createFTRCPInterceptors`: RCP auto-track helpers
- `RCPTraceInterceptor` / `RCPResourceInterceptor`: advanced manual RCP interceptor assembly
- `DefaultFTTraceInterceptor`: default low-level trace interceptor implementation

## Requirements

- HarmonyOS application project with `ohpm` support
- Network permission for data reporting
- Verify compatibility against your target HarmonyOS API level before release

## Notes

- Call `FTSDK.install(...)` before `installRUMConfig`, `installLogConfig`, and `installTraceConfig`
- Add `@guancecloud/ft_sdk_ext` when you need HarmonyOS `HttpInterceptor` chain integration
- Add `@guancecloud/ft_native` when you need native crash monitoring. `ft_sdk` initializes `libftnativecrash.so` internally when crash tracking is enabled:

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
