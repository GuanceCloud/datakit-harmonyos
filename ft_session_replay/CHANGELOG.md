# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.0-alpha01] - 2026-09-29

- Added an effect-free compiler hook for the real default Router transition start. Replay prefers native intermediate geometry and reconstructs target-only Push/Pop positions with a bounded default-spring approximation; disposed outgoing pages are released at its end. Native timing variations, clipping, and masks still require playback validation.
- Fixed delayed Worker processing dropping default Router intermediate frames after one second. Samples within the bounded reconstruction window now retain their original timestamps and View context through the ordered queue.
- Fixed Replay snapshots using stale baselines after mixed manual/automatic captures, queued View changes, or Worker recovery. Ordered writes reuse committed checkpoints and viewport state, and native node reordering retains unchanged nodes instead of replacing them unnecessarily.
- Fixed Replay cache trimming and error-window promotion retaining mutations without their required Full Snapshot. The retained checkpoint chain remains replayable, and writes rejected by quota eviction recover the same frame with a Full Snapshot.
- Fixed short visits losing Replay when their first snapshot waited over one second: both queue and Worker retain the captured View Start under its original View ID and write it before View End. Added first-frame latency and unavailable-root diagnostics.
- Added Session Replay for ArkUI pages and supported ArkWeb content, linked to Guance RUM Views and Errors.
- Fixed scrolling and page transitions shrinking partially visible components during playback. Native node sizes are now preserved with independent clipping, and returning into view explicitly clears clipping through Mutation updates. Page scenes use stable window bounds and page slide distances, retain outgoing pages through known transition progress, and observe Navigation lifecycle and paint order on supported runtimes. Custom Navigation animations can forward their actual progress and completion through the Replay API. Page backgrounds and stacking prevent controls from different pages bleeding through during transitions. Explicit resize signals use captured native dimensions when available. Completion removes detached outgoing pages from the scene, and Router stack positions preserve Pop layering when the returning page is recreated. Default Router transitions stop reusing unreadable outgoing frames; page removal no longer waits for the successor's layout. Removal and settled-motion frames remain queued through processing delays, preventing a partial transition from becoming the final replay image.
- Added automatic capture of drawn text, style, and layout changes, including motion sampled at a default 32 ms interval with a settled final frame. With `TouchPrivacy.SHOW`, compiler hooks record multi-finger touch trajectories and cancellation while preserving application callbacks; integrations without the plugin can forward `recordTouchEvent(event)`.
- Added root readiness diagnostics for automatic page registration.
- Added session sampling, error-triggered recording, and configurable text, image, and touch privacy.
- Added private on-device storage, scheduled uploads, and an explicit `flush()` option.
- Added automatic ArkUI page registration through the optional Guance Hvigor plugin; other integrations can register the visible root manually.
- Fixed Replay starting on an already visible page: it attaches to the current RUM View and captures a first snapshot without changing the session or View ID.
- Fixed Replay stopping before accepted snapshots finish: their image resources and final View End now reach storage, and scheduled uploads drain pending segments with retries. Rapid restart preserves the active upload schedule.
- Fixed RUM Replay metadata being reported before capture succeeds; `has_replay` and the record count are now updated after successful capture, including when the View has already closed.
- Fixed closed RUM Views being cleaned up before accepted Replay writes and metadata updates finish, including after recording stops. Successful writes now retain the original View long enough to report its Replay availability and final record count.
- Added first-snapshot and scheduled or manual upload diagnostics through the core SDK logger.
- Known limitation: inherited text colors and automatically resized long button labels may differ from the original ArkUI screen during playback.
