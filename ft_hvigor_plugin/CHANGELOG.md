# Changelog

## [0.1.0-alpha.3] - 2026-09-11

- Added build-time registration of the installed plugin version in SDK `sdk_pkg_info.track`.

## [0.1.0-alpha.2] - 2026-09-11

- Added GitHub Actions trusted npm publishing triggered by plugin version tags.
- Added the plugin version badge to the package documentation.

## [0.1.0-alpha.1] - 2026-09-11

- Prepared the initial npm prerelease of the console/HiLog and cold-launch instrumentation plugin.

## [0.1.0] - 2026-09-05

- Added compiler instrumentation for automatic console/HiLog collection.
- Added compiler instrumentation for cold-launch tracking.
- Fixed cold-launch instrumentation to retry first-frame observation after `WindowStage.loadContent(...)` completes successfully.
