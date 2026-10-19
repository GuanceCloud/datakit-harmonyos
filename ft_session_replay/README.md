# ft_session_replay

Guance HarmonyOS Session Replay SDK for ArkUI pages and supported ArkWeb content.

## Introduction

`@guancecloud/ft_session_replay` is an optional package built on top of
`@guancecloud/ft_sdk`. It records page content and interactions, associates
recordings with RUM Views and Errors, and uploads through the core SDK's
DataKit or Dataway endpoint.

## Features

- ArkUI page and supported ArkWeb replay
- Automatic page registration and touch capture through the optional Hvigor plugin
- Session sampling and error-triggered recording
- Text/input, image, and touch privacy controls
- Private local caching and scheduled or manual uploads

## Package

- Name: `@guancecloud/ft_session_replay`
- Depends on: `@guancecloud/ft_sdk`
- License: `Apache-2.0`

## Installation

Install the Replay package in the application's HAP module:

```bash
ohpm install @guancecloud/ft_session_replay
```

Short form:

```bash
ohpm i @guancecloud/ft_session_replay
```

This bytecode HAR requires normalized OHMUrl. See [Requirements](#requirements)
for the project configuration.

## Import

```ts
import {
  FTSessionReplay,
  FTSessionReplayConfig,
  TextAndInputPrivacy,
  ImagePrivacy,
  TouchPrivacy
} from '@guancecloud/ft_session_replay/Index'
```

## Quick Start

Initialize the core SDK and RUM before Replay in `UIAbility.onCreate`.
Pass the application's private `filesDir` for persistent caching.

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import type Want from '@ohos.app.ability.Want'
import { FTSDK, FTSDKConfig, FTRUMConfig } from '@guancecloud/ft_sdk/Index'
import {
  FTSessionReplay,
  FTSessionReplayConfig
} from '@guancecloud/ft_session_replay/Index'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_URL')
    FTSDK.install(sdkConfig, this.context)

    const rumConfig = new FTRUMConfig()
      .setRumAppId('YOUR_RUM_APP_ID')
      .setEnableTraceUserView(true)
    FTSDK.installRUMConfig(rumConfig)

    const replayConfig = new FTSessionReplayConfig()
      .setSampleRate(0.1)
    FTSessionReplay.getInstance().init(replayConfig, this.context.filesDir)
  }
}
```

Replay starts automatically after `init()`. Automatic ArkUI Session Replay
collection requires the
[`@cloudcare/hvigor-ohos-plugin` build plugin](https://www.npmjs.com/package/@cloudcare/hvigor-ohos-plugin?activeTab=readme).

## Manual Page Registration

For integrations without the plugin, give the page root an ID and register it
when the page becomes visible and after layout. Forward touch events to Replay.

```ts
import { FTSessionReplay } from '@guancecloud/ft_session_replay/Index'

@Entry
@Component
struct ReplayPage {
  private replay: FTSessionReplay = FTSessionReplay.getInstance()

  private registerReplayRoot(): void {
    this.replay.registerRoot(this.getUIContext(), 'replay-page-root', vp2px(1))
  }

  onPageShow(): void {
    this.registerReplayRoot()
  }

  onPageHide(): void {
    this.replay.unregisterRoot()
  }

