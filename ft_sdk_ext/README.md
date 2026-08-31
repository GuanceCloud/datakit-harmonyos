# ft_sdk_ext

Guance HarmonyOS extension SDK for newer HarmonyOS compiler and platform capabilities.

## Introduction

`@guancecloud/ft_sdk_ext` is the extension package for capabilities that are intentionally isolated from the core package, especially HarmonyOS NetworkKit `HttpInterceptor` chain integration.

## Features

- Extension APIs built on top of `@guancecloud/ft_sdk`
- NetworkKit and interceptor-based HTTP auto tracking helpers
- Compatibility layer for newer HarmonyOS capabilities

## Package

- Name: `@guancecloud/ft_sdk_ext`
- Depends on: `@guancecloud/ft_sdk`
- License: `Apache-2.0`

## Installation

```bash
ohpm install @guancecloud/ft_sdk_ext
```

Short form:

```bash
ohpm i @guancecloud/ft_sdk_ext
```

`@guancecloud/ft_sdk_ext` is an extension package built on top of `@guancecloud/ft_sdk`. Keep both package versions aligned when releasing or consuming them together.

## Import

```ts
import {
  createFTHttpInterceptorChain,
  applyFTHttpTrack,
  applyFTAxiosChainMethodBridge
} from '@guancecloud/ft_sdk_ext/Index'
```

## Quick Start

Use this package together with `@guancecloud/ft_sdk` when you need `HttpInterceptor` chain support:

```ts
import { createFTHttpInterceptorChain } from '@guancecloud/ft_sdk_ext/Index'

const interceptorChain = createFTHttpInterceptorChain({
  enableTraceInterceptor: true,
  enableResourceInterceptor: true
})
```

## API 22 First-frame Cold Launch Timing

On API 22, first call `observeFTAppFirstFrame()` at the beginning of the first
`UIAbility.onWindowStageCreate()` and before `loadContent()`. Some devices do
not permit the listener until the content-loading operation has completed. If
the first registration returns `false`, make one further attempt from the
successful `loadContent()` callback. The SDK only accepts an event whose
`firstDrawFrame` is `true`; a late registration that receives later frames does
not produce a synthetic T3.

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import window from '@ohos.window'
import { observeFTAppFirstFrame } from '@guancecloud/ft_sdk_ext/Index'

export class EntryAbility extends UIAbility {
  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const firstFrameListenerRegistered = observeFTAppFirstFrame(windowStage)
    windowStage.loadContent('pages/Index', (error) => {
      if (!error.code && !firstFrameListenerRegistered) {
        observeFTAppFirstFrame(windowStage)
      }
    })
  }
}
```

The observer deliberately uses the callback-arrival value of
`systemDateTime.getUptime(TimeType.STARTUP, true)` rather than
`FrameMetrics.vsyncTimestamp` until their clock origins have been confirmed on
an API 22 device. It is a real first-draw signal, but avoids mixing time bases
in phase durations.

## Dependency

- Required: `@guancecloud/ft_sdk`
- Recommended: keep `@guancecloud/ft_sdk_ext` and `@guancecloud/ft_sdk` aligned on the same release version

## Requirements

- HarmonyOS project using NetworkKit interceptor-chain APIs, or API 22
  first-frame metrics for cold-launch timing
- This package is an addition to the core SDK, not a replacement for it

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
