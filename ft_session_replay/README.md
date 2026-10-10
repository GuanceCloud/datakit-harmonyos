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

With the Hvigor plugin enabled, pages do not need individual `registerRoot()` calls. The plugin reports page visibility and root layout changes and forwards real touch events while preserving existing root `onTouch` callbacks. Replay observes ArkUI drawing and samples visual changes every 32 ms by default, including scrolling, Swiper movement, translation, and opacity changes. `setSnapshotIntervalMs(...)` controls that interval (minimum 16 ms). `notifyPageChanged()` remains available for explicit updates and as a fallback when drawing observation is unavailable. `notifyScroll()` and `notifyTransition()` keep capturing through motion and its final state; they do not postpone every snapshot until motion stops.

Automatic registration combines the registered native page roots so outgoing and incoming pages can appear together during a route animation. It preserves page-stack drawing order on both push and pop. The plugin also observes `PageTransitionEnter`/`PageTransitionExit` progress and their `slide`/`opacity` modifiers, preserving existing callbacks, to reconstruct these effects when native geometry exposes only the animation target. Pages without `pageTransition()` get an effect-free observer at the real default Router animation start. Replay prefers native intermediate positions; target-only geometry uses a bounded approximation of the default spring, with half-page foreground travel and 20% background travel in left-to-right layouts. Right-to-left layouts use the corresponding page travel ratios from the system-language direction. This changes recorded geometry only. A disposed default outgoing page can continue through that bounded reconstruction window; it is then released. Without start metadata or actual exit progress, unreadable outgoing frames are discarded. Completion removes the page from the recording scene even while the successor is waiting for layout, and an empty scene keeps its existing canvas instead of recapturing an exited root. Page removal and the final motion frame stay in the ordered Worker queue even when processing takes over one second, using Mutation when the checkpoint and viewport remain valid. Accepted snapshots retain their original RUM View and finish writing before that View's end, even if the next page has already appeared.

Without the plugin, give the visible ArkUI root an `.id()`, then call `registerRoot(this.getUIContext(), rootId, vp2px(1))` after it is laid out. To compose separate Router pages, pass `true` as the fourth argument and their root IDs in native drawing order as the fifth argument. Internal Page/Stage containers are not accessible through `FrameNode.getParent()`. Forward root `.onTouch` events to `recordTouchEvent(event)`; ArkUI event coordinates are already in window-relative vp units. If a child stops touch-event bubbling, forward its events explicitly too. The lower-level `recordTouch(...)` API continues to accept physical-pixel coordinates. Call `unregisterRoot()` when collection should detach. Do not combine manual root registration with the plugin's automatic registration for the same page.

When `start()` is called after a page is already visible, Replay attaches to the current RUM View and records its first snapshot once the root is available. The session and View IDs stay the same; recording begins at the time Replay is enabled. After capture is committed, native RUM Views, Actions, Resources, Long Tasks, and Errors associated with that View report the boolean field `session_has_replay=true`, which the console uses for Replay entry points. Views and Actions also retain `has_replay=true` for compatibility, and Views report the record count. The console's aggregated Session entry continues to use `has_replay`.

`session_has_replay` is reserved SDK metadata: custom properties and global custom context cannot override it or add it to these native RUM records without Replay metadata. It is omitted when Replay is unavailable. The local database continues to store Replay metadata under `has_replay`; this upload-field addition does not rename cached metadata or change sampling and capture timing.

The first snapshot may finish after an Action or request starts. Its committed metadata updates matching active and queued Actions, retained Resource contexts, and queued Errors. The same database command also persists availability on the original View and its stored Actions in one transaction. Action cache reads and writes preserve their own Replay marker, so deleting a closed View or disabling Replay cannot remove committed availability from an Action that is still waiting to be reported. Actions, Resources, and Errors recheck their original application's session and View before dispatch; restored pending Resources and recovered crashes also read their original stored View. A later page or session cannot supply that metadata. Action, Resource, Long Task, and Error events already dispatched before Replay becomes available are not retroactively updated.

