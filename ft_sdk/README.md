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
