# Changelog

## [0.1.2-alpha01] - 2026-09-29

- Added automatic Session Replay page registration and visibility tracking for supported `@Entry` ArkUI pages. Declare `@guancecloud/ft_session_replay` in the HAP and initialize `FTSessionReplay`; existing root IDs and page callbacks are preserved.
- Added automatic root touch capture controlled by Replay's `TouchPrivacy` setting. Existing `onTouch` callbacks and event propagation are preserved.
- Added capture of `PageTransitionEnter/Exit` slide and opacity effects, plus default Router animations. Existing transition settings and callbacks are preserved; default Router playback is approximate.

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