A completed Action without Replay metadata waits before serialization while its original View has accepted Replay work still in progress. The first committed frame supplies `session_has_replay` before dispatch, even if the page has already changed. Ready Actions from other Views continue to dispatch, and Actions with committed Replay do not wait for subsequent animation frames. If capture fails, the Action reports without Replay metadata. Views with no pending capture add no wait. Waiting preserves the Action's original timestamp, ID, and View association, and resumes from completion signals rather than repeated polling. SDK diagnostics identify this wait with `Completed Actions waiting for Replay`.

Once captured, a View's first snapshot is retained even if it waits more than one second or the page closes. It commits with its original View ID before that View's end record. Intermediate sampling snapshots still expire after waiting over one second; accepted page-removal and settled-motion frames are retained. A page that closes before its root can be captured remains unavailable for Replay. Core SDK diagnostics report root readiness or exhausted layout retries, the View waiting for its root, first-frame enqueue and save, and total first-frame processing latency (`elapsedMs`). When automatic RUM View tracking is enabled, avoid also calling `startView()` in that page's `aboutToAppear()`; the two lifecycle paths create separate View IDs for the same visit.

The core SDK keeps a closed View's aggregate until accepted Replay writes and their RUM metadata updates finish, including when recording stops during a page transition. If an earlier summary was cached without Replay, a newer summary reports `session_has_replay` and the final record count before cleanup. A failed capture releases the aggregate without reporting unavailable Replay. Open Views continue to report while capture is in progress.

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

`MASK_SENSITIVE_INPUTS` retains ordinary page text while masking inputs identified as sensitive. `MASK_ALL_INPUTS` masks every input. `TouchPrivacy.SHOW` records each finger's down/move/up positions; cancellation and View end close active pointers. `TouchPrivacy.HIDE` suppresses coordinates while visual animation recording continues. Review visible text and image content before relaxing the defaults. `enableLinkRUMKeys([...])` adds only the selected RUM context keys to Replay; do not select secrets or personal data.

The ArkUI collector can include image bytes from a data URI. For other images, register the bytes with `FTSessionReplay.getInstance().registerImageAsset(componentIdOrSource, bytes, mimeType)` before their next snapshot and unregister them when they are no longer needed. It cannot obtain arbitrary bundle, file, or network image pixels from an ArkUI `FrameNode`.

## Upload and storage

Passing the application's private `filesDir` to `init()` enables durable storage. Replay uses the core SDK's configured DataKit or Dataway endpoint and schedules an upload every 15 seconds by default. Segments remain on the device until the server acknowledges them. The default storage limit is 10 MiB; older segments are removed when that limit is reached. Data in the application's private files directory is not encrypted by this package.

Use `await FTSessionReplay.getInstance().flush()` to upload pending data immediately. `setUploadIntervalMs(0)` disables scheduled uploads and leaves uploading to explicit `flush()` calls. `setUploadUrl(url)` overrides the Replay upload endpoint when a separate route is required.

`disable()` stops new collection immediately and lets accepted snapshots, their image resources, and the final View End finish writing. With scheduled uploads enabled, the SDK then flushes the remaining data and retries failed uploads until the queue is empty. Calling `disable()` again does not cancel this draining. With `setUploadIntervalMs(0)`, call `flush()` explicitly after stopping. Calling `disable()` is sufficient when stopping Replay.

With core SDK diagnostic logging enabled, filter for `FTSessionReplayBridge`. The logs report the attached session/View, first-snapshot result, and both scheduled and manual upload results (`code`, `attemptedSegments`, `uploadedSegments`, `remainingSegments`, and `retryable`). A successful result with zero uploaded segments means the queue was empty, not that a new recording was uploaded. Upload diagnostics do not include endpoint tokens or snapshot contents.

ArkWeb Replay uses the active Browser RUM View supplied through the core SDK's WebView bridge. Browser replay records follow the same storage and upload schedule as ArkUI records.

## Playback fidelity

