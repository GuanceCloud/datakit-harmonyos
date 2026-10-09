# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.0-alpha01] - 2026-09-29

- Fixed Replay snapshots using stale baselines after mixed manual/automatic captures, queued View changes, or Worker recovery. Ordered writes reuse committed checkpoints and viewport state, and native node reordering retains unchanged nodes instead of replacing them unnecessarily.
- Fixed Replay cache trimming and error-window promotion retaining mutations without their required Full Snapshot. The retained checkpoint chain remains replayable, and writes rejected by quota eviction recover the same frame with a Full Snapshot.
- Fixed short visits losing Replay when their first snapshot waited over one second: both queue and Worker retain the captured View Start under its original View ID and write it before View End. Added first-frame latency and unavailable-root diagnostics.
- Added Session Replay for ArkUI pages and supported ArkWeb content, linked to Guance RUM Views and Errors.
- Added session sampling, error-triggered recording, and configurable text, image, and touch privacy.
- Added private on-device storage, scheduled uploads, and an explicit `flush()` option.
- Added automatic ArkUI page registration through the optional Guance Hvigor plugin; other integrations can register the visible root manually.
- Fixed Replay starting on an already visible page: it attaches to the current RUM View and captures a first snapshot without changing the session or View ID.
- Fixed Replay stopping before accepted snapshots finish: their image resources and final View End now reach storage, and scheduled uploads drain pending segments with retries. Rapid restart preserves the active upload schedule.
- Fixed RUM Replay metadata being reported before capture succeeds; `has_replay` and the record count are now updated after successful capture, including when the View has already closed.
- Fixed closed RUM Views being cleaned up before accepted Replay writes and metadata updates finish, including after recording stops. Successful writes now retain the original View long enough to report its Replay availability and final record count.
- Added first-snapshot and scheduled or manual upload diagnostics through the core SDK logger.
- Known limitation: inherited text colors and automatically resized long button labels may differ from the original ArkUI screen during playback.
