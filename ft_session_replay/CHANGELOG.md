# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.0-alpha03] - 2026-10-30
- Restored native rounded clipping around embedded WebViews over opaque solid backgrounds using privacy-safe vector corner masks compatible with existing mobile Replay players.
- Fixed bottom content being clipped after navigating to a safe-area-expanded Router page by respecting native root clipping instead of imposing the root's smaller measured bounds on the whole Replay scene.
- Fixed embedded ArkWeb Replay bottom clipping by synchronizing Browser VisualViewport records with the native Web bounds while preserving zoom and scroll offsets, including native-only resizes.
- Changed `setSampleRate(...)`, `setSessionReplayOnErrorSampleRate(...)`, and their getters to use `[0,100]` percentages for the initial HarmonyOS release. Defaults are `100` and `0`; `1` means 1% without legacy `[0,1]` probability compatibility. Updated sampling decisions, examples, and tests accordingly.

## [0.1.0-alpha02] - 2026-10-23
- Added automatic Replay package-version registration in the core SDK's `sdk_pkg_info.replay` field during initialization.
- Fixed embedded ArkWeb Replay height mismatches by aligning Browser Meta and viewport-resize records with the measured native `Web` wireframe.

## [0.1.0-alpha01] - 2026-10-19
- Added ArkUI and ArkWeb Session Replay. Configure `FTSessionReplayConfig`, then call `FTSessionReplay.getInstance().init(config, filesDir)` after core SDK and RUM initialization. Automatic ArkUI collection requires `@cloudcare/hvigor-ohos-plugin`.
- Added automatic capture of text and inline content, layouts, scrolling, supported animations, viewport changes, Router and Navigation transitions, native controls, overlays, and system icons.
- Added Replay sampling through `setSampleRate(...)` and error-triggered recording through `setSessionReplayOnErrorSampleRate(...)`. Error-triggered recording keeps a one-minute pre-error window by default.
- Added privacy controls through `setTextAndInputPrivacy(...)`, `setCaptureVisiblePassword(...)`, `setImagePrivacy(...)`, and `setTouchPrivacy(...)`. `enableLinkRUMKeys(...)` selects the RUM context included in Replay. Text, images, visible passwords, and touch coordinates remain protected by default.
- Added capture of rendered images, drawing components, ImageAnimator frames, PatternLock interactions, and integrated video playback. Unsupported image sources and custom video players can be supplied explicitly when needed.
- Added delayed recording, explicit recording control, private local caching, and scheduled or immediate uploads through the core SDK's DataKit or Dataway endpoint.