ArkUI wireframes retain each node's original position and measured size. Viewport and ancestor clipping is carried separately in Android-compatible `clip` insets (`top`, `right`, `bottom`, `left`), in the same Replay coordinates as geometry. Attached, visible native nodes remain in the snapshot while fully clipped, subject to the configured node limit. Moving back into view uses position and clipping updates; an unclipped node has four zero insets, so a clearing Mutation and the latest Full Snapshot agree without replacing the node.

Node reordering retains the largest set of nodes whose relative draw order is already correct, replacing only moved or visually incompatible nodes. Unchanged nodes do not emit empty Mutation updates. Automatic capture uses the Worker's last committed checkpoint and viewport, including after manual snapshots, so queued frames from an outgoing View do not repeatedly create Full Snapshots because the active page has changed. New Views, actual viewport changes, periodic checkpoints, Worker recovery and cache trimming still require Full Snapshots. This reduces unnecessary records on the existing mobile playback path; Studio's handling of a necessary Mutation update determines whether its DOM node is reused.

Automatic page scenes use the hosting window's drawable bounds, with one shared origin for geometry and touches. Before window metrics are available, one registered page supplies a stable fallback; the moving union of pages never determines the canvas size. `recordViewportResize(width, height)` refreshes the native bounds and uses the captured viewport for its resize record and Full Snapshot when capture succeeds. Physical-pixel arguments are a fallback when capture is unavailable; synthetic test dimensions do not change the persistent scene bounds. Slide distance follows each page's original size during its transition. Incoming and outgoing page instances retain their native node IDs. Automatic Router page stacking follows each page's stack index captured on page show, with instance creation order as a fallback, so a recreated returning page stays below the outgoing page during Pop.

Each top-level page scene has a separate backing surface using the collector's default white page color, so transparent application containers do not expose the previous page through their content gaps. The backing moves, fades and clips with its page, while application background colors remain intact. Page-local z-index values are ordered within separate page layers; outgoing controls cannot cross above an incoming page merely because they have a larger local z-index. Releasing an outgoing page preserves the successor's layer and node IDs. The default backing color remains an approximation when an application uses a different native page or window background.

The SDK observes Router and Navigation lifecycle signals in the registered UIContext. On runtimes exposing `NavDestinationInfo.uniqueId` (API 15+), Navigation destinations are captured separately within their host page, preserving outgoing/incoming overlap and Push/Pop paint order. The optional compiler plugin supplies actual progress for supported explicit Router transitions and start metadata for default Router reconstruction. Outgoing pages keep bounded, temporary detached data in memory if their FrameNode disappears; the usual Worker privacy processing still happens before persistence. Completion releases the outgoing instance and refreshes the recording scene together, so a disposed page cannot reappear from its detached cache. A watchdog bounds interrupted explicit transitions. Default reconstruction ends after 450 ms; Router pages with neither progress nor default start metadata retain the one-second lifecycle grace period without reusing unreadable frames.

When a new View's first frame is queued, drawing observation continues immediately while the Worker saves that frame. Later captures follow its start checkpoint in the same queue, preventing the initial write from delaying transition capture.

Samples captured inside the bounded default Router reconstruction window remain in the ordered Worker queue even when processing takes over one second. They retain their original timestamps and View context, so a delayed write cannot collapse the entry to its start and end frames. Ordinary snapshots outside that window continue to expire normally.

For custom Navigation animations, forward actual animation progress with `updateNavigationTransition(uniqueId, entering, progress, slide?, opacity?)`, then call `finishNavigationTransition(uniqueId)` from the completion or cancellation callback. Custom Router integrations can use `updatePageTransition(rootId, entering, progress, slide?, opacity?)` and `finishPageTransition(rootId)`. These methods observe the application's animation and do not change it. Lifecycle observers alone do not expose a universal per-frame progress value for system animations; effects whose public geometry exposes only a final value remain a playback limitation.

ArkUI Replay reconstructs a visual view from component properties rather than screen pixels. Inherited text colors and automatically resized long button labels may currently appear differently in playback.

