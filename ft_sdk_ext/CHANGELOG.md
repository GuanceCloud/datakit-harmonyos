# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.14-alpha03] - 2026-04-14
- Added the new `ft_sdk_ext` HAR module to isolate HarmonyOS NetworkKit `HttpInterceptor` APIs from the core `ft_sdk` package.
- Added `createFTHttpInterceptorChain` and `applyFTHttpTrack` as extension-only exports for newer compiler and platform support.
- Added `applyFTAxiosChainMethodBridge` to the extension module for axios `interceptorChain` integrations.
- Aligned `ft_sdk_ext` version generation with `ft_sdk` through `hvigorfile.ts` and the local sync script.
- Documented the local HAR compatibility setup for `oh-package.json5` and root `overrides` handling.
