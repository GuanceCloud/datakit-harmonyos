# Changelog

## [0.1.2-alpha.1] - 2026-10-19

- Added automatic page registration and lifecycle tracking for supported ArkUI `@Entry` pages. After adding `@guancecloud/ft_session_replay` to the HAP and initializing `FTSessionReplay`, applications no longer need to register visible page roots manually.
- Added automatic ArkWeb component association for Session Replay, linking supported Web content to the correct Replay page without manual component IDs or controller registration.
- Added automatic touch capture for Session Replay, removing the need to forward page touch events manually. Touch coordinates are recorded only when `TouchPrivacy.SHOW` is configured.
- Added Router transition capture for `PageTransitionEnter/Exit` slide and opacity animations and default Router page changes. Default system transition playback may be approximate.

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
