# ft_native

Guance HarmonyOS native crash monitoring module for native crash collection and reporting.

## Introduction

`@guancecloud/ft_native` provides native-layer crash collection for HarmonyOS and is intended to be used together with `@guancecloud/ft_sdk`.

## Features

- Native crash capture
- C++ crash signal handling
- Integration with HarmonyOS applications
- Works together with `@guancecloud/ft_sdk`

## Package

- Name: `@guancecloud/ft_native`
- License: `Apache-2.0`

## Installation

```bash
ohpm install @guancecloud/ft_native
```

Short form:

```bash
ohpm i @guancecloud/ft_native
```

## Usage

Add `@guancecloud/ft_native` together with `@guancecloud/ft_sdk`, then enable crash tracking in RUM configuration:

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

The native module contributes `libftnativecrash.so`; `ft_sdk` detects and initializes it internally when crash tracking is enabled.

## Dependency

- Recommended: use together with `@guancecloud/ft_sdk`
- Native crash events complement the core SDK monitoring pipeline
- Use a compatible `@guancecloud/ft_sdk` version in the application so native crash events can be reported into the RUM pipeline.

## Requirements

- HarmonyOS project with native library support
- Use together with the Guance HarmonyOS core SDK for reporting and unified monitoring

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
