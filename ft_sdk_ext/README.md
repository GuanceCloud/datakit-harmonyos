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

`@guancecloud/ft_sdk_ext` is an extension package built on top of `@guancecloud/ft_sdk`. Install matching versions of both packages together.

## Import

```ts
import {
  createFTHttpInterceptorChain,
  applyFTHttpTrack,
  applyFTAxiosChainMethodBridge,
  FTHttpInterceptorChainOptions
} from '@guancecloud/ft_sdk_ext/Index'
```

`FTHttpInterceptorChainOptions` describes the optional trace/resource switches and additional NetworkKit interceptors accepted by `createFTHttpInterceptorChain` and `applyFTHttpTrack`. Its `networkErrorHandler` option uses the core SDK's local Network Error filter contract: return `true` only to suppress the Error derived from a no-response local failure; the Resource and HTTP 4xx/5xx behavior remain unchanged.

## Quick Start

Use this package together with `@guancecloud/ft_sdk` when you need `HttpInterceptor` chain support:

```ts
import { createFTHttpInterceptorChain } from '@guancecloud/ft_sdk_ext/Index'

const interceptorChain = createFTHttpInterceptorChain({
  enableTraceInterceptor: true,
  enableResourceInterceptor: true
})
```

## Dependency

- Required: `@guancecloud/ft_sdk`
- Recommended: keep `@guancecloud/ft_sdk_ext` and `@guancecloud/ft_sdk` on the same version

## Requirements

- HarmonyOS project using NetworkKit interceptor-chain APIs
- This package is an addition to the core SDK, not a replacement for it
- `ft_sdk_ext` declares no permissions. Its `ft_sdk` dependency declares the
  core normal permissions, so a consuming HAP does not need to duplicate them.

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
