# Changelog

## [0.1.2-alpha01] - 2026-09-29

- Added automatic Session Replay root registration for `@Entry` ArkUI pages.
  The compiler now injects opaque page-instance tokens and page visibility
  callbacks in memory, while the optional Replay HAR centrally selects the
  latest visible, laid-out root.
- Preserved existing page root IDs and skipped Replay source transformation
  entirely when the HAP does not declare `@guancecloud/ft_session_replay`.
- Forwarded real root touch events through the Replay privacy policy while
  preserving existing application callbacks. Automatic root registration
  composes outgoing/incoming roots in page-stack drawing order. Page-transition
  slide and opacity effects use native progress callbacks, preserving existing
  application callbacks.
- Added an effect-free default Router transition start hook for pages without
  `pageTransition()`, preserving the system default animation and existing
  explicit effects and callbacks.

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
