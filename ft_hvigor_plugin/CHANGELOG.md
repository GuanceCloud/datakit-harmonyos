# Changelog

## [0.1.0] - 2026-09-05

- Added compiler instrumentation for automatic console/HiLog collection.
- Added compiler instrumentation for cold-launch tracking.
- Fixed cold-launch instrumentation to retry first-frame observation after `WindowStage.loadContent(...)` completes successfully.
