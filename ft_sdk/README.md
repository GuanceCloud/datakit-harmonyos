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
  EnvType,
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
  EnvType,
  TraceType
} from '@guancecloud/ft_sdk/Index'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    const sdkConfig = new FTSDKConfig('YOUR_DATAKIT_OR_DATAWAY_URL')
    sdkConfig.setEnv(EnvType.PROD)
    sdkConfig.setServiceName('your_service_name')

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

## Main Exports

- `FTSDK`: SDK bootstrap entry
- `FTSDKConfig`: base SDK configuration
- `FTRUMConfig`: RUM configuration
- `FTLoggerConfig`: logger configuration
- `FTTraceConfig`: trace configuration
- `FTRUMGlobalManager`: RUM reporting API
- `FTLogger`: custom log API
- `FTTraceManager`: trace helper API

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