  build() {
    Column() {
      Text('Session Replay')
    }
    .id('replay-page-root')
    .onAreaChange(() => this.registerReplayRoot())
    .onTouch((event: TouchEvent) => this.replay.recordTouchEvent(event))
  }
}
```

When starting Replay on an already visible page, register that root again.
If a child stops touch-event bubbling, forward its events too.
`recordTouchEvent(event)` accepts ArkUI's window-relative vp coordinates;
the lower-level `recordTouch(...)` accepts physical pixels.

For manual capture of overlapping Router pages, pass `true` as the fourth
`registerRoot()` argument and root IDs in native drawing order as the fifth.

Automatic capture uses a default 32 ms interval. Adjust it with
`setSnapshotIntervalMs(ms)`; the minimum is 16 ms.
`notifyPageChanged()`, `notifyScroll()`, and `notifyTransition()` provide
explicit signals for content changes, scrolling, and animations.

## Sampling Rates

Replay rates use values in `[0,1]`: `0.1` means **10%** and `1` means
**100%**. Replay sampling is configured separately from the core SDK's
percentage-based RUM sampling.

| Capability | Setter | Default |
| --- | --- | --- |
| Session Replay | `setSampleRate(...)` | `1` |
| Error-triggered Replay | `setSessionReplayOnErrorSampleRate(...)` | `0` |

To record only error-sampled sessions:

```ts
const replayConfig = new FTSessionReplayConfig()
  .setSampleRate(0)
  .setSessionReplayOnErrorSampleRate(1)
```

Error-triggered recordings keep a one-minute pre-error window locally and
enter the upload queue after a matching RUM Error.

## Privacy and Images

Configure privacy before `init()`. The defaults mask all text and images
and hide touch coordinates.

| Content | Setter | Default |
| --- | --- | --- |
| Text and inputs | `setTextAndInputPrivacy(...)` | `TextAndInputPrivacy.MASK_ALL` |
| Images | `setImagePrivacy(...)` | `ImagePrivacy.MASK_ALL` |
| Touch coordinates | `setTouchPrivacy(...)` | `TouchPrivacy.HIDE` |

```ts
const replayConfig = new FTSessionReplayConfig()
  .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS)
  .setImagePrivacy(ImagePrivacy.MASK_NONE)
  .setTouchPrivacy(TouchPrivacy.SHOW)
  .enableLinkRUMKeys(['service', 'env'])
```

`MASK_SENSITIVE_INPUTS` keeps ordinary text while masking sensitive inputs;
`MASK_ALL_INPUTS` masks every input. `TouchPrivacy.SHOW` records
multi-finger down/move/up positions. `enableLinkRUMKeys(...)` selects the RUM
context fields included in Replay.

Visible `Image` components using bundle, file, network, PixelMap, or drawable
sources are captured automatically.

`ImageAnimator`, `QRCode`, `Canvas`, and `Shape` components are also captured
automatically. On API 12–14, assign a stable `.id()` to captured components.
Captured media follows `ImagePrivacy`; drawing components are hidden when
`TextAndInputPrivacy.MASK_ALL` is enabled.

If an image cannot be captured automatically, provide it with
`registerImageAsset(componentIdOrSource, bytes, mimeType)` and call
`unregisterImageAsset(...)` when it is no longer needed.

### Video

To capture an ArkUI `Video`, assign a stable `.id()`, register its source and
poster, forward playback events, and unregister it when the player disappears:

```ts
const replay = FTSessionReplay.getInstance()
replay.registerVideoSource('player', videoUrl, $r('app.media.video_cover'))

Video({ src: videoUrl, previewUri: $r('app.media.video_cover') })
  .id('player')

// Forward changes from the corresponding Video callbacks.
replay.updateVideoState('player', { currentTime, duration, playing, buffering })

// When the player is removed:
replay.unregisterVideoSource('player')
```

Replay records the poster, playback state, timeline, and periodic keyframes; it
does not record audio or a continuous video stream. Local file keyframes require
API 12+. HTTP(S) keyframes require API 20+ and may make additional network
requests. Authenticated and DRM streams retain the poster. Video frames follow
`ImagePrivacy`; source URLs and authentication data are not stored in Replay.

For a custom player or `XComponent(SURFACE)`, register a frame provider:

```ts
replay.registerVideoFrameProvider('player', async (_timeSeconds) => {
  return image.createPixelMapFromSurface(surfaceId, surfaceRegion)
})
```

## Recording Control

Set `.setDelayInit(true)` on the configuration before `init()` to defer
recording until consent or application configuration is ready.

```ts
const replay = FTSessionReplay.getInstance()

