# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.0-alpha01] - 2026-09-29

- Added ArkUI and supported ArkWeb replay linked to RUM Views and Errors. Configure `FTSessionReplayConfig`, then call `FTSessionReplay.getInstance().init(config, filesDir)` after core SDK and RUM setup; pass the application's private `filesDir` for persistent caching.
- Added automatic capture of text/layout changes, scrolling, supported animations, viewport resizing, and Router/Navigation transitions. Automatic ArkUI collection requires `@cloudcare/hvigor-ohos-plugin`; manual integrations use `registerRoot(...)`, `unregisterRoot()`, and `recordTouchEvent(event)` to manage page roots and forward touches.
- Added Navigation transition capture on API 15+, with `updateNavigationTransition(...)` and `finishNavigationTransition(...)` for custom animations. Custom Router integrations use `updatePageTransition(...)` and `finishPageTransition(...)` to report progress and completion.
- Added session sampling through `setSampleRate(...)` and error-triggered recording through `setSessionReplayOnErrorSampleRate(...)`, with a one-minute pre-error window by default. Rates range from `0` to `1` (`0.1` means 10%).
- Added privacy controls through `setTextAndInputPrivacy(...)`, `setImagePrivacy(...)`, and `setTouchPrivacy(...)`. Defaults mask text and images and hide touch coordinates; `TouchPrivacy.SHOW` enables multi-finger trajectories. `enableLinkRUMKeys(...)` selects the RUM context fields included in Replay.
- Added `registerImageAsset(...)` for unmasked bundle, file, and network images. Use `unregisterImageAsset(...)` to remove registered assets; Data-URI images can be collected directly.
- Added delayed recording through `setDelayInit(true)` and `start()`. `disable()` stops collection while scheduled uploads drain pending data.
- Added local cache limits through `setStorageMaxBytes(...)` and scheduled uploads through `setUploadIntervalMs(...)`. Use `setUploadIntervalMs(0)` with `flush()` for manual uploads. Replay uses the core SDK's DataKit or Dataway endpoint by default; `setUploadUrl(...)` overrides it.
- Added `cleanup` counts and a reason to resource upload results, separating local cleanup status from upload success.
- Improved Replay recording performance during continuous animation, while keeping availability immediate and final record counts current at View end, recording stop, and upload.
- Fixed text colors, font sizes, alignment, padding, and rounded corners being rendered incorrectly, and Select controls losing labels or dropdown arrows.
- Fixed incorrect initial text typography and missing span styles in inline Text and unfocused RichEditor. Inline images retain their resources when adjacent text changes.
- Fixed native control labels, selection and disabled states, progress, ratings, and animations being rendered incorrectly or failing to update in Replay. Standard controls remain visible when images are masked.
- Fixed native menus, popups, dialogs, and sheets missing from Replay, with correct layering and removal when closed.
- Fixed clipped or transitioning components shrinking and outgoing pages remaining visible after transitions end.
- Fixed incomplete recordings at storage limits or during error-triggered upload, and inconsistent playback after mixed manual/automatic captures.
- Fixed Replay uploads being blocked when acknowledged resources were reused or local cleanup failed or timed out.
- Fixed Replay being marked available before capture succeeds and missing entry points for short visits or after recording stops.
- Known limitations: default Router animation playback is approximate; text colors and automatically resized font sizes may differ when ArkUI does not expose their rendered values.
