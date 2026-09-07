# ft_sdk_ext

Guance HarmonyOS extension SDK for newer HarmonyOS compiler and platform capabilities.

## Introduction

`@guancecloud/ft_sdk_ext` is the extension package for capabilities that are intentionally isolated from the core package, especially HarmonyOS NetworkKit `HttpInterceptor` chain integration.

## Features

- Extension APIs built on top of `@guancecloud/ft_sdk`
- NetworkKit and interceptor-based HTTP auto tracking helpers
- Compatibility layer for newer HarmonyOS capabilities

NetworkKit HTTP and Axios Chain transport failures (`responseCode=0`) produce
both a Resource and its linked network Error. When the interceptor has no native
failure details, the Error includes a diagnostic message and the interceptor's
call stack. The request still fails normally for the caller.

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

## Cold-launch First-frame Timing

Cold-launch first-frame observation is injected automatically by the Guance
Hvigor compiler plugin. Do not call `observeFTAppFirstFrame()` from application
code. On API 22 and later the plugin records the real first draw; earlier API
levels omit the first-frame phase.

## Dependency

- Required: `@guancecloud/ft_sdk`
- Recommended: keep `@guancecloud/ft_sdk_ext` and `@guancecloud/ft_sdk` aligned on the same release version

## Requirements

- HarmonyOS project using NetworkKit interceptor-chain APIs
- This package is an addition to the core SDK, not a replacement for it

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## Device Tests

In DevEco Studio, run `src/ohosTest/ets/test/List.test.ets` as an Instrument Test
with module `ft_sdk_ext` and product `default` (API 22 or later). The device
command must target `-m ft_sdk_ext_test`. The full suite contains the HTTP chain
tests and the first-frame listener test. Check the final `Tests run`, `Failure`,
`Error`, and `Pass` counts; `TestFinished-ResultCode: 0` alone does not mean the
assertions passed.

The `ohosTest` build target explicitly includes the core SDK Worker entry points.
The shared device-test collector keeps the real Worker, line-protocol assembly,
and database commit/deletion path, and injects HTTP results at the upload Worker
boundary. These cases do not contact a real collector. Use a real-backend smoke
test separately to verify network transport. The test helper imports from
`ft_sdk/src/ohosTest` are for this repository's local tests only.

## License

- Apache-2.0
