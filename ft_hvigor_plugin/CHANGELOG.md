# Changelog

## [0.1.2-alpha.2] - 2026-10-30

- Added build warnings with feature names, source paths, skip reasons and source locations for Console/HiLog, cold-launch lifecycle hooks, Session Replay root registration and ArkWeb binding.
- Fixed automatic Session Replay page registration being skipped on pages that use UI enum values or `ForEach`/`LazyForEach`/`Repeat` child blocks, which could leave native View/Action events without `session_has_replay`.

## [0.1.2-alpha.1] - 2026-10-19

- Added automatic Session Replay integration for supported ArkUI `@Entry` pages, ArkWeb components and touch events, without manual page registration or event forwarding. Requires `@guancecloud/ft_session_replay` in the HAP and Replay initialization; touch coordinates require `TouchPrivacy.SHOW`.
- Added automatic recording of Router page-switch animations for Session Replay, including slide and fade effects. Default system animations may differ during playback.
- Fixed build/runtime errors and missing log arguments when automatic console/HiLog collection is enabled.
- Fixed cold-launch instrumentation for inherited UIAbilities and InsightIntent entries, preserving existing lifecycle callbacks. Apps without an AbilityStage now use approximate application-initialization timing.
- Fixed build errors and repeated execution of page `.id()` expressions caused by automatic Replay collection.
- Changed automatic collection to run only in modules that declare the required SDK packages in their own `oh-package.json5` `dependencies`; other modules are left unchanged.
- Fixed automatic logging, cold-launch or Replay code being omitted from some application modules when multiple HAP modules are built together.

## [0.1.1] - 2026-09-14

- Fixed console/HiLog instrumentation being skipped when cold-launch instrumentation is enabled in the same Hvigor plugin.

## [0.1.0] - 2026-09-14

- Added compiler instrumentation for automatic console/HiLog collection.
- Added compiler instrumentation for cold-launch tracking.

## [0.1.0-alpha.3] - 2026-09-11

- Added build-time registration of the installed plugin version in SDK `sdk_pkg_info.track`.

## [0.1.0-alpha.2] - 2026-09-11

- Added GitHub Actions trusted npm publishing triggered by plugin version tags.
- Added the plugin version badge to the package documentation.

## [0.1.0-alpha.1] - 2026-09-11

- Prepared the initial npm prerelease of the console/HiLog and cold-launch instrumentation plugin.
