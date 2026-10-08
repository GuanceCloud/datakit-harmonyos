# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3-alpha01] - 2026-09-22
- Exposed `app_running_unique_id` in Native Crash callback data, allowing crash recovery to distinguish separate process runs that share the same crash stack UUID.

## [0.1.2] - 2026-09-11
- Streamlined native crash-monitoring diagnostics by moving verbose normal-path NAPI, signal-handler, and crash-parser logs to Debug and removing redundant lifecycle logs. No native crash-collection API or behavior changed.

## [0.1.2-alpha01] - 2026-09-05
- Optimized native crash-monitoring diagnostics by moving verbose normal-path logs to Debug and removing redundant lifecycle logs. No API or crash-collection behavior changed.

## [0.1.1] - 2026-07-29
- `ft_native` 0.1.1 replaces the Debug-built 0.1.0 distribution with a production HAR built in Release mode (`debug: false`).
- The release artifact uses ArkTS bytecode packaging and ArkGuard obfuscation, while consumer rules preserve the native crash-monitoring public API for host applications that enable obfuscation.
- This is a packaging and code-protection correction; it does not change the native crash-monitoring API or behavior.

## [0.1.0] - 2026-07-17
- Released the first stable `ft_native` package for standalone native crash monitoring.
- Native crash collection automatically adapts to the installed `ft_sdk` dependency and excludes JavaScript crashes to prevent duplicate reporting.

## [0.1.0-alpha03] - 2026-07-16
- update LICENSE

## [0.1.0-alpha02] - 2026-03-13
- The ft_native library is decoupled from ft_sdk and will automatically capture native crashes based on the dependency situation.
- Improve SDK version logging
- ft_sdk:>=0.1.13-alpha01

## [0.1.0-alpha01] - 2026-02-09

### Fixed

#### JavaScript Crash Duplicate Reporting
- **Fixed JavaScript crashes being reported as native crashes**: JavaScript errors (crash_type: "JsError") were incorrectly passed to ArkTS layer and reported as native crashes
  - Added crash type filtering in `FTNativeCrashHandler.cpp` before invoking ArkTS callback
  - JavaScript crashes are now skipped at C++ layer with log message: `*** SKIPPING JS CRASH *** (handled by errorManager)`
  - Only true native crashes (SIGSEGV, SIGABRT, etc.) are passed to `FTNativeCrashAdapter` for reporting
  - This prevents duplicate reporting: JavaScript crashes are handled by `errorManager` in `ft_sdk`, native crashes are handled by `ft_native`
