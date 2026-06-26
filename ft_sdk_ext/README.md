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

## Dependency

- Required: `@guancecloud/ft_sdk`
- Recommended: keep `@guancecloud/ft_sdk_ext` and `@guancecloud/ft_sdk` aligned on the same release version

## Requirements

- HarmonyOS project using NetworkKit interceptor-chain APIs
- This package is an addition to the core SDK, not a replacement for it

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