// Start recording when ready.
replay.start()

// Stop collecting new data when needed.
replay.disable()
```

## Upload and Storage

Replay uses the core SDK's DataKit or Dataway endpoint. Private local caching
requires passing `filesDir` to `init()`.

| Configuration | Setter | Default |
| --- | --- | --- |
| Cache capacity | `setStorageMaxBytes(...)` | 10 MiB |
| Upload interval | `setUploadIntervalMs(...)` | 15,000 ms |
| Upload endpoint | `setUploadUrl(...)` | Core SDK endpoint |

Call `await FTSessionReplay.getInstance().flush()` for an immediate upload.
Set `setUploadIntervalMs(0)` for manual uploads. `setUploadUrl(url)`
overrides the Replay endpoint when a separate route is needed.

After `disable()`, pending data finishes saving and scheduled uploads
continue. With manual uploads configured, call `flush()` explicitly.
Older recordings are removed when the cache limit is reached. The package
does not encrypt data in the application's private files directory.

## RUM Association

Replay follows the active RUM Session and View. After a frame is saved,
associated native Views, Actions, Resources, Long Tasks, and Errors report
`session_has_replay=true`. Views and Actions also retain `has_replay`.
These are SDK-managed fields; custom context cannot override Replay availability.
Starting or stopping Replay does not affect RUM collection.

When automatic RUM View tracking is enabled, avoid also calling `startView()`
for the same page. ArkWeb recording uses the core SDK's `FTWebViewHandler`
bridge and a Browser RUM SDK in the web page.

## Page Transitions

The Hvigor plugin observes explicit Router transition progress and default
Router animations. Default animation playback is approximate.

Navigation transition capture requires API 15+. For custom animations,
forward progress in `[0,1]` with
`updateNavigationTransition(uniqueId, entering, progress, slide?, opacity?)`,
then call `finishNavigationTransition(uniqueId)` on completion or cancellation.
Custom Router integrations use `updatePageTransition(...)` and
`finishPageTransition(rootId)`.

## Main Exports

- `FTSessionReplay`: initialization, recording, page registration, and upload API
- `FTSessionReplayConfig`: sampling, privacy, capture, and storage configuration
- `TextAndInputPrivacy`: text and input masking policy
- `ImagePrivacy`: image masking policy
- `TouchPrivacy`: touch-coordinate recording policy

## Requirements

- HarmonyOS application project with `ohpm` support
- HarmonyOS API 12 or later
- Core SDK and RUM initialization before Replay
- Normalized OHMUrl enabled for the consuming product in project-level `build-profile.json5`:

```json5
{
  "app": {
    "products": [
      {
        "name": "default",
        "buildOption": {
          "strictMode": {
            "useNormalizedOHMUrl": true
          }
        }
      }
    ]
  }
}
```

## Notes

- Native animations, text styles, automatically resized labels, popup placement,
  and material blur may not exactly match the original screen in Replay.
- `RichText` captures text, paragraphs, and basic text styles only. It does not
  capture HTML images, external styles, scripts, or complex Web layouts.
- `PatternLock` replay requires forwarding touch and state changes through
  `recordPatternTouch(...)` and `updatePatternLockState(...)`. Configure
  `TextAndInputPrivacy.MASK_SENSITIVE_INPUTS` and `TouchPrivacy.SHOW` to capture it.
- The package declares no permissions. Its core SDK dependency supplies
  the normal permissions needed for network uploads and monitoring.

## Documentation

- [Core SDK integration](https://github.com/GuanceCloud/datakit-harmonyos/blob/master/ft_sdk/README.md)
- [Hvigor compiler plugin](https://www.npmjs.com/package/@cloudcare/hvigor-ohos-plugin?activeTab=readme)
- [Changelog](https://github.com/GuanceCloud/datakit-harmonyos/blob/master/ft_session_replay/CHANGELOG.md)

## License

- Apache-2.0
