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

Use `FTSDK.updateRemoteConfig()` for an interval-respecting manual refresh, or pass `0` as the first argument to the overload to force a fetch. `FTSDK.setEnableAccessDeviceID(...)` can switch the runtime `device_uuid` between the system identifier (when available) and the SDK's privacy UUID.

## Update the Reporting Endpoint at Runtime

After `FTSDK.install(...)`, switch the active reporting endpoint without recreating the SDK:

```ts
// DataKit mode
FTSDK.setDatakitUrl('https://datakit.example.com')

// Dataway mode
FTSDK.setDatawayUrl('https://dataway.example.com', 'YOUR_CLIENT_TOKEN')
```

The two modes are mutually exclusive: setting a DataKit URL clears the Dataway URL and token; setting a Dataway URL clears the DataKit URL. Use a complete `http://` or `https://` URL. The new value is kept in memory only, so configure it again after an app restart if needed. Automatic upload resumes when the endpoint is valid; call `FTSDK.flushSyncData()` when you need to request an immediate upload.

## Local Data Filtering

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
- A rule is enclosed in `{}`. Supported operators are `in`, `not in`, `match`, and `not match`, combined with `and` / `or`. `match` uses regular expressions.
- Rule fields are resolved from tags and fields. `source`, `measurement`, and `class` refer to the Line Protocol measurement. For example, HarmonyOS custom logs use `df_rum_harmonyos_log`.
- Call `.setEnableDataFilter(false)` to turn off local filtering without removing the configured rules. Call `.setDataFilters(null)` to clear rules.

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
