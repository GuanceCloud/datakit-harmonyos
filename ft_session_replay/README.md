# Guance Session Replay for HarmonyOS

`@guancecloud/ft_session_replay` records ArkUI pages and supported ArkWeb content alongside RUM Views and Errors from `@guancecloud/ft_sdk`. It stores sampled replay data in the application's private files directory and uploads it through the SDK's configured DataKit or Dataway endpoint.

## Install

Install the Replay HAR in the application's HAP module:

```sh
ohpm install @guancecloud/ft_session_replay
```

The Replay package is a bytecode HAR and requires HarmonyOS API 12 or later. Enable normalized OHMUrl for the consuming product in the project-level `build-profile.json5`:

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

Replay uses `@guancecloud/ft_sdk` for RUM session, View, Error, and upload context. The optional `@cloudcare/hvigor-ohos-plugin` automates ArkUI page-root registration; without it, applications register the visible root through the Replay API.

## Configure and start

After the application's RUM setup is complete, initialize Replay with its configuration and an application-private `filesDir`:

```ts
import { FTSessionReplay, FTSessionReplayConfig } from '@guancecloud/ft_session_replay'

function initializeReplay(filesDir: string): void {
  FTSessionReplay.getInstance().init(
    new FTSessionReplayConfig().setSampleRate(0.1),
    filesDir
  )
}
```

`setSampleRate(0.1)` records approximately 10% of sessions; use a value from `0` to `1`. To wait for consent or remote configuration, add `.setDelayInit(true)` to the Replay configuration and call `FTSessionReplay.getInstance().start()` when recording may begin. Call `disable()` to stop collecting new replay data.

To retain a recent replay only when an error occurs, set the regular sample rate to `0` and configure `setSessionReplayOnErrorSampleRate(rate)`. Error-sampled data is held locally for a one-minute pre-error window and enters the upload queue only after a matching RUM Error.

## Page updates

With the Hvigor plugin enabled, pages do not need individual `registerRoot()` calls. The plugin reports page visibility and root layout changes. If a page root already has its own `onAreaChange` or `onTouch` callback, keep that callback and call `FTSessionReplay.getInstance().notifyPageChanged()` or `notifyScroll()` from it when appropriate. Also call `notifyPageChanged()` after visual state changes that do not change the root's size. Use `notifyTransition()` for custom transitions and animations; Replay collects a settled frame after motion.

Without the plugin, give the visible ArkUI root an `.id()`, then call `registerRoot(this.getUIContext(), rootId, vp2px(1))` after it is laid out. Call `unregisterRoot()` when the page is hidden. Do not combine manual root registration with the plugin's automatic registration for the same page.

When `start()` is called after a page is already visible, Replay attaches to the current RUM View and records its first snapshot once the root is available. The session and View IDs stay the same; recording begins at the time Replay is enabled. RUM receives `has_replay` and the record count after capture succeeds.

## Privacy and images

The defaults mask all text and images and hide touch coordinates. Change these settings only for data that your application is allowed to record:

```ts
import {
  FTSessionReplayConfig,
  TextAndInputPrivacy,
  ImagePrivacy,
  TouchPrivacy
} from '@guancecloud/ft_session_replay'

const config = new FTSessionReplayConfig()
  .setTextAndInputPrivacy(TextAndInputPrivacy.MASK_SENSITIVE_INPUTS)
  .setImagePrivacy(ImagePrivacy.MASK_NONE)
  .setTouchPrivacy(TouchPrivacy.HIDE)
```

`MASK_SENSITIVE_INPUTS` retains ordinary page text while masking inputs identified as sensitive. `MASK_ALL_INPUTS` masks every input. `TouchPrivacy.SHOW` records pointer positions. Review visible text and image content before relaxing the defaults. `enableLinkRUMKeys([...])` adds only the selected RUM context keys to Replay; do not select secrets or personal data.

The ArkUI collector can include image bytes from a data URI. For other images, register the bytes with `FTSessionReplay.getInstance().registerImageAsset(componentIdOrSource, bytes, mimeType)` before their next snapshot and unregister them when they are no longer needed. It cannot obtain arbitrary bundle, file, or network image pixels from an ArkUI `FrameNode`.

## Upload and storage

Passing the application's private `filesDir` to `init()` enables durable storage. Replay uses the core SDK's configured DataKit or Dataway endpoint and schedules an upload every 15 seconds by default. Segments remain on the device until the server acknowledges them. The default storage limit is 10 MiB; older segments are removed when that limit is reached. Data in the application's private files directory is not encrypted by this package.

Use `await FTSessionReplay.getInstance().flush()` to upload pending data immediately. `setUploadIntervalMs(0)` disables scheduled uploads and leaves uploading to explicit `flush()` calls. `setUploadUrl(url)` overrides the Replay upload endpoint when a separate route is required.

`disable()` stops new collection immediately and lets accepted snapshots, their image resources, and the final View End finish writing. With scheduled uploads enabled, the SDK then flushes the remaining data and retries failed uploads until the queue is empty. Calling `disable()` again does not cancel this draining. With `setUploadIntervalMs(0)`, call `flush()` explicitly after stopping. Calling `disable()` is sufficient when stopping Replay; do not call `unregisterRoot()` first, because root removal invalidates frames associated with a page transition.

With core SDK diagnostic logging enabled, filter for `FTSessionReplayBridge`. The logs report the attached session/View, first-snapshot result, and both scheduled and manual upload results (`code`, `attemptedSegments`, `uploadedSegments`, `remainingSegments`, and `retryable`). A successful result with zero uploaded segments means the queue was empty, not that a new recording was uploaded. Upload diagnostics do not include endpoint tokens or snapshot contents.

ArkWeb Replay uses the active Browser RUM View supplied through the core SDK's WebView bridge. Browser replay records follow the same storage and upload schedule as ArkUI records.

## Playback fidelity

ArkUI Replay reconstructs a visual view from component properties rather than screen pixels. Inherited text colors and automatically resized long button labels may currently appear differently in playback.
