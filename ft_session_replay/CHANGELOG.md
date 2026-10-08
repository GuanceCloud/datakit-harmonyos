# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.0-alpha01] - 2026-09-29

- Added Session Replay for ArkUI pages and supported ArkWeb content, linked to Guance RUM Views and Errors.
- Added session sampling, error-triggered recording, and configurable text, image, and touch privacy.
- Added private on-device storage, scheduled uploads, and an explicit `flush()` option.
- Added automatic ArkUI page registration through the optional Guance Hvigor plugin; other integrations can register the visible root manually.
- Fixed Replay starting on an already visible page: it attaches to the current RUM View and captures a first snapshot without changing the session or View ID.
- Fixed Replay stopping before accepted snapshots finish: their image resources and final View End now reach storage, and scheduled uploads drain pending segments with retries. Rapid restart preserves the active upload schedule.
- Fixed RUM Replay metadata being reported before capture succeeds; `has_replay` and the record count are now updated after successful capture, including when the View has already closed.
- Added first-snapshot and scheduled or manual upload diagnostics through the core SDK logger.
- Known limitation: inherited text colors and automatically resized long button labels may differ from the original ArkUI screen during playback.
