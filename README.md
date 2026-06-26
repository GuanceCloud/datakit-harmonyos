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

## Package Guide

- `@guancecloud/ft_sdk`: standard SDK initialization, RUM, logging, tracing, and common network helpers
- `@guancecloud/ft_sdk_ext`: add when you need HarmonyOS `HttpInterceptor` chain integration
- `@guancecloud/ft_native`: add when you need native crash monitoring through the implicit `libftnativecrash.so` integration

## Native Crash Monitoring

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

Add `@guancecloud/ft_native` to the application dependencies so `libftnativecrash.so` is packaged with the app. When crash tracking is enabled, `ft_sdk` initializes the native crash module internally.

## Release Checklist

- Ensure package names, versions, descriptions, author, and license in each module `oh-package.json5` are correct before `ohpm publish`.
- Keep the published version compliant with semantic versioning.
- Verify dependency versions stay aligned. In particular, `@guancecloud/ft_sdk_ext` should depend on the same `@guancecloud/ft_sdk` version that is being released.
- Confirm the public documentation page is ready and matches the published package behavior.
- Clean local build artifacts such as `build/` and `oh_modules/` from the release package or release branch if they are not meant to be shipped.
- Recheck compatibility claims against the demo project settings before release.

## Documentation

[Documentation Center](https://docs.guance.com/real-user-monitoring/harmonyos/app-access/)