Animation fidelity depends on the capture interval and the properties exposed by ArkUI. Render Service implicit animations can expose only their final property values to public FrameNode queries. Default Router reconstruction uses a 450 ms approximation based on ArkUI's default spring; platform quick-push timing, animation-speed settings, native page clipping, and foreground masks can differ. Existing `pageTransition()` methods are preserved and use their explicit progress hooks, including zero-duration effects. The page-transition progress hooks compensate for explicit left/right/top/bottom slides and opacity; other native effects, including arbitrary `animateTo`, scale, custom translation and spring effects, require device/playback validation and are not guaranteed to retain every intermediate frame.

For manual checks, open **Session Replay Demo**, enable recording, drag in the touch pad, scroll the page and swipe the Swiper. Use **Animate Translation and Fade**, then **Open Animated Replay Page** and **Return with Animation**. Also use **Default Router Transition** and **Return with Default Animation** to exercise pages without explicit transition effects. Upload the recording and compare its pointer positions, intermediate frames, page overlap and final state in Studio.

For clipping checks, scroll or swipe until a text/button/image is partially and then fully outside its viewport, and move it back. Its size and text alignment should remain stable; clipping should disappear when the node is fully inside. During a page transition, both pages should keep their original layout while their visible regions change. In exported records, inspect `clip` updates and their four-zero reset rather than repeated geometry shrinking or node removal/addition caused only by clipping.

For checkpoint/order checks, rapidly navigate forward and back, reorder a list, and alternate manual snapshots with automatic recording. Within a single View at a stable viewport, moving frames should use Mutation between checkpoints. Rotating `[A,B,C,D]` to `[D,A,B,C]` needs one removal/addition pair for D; unchanged siblings should remain. Rotate the device or restart recording separately to check that a required Full Snapshot is still emitted.

For page-scene checks, compare push and pop at the start, 25%, 50%, 75% and end of the real animation. Check original page sizes, travel distance, overlap, clipping, touch alignment and which page stays on top. Include an explicit transition lasting longer than one second, an outgoing page that detaches early, a recreated returning page, repeated instances of the same Router page, a Navigation push/pop, and a real window resize. The outgoing page should disappear at completion; a stable window should not produce resize checkpoints because pages move. On a portrait device, the Demo's **Emit Viewport Resize Signal** button supplies synthetic landscape dimensions; with an available native root, the recording must keep the actual portrait viewport. Check subsequent scrolling and navigation too. Start a new recording when validating this fix, since previously uploaded records retain their original dimensions and page contents.

## Regression checks

Run the `entry` module's `ohosTest` tests on a device from DevEco Studio, with the Hvigor Replay transform enabled and automatic RUM View tracking configured. [SessionReplayMutationUITest](../entry/src/ohosTest/ets/test/SessionReplayMutationUITest.test.ets) is registered in the [entry test suite](../entry/src/ohosTest/ets/test/List.test.ets). Its eight cases cover fixed-size text changes, native node reordering, mixed manual/automatic snapshots, real swipe coordinates, Swiper movement, translation and opacity, and default/explicit Router push/pop. The suite applies emitted Full Snapshot and Mutation records to a reference state and compares the result with a fresh native snapshot. It uses a separate private cache directory and disables scheduled uploads.

The Replay module's [unit test suite](src/test/List.test.ets) covers protocol mutations and privacy, collector geometry and clipping, page-scene composition, Worker checkpoint ordering and recovery, and storage trimming and error-window promotion. Run these tests through DevEco Studio's unit-test runner.

For upload validation, configure a real DataKit or Dataway endpoint, start a new recording in **Session Replay Demo**, exercise the controls above, and select **Upload Durable Replay Segments**. Verify that matching native RUM events report `session_has_replay=true` only after a frame is committed, including an Action completed during a delayed first write and a Resource completed after leaving its original View. Check the original session/View IDs and confirm that a later page cannot supply another View's Replay availability. Inspect the recording in Studio for pointer alignment, intermediate frames, page overlap, clipping, and final state. Device test results alone do not verify HTTP delivery, backend ingestion, or Studio rendering.
