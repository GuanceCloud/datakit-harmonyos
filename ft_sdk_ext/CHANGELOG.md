# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.16-alpha03] - 2026-08-20
- Added the API 22 `observeFTAppFirstFrame(...)` helper for one-shot cold-launch first-frame timing.

## [0.1.16-alpha02] - 2026-08-18
- No extension API changes.

## [0.1.16-alpha01] - 2026-08-14
- No extension API changes; released with `ft_sdk` 0.1.16-alpha01.

## [0.1.15] - 2026-07-29
- Released `ft_sdk_ext` 0.1.15 as a production HAR package, aligned with `ft_sdk` 0.1.15.
- The published package is built in Release mode (`debug: false`) as an ArkTS bytecode HAR and has ArkGuard obfuscation enabled.
- Added consumer obfuscation rules to preserve the extension's documented interceptor APIs when the host application also enables obfuscation.

## [0.1.14] - 2026-07-17
- Released the stable `ft_sdk_ext` package, aligned with `ft_sdk` 0.1.14.
- Provides NetworkKit interceptor integration through the versioned `FTSDKExtensionBridge` contract.

## [0.1.14-alpha07] - 2026-07-16
- No changes, aligned with the ft_sdk version

## [0.1.14-alpha06] - 2026-05-14
- Migrated NetworkKit interceptor integration to the versioned `FTSDKExtensionBridge` contract from `ft_sdk`.
- Removed `ft_sdk_ext` dependencies on internal ft_sdk source-tree import paths.

## [0.1.14-alpha05] - 2026-05-11
- Updated the supported compatibleApi range to API 22

## [0.1.14-alpha04] - 2026-04-30
- No changes, aligned with the ft_sdk version

## [0.1.14-alpha03] - 2026-04-14
- Added the new `ft_sdk_ext` HAR module to isolate HarmonyOS NetworkKit `HttpInterceptor` APIs from the core `ft_sdk` package.
- Added `createFTHttpInterceptorChain` and `applyFTHttpTrack` as extension-only exports for newer compiler and platform support.
- Added `applyFTAxiosChainMethodBridge` to the extension module for axios `interceptorChain` integrations.
- Aligned `ft_sdk_ext` version generation with `ft_sdk` through `hvigorfile.ts` and the local sync script.
- Documented the local HAR compatibility setup for `oh-package.json5` and root `overrides` handling.
