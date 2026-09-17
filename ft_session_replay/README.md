# HarmonyOS Session Replay POC

This HAR implements an ArkUI-to-Android Session Replay collection path with a
bounded in-memory diagnostic stream, durable private-file segments, and an
Android-compatible multipart upload request.

When `FTSessionReplayPOC.start()` is called, it registers the optional core SDK
bridge. RUM View starts and Error reports then capture a Full Snapshot using the
registered ArkUI root and mark their RUM View/Action output with `has_replay`.
Without a registered bridge, the core SDK invokes a NoOp and preserves its
existing behavior.

For a Replay-enabled RUM View, the core also writes Android-aligned View fields:
`records_count` and `sampled_on_reply_error`. They describe the accumulated
Replay records and whether the current session used the error-sampling path.

## Application integration

Use the process-wide `FTSessionReplay` entry point from the optional HAR. It
owns bridge registration; bind the root of the currently visible ArkUI page
after Replay is enabled.

```ts
const replay = FTSessionReplay.getInstance();
replay.init(new FTSessionReplayConfig()
  .setSampleRate(1)
  .setSessionReplayOnErrorSampleRate(0), context.filesDir);

// In an ArkUI page that is currently visible:
replay.registerRoot(this.getUIContext(), 'checkout-root', vp2px(1));

// When this root is no longer visible:
replay.unregisterRoot();

// Explicit global kill switch:
replay.disable();
```

Use `setDelayInit(true)` with `init()` to retain the configuration without
starting Replay; call `start()` only after the user grants consent. The sample
page exposes the same behavior through **Enable/Disable Session Replay** and
disables all capture actions while Replay is off.

Once a sampled RUM View starts, the registered ArkUI root is structurally
polled every 500 ms by default. Unchanged trees do not emit records; changes
produce Android Incremental Snapshot records (`type:11`, `source:0`). Change
the bounded cadence with `setSnapshotIntervalMs(100..10000)`.

When `filesDir` is supplied to `init()` or `enable()`, each capture batch is
atomically persisted below `filesDir/ft_session_replay/segments`. Storage is
bounded to 10 MiB by default and evicts oldest complete segments before writing
new data. Use `setStorageMaxBytes()` and `setMaxRecordsPerSegment()` to tune
the bounds. Private-app storage is durable but not encrypted by this POC.

Call `await replay.flush()` to upload the durable segments. By default, the
uploader reuses the installed core SDK's DataKit or Dataway intake configuration
and sends `v1/write/rum/replay` with Android's `multipart/form-data` contract:
newline-delimited record envelopes are deflate-compressed into the `segment`
file part and include `start`, `end`, `records_count`, RUM linkage, environment,
SDK, and global-context fields. The source is honestly marked `harmonyos`.
It deletes a local segment only after HTTP `200`; unavailable networking and
non-200 responses leave every unacknowledged segment on device for retry. For
a controlled proxy, use `setUploadUrl('https://host/v1/write/rum/replay')`.
Once Replay is enabled, the regular queue is also drained automatically every
15 seconds by default. Use `setUploadIntervalMs(1000..300000)` to change the
interval, or `setUploadIntervalMs(0)` to require explicit `flush()` calls.
Error-sampled data deliberately does not enter this queue until an error occurs.
Network failures, timeouts, `429`, and `5xx` responses are retried with an
exponential delay capped at 60 seconds. A missing endpoint sends no request and
waits 60 seconds before checking again; a successful `200` resets scheduling to
the configured base interval. Other client errors retain data but use the normal
interval, so they remain diagnosable without a tight retry loop.

## ArkWeb Browser Replay integration

`FTWebViewHandler` now exposes the same JavaScript bridge contract as Android
when this optional HAR is enabled: `getPrivacyLevel()` returns `mask` by
default, `getCapabilities()` returns `["records"]`, and Browser SDK events
named `session_replay` enter the regular Replay segment pipeline. Keep
`FTRUMConfig.setEnableTraceWebView(true)` enabled and configure its
`allowWebViewHost` list before loading the Browser SDK page; the Browser SDK
uses that allow-list returned by `getAllowedWebViewHosts()` before sending any
data to native.

Each `FTWebViewHandler` assigns a stable `harmony-web-*` slot ID. Browser
records retain their original rrweb `timestamp`, `type`, and `data`, receive
only that `slotId`, and are enveloped with the configured RUM App ID, current
RUM session, Browser RUM `view_id`, and only explicitly configured
`enableLinkRUMKeys(...)` values. A stale WebView slot remains acceptable for
two seconds after it is cleared, then its records are ignored. For an
error-sampled session, the native bridge requests
`DATAFLUX_RUM.takeSubsequentFullSnapshot()` every ten seconds while its latest
WebView slot remains active.

## Replay resource assets

When a collector creates a Replay record that refers to binary content, queue
that content with `replay.queueResource(context, bytes, mimeType)`. The method
returns a SHA-256 file name suitable for the record reference. Identical bytes
are retained once in `filesDir/ft_session_replay/resources/data`; pending
metadata is scoped by the RUM App ID and `wgt_id`, matching Android's backend
routing. The current conservative ArkUI collector emits masked placeholder
wireframes and therefore does not queue image bytes itself.

`flush()` first performs Android-compatible resource processing: it posts
`{app_id, files, tags}` to `v1/check/rum/replay_assets`, removes assets the
server already has, then uploads only missing files as repeated `files`
multipart parts to `v1/write/rum/replay_assets`. Private assets remain until a
`200` acknowledgement. Use `flushResources()` when validating this phase by
itself. Asset uploads use the same scheduled retry cycle as Replay records.

The generated JSON is compatible with Android's Replay record envelope:

```json
{
  "application_id": "...",
  "session_id": "...",
  "view_id": "...",
  "globalContext": { "wgt_id": "..." },
  "records": [{ "timestamp": 0, "type": 10, "data": { "wireframes": [] } }]
}
```

`type: 10` is Android's Full Snapshot record type. The POC uses only
`placeholder` wireframes, and never reads Inspector data, text values, input
values, or image bytes.

## Manual verification

1. Run the demo on an API 12 or later device, then select **Session Replay POC**.
2. Tap **Capture Full Snapshot**. The page reports the number of collected
   wireframes and displays the serialized payload prefix.
3. Confirm the payload contains `application_id`, `session_id`, `view_id`, a
   `records` array, `type:10`, and a `wireframes` array.
4. Confirm the displayed node labels are only `ArkUI:<component type>` and do
   not include the page's visible text or any input value.

## P2 native record grammar verification

1. On the same page, first tap **Capture through RUM View Bridge**. The payload
   must include records in this order: Meta (`type:4`), Focus (`type:6`), then
   Full Snapshot (`type:10`).
2. Tap **Capture Incremental Mutation**. Confirm the result is `type:11` and
   its data has `source:0` plus one or more `adds`, `removes`, or `updates`.
3. Navigate away after a bridge capture and inspect the latest bridge payload
   or RUM-side diagnostic. The closing record uses Android's View End type
   `7`; it has no payload fields.
4. Do not expect touch positions under default settings: `TouchPrivacy.HIDE`
   suppresses them before serialization. Only an explicit `TouchPrivacy.SHOW`
   configuration enables pointer records (`type:11`, `source:9`).

## P3 sampling and RUM link verification

1. Configure `setSampleRate(0).setSessionReplayOnErrorSampleRate(1)` and open
   the page. The bridge still records the session as error-sampled; with both
   rates set to `0`, it produces no Replay capture.
2. Configure `enableLinkRUMKeys(['wgt_id'])`, add `wgt_id` to the RUM global
   context, then trigger **Capture through RUM View Bridge**. Confirm only
   `wgt_id` appears in `globalContext`; unconfigured RUM fields and tags must
   be absent.
3. Change the configured linked value while staying on the same RUM View and
   trigger the bridge again. Confirm a new Meta, Focus, Full Snapshot sequence
   is produced, rather than appending different context values to one batch.
4. Never configure passwords, tokens, or other secrets as linked keys: selected
   values are intentionally added to the Replay payload for backend correlation.

## P1 bridge verification

1. Configure a non-empty RUM app ID in the demo and open **Session Replay POC**.
2. Tap **Capture through RUM View Bridge**. Confirm the displayed envelope has a
   non-placeholder `application_id`, `session_id`, and `view_id`; record type
   remains `10`.
3. Tap **Capture through RUM Error Bridge**. Confirm it again displays a new
   Full Snapshot without exposing the manual error text in the wireframes.
4. Using the configured RUM intake or a local capture proxy, inspect the RUM
   View and any subsequent Action emitted after either capture. Confirm its
   fields include `has_replay:true`.
5. Return from the page, revisit a normal demo page, and confirm ordinary RUM
   events still work. This verifies unregistering the bridge leaves the core
   SDK on its NoOp path.

## P4 RUM View metadata verification

1. Set `setSampleRate(1)`, configure a RUM app ID, open **Session Replay POC**,
   and trigger **Capture through RUM View Bridge**. Leave the page so the RUM
   View is closed and emitted.
2. Inspect the emitted RUM View through the configured intake, local capture
   proxy, or Studio event detail. It must include `has_replay:true` and a
   positive `records_count` (the initial bridge capture produces at least Meta,
   Focus, and Full Snapshot records).
3. Set `setSampleRate(0).setSessionReplayOnErrorSampleRate(1)`, reopen the
   POC, trigger **Capture through RUM View Bridge**, then **Capture through RUM
   Error Bridge**, and leave the page. Confirm the associated RUM View contains
   `sampled_on_reply_error:true`, a positive `records_count`, and
   `has_replay:true`.
4. Repeat with both sample rates set to `0`. The emitted RUM View must omit
   Replay metadata (`has_replay`, `records_count`, and
   `sampled_on_reply_error`), confirming that the NoOp/sampling path does not
   mark unrelated views.

## P5 global switch verification

1. Open **Session Replay POC**. **Enable Session Replay** must be visible and
   every capture button must be disabled.
2. Enable Replay, then verify all capture buttons become available. Trigger a
   RUM View bridge capture and confirm the usual Android-compatible payload is
   displayed.
3. Tap **Disable Session Replay**. The capture buttons must become disabled;
   attempts to create a new RUM View or Error capture must not be possible from
   the page, and a subsequently emitted RUM View must not receive new Replay
   metadata.
4. Enable Replay again, trigger a RUM View bridge capture, then leave the
   page. Confirm the closed View contains Replay metadata, proving that the
   global switch re-registers the optional core bridge correctly.

## P6 continuous ArkUI observation verification

1. Enable Replay and trigger **Capture through RUM View Bridge** to establish
   the initial Meta, Focus, and Full Snapshot baseline.
2. Do not use **Capture Incremental Mutation**. Instead select **Toggle Layout
   for Automatic Observation** and wait roughly 700 ms (the default 500 ms
   polling interval plus UI settling time).
3. The result must report **Automatic observer captured a structural mutation**.
   Its JSON must contain `type:11` and `source:0`; the buffered-record count
   must be at least four (the three start records plus the observed mutation).
4. Repeat the layout toggle. Each structural change should add one Mutation
   record, while waiting without changing the page must not raise the buffered
   count.
5. Disable Replay, then confirm the automatic-observation button is disabled.
   This verifies the polling timer is stopped with the global switch.

## P7 durable segment verification

1. Enable Replay, trigger **Capture through RUM View Bridge**, then toggle the
   layout once. The sample result must display a positive **durable segments**
   count.
2. Force-stop the application without clearing its data, then start it again.
   Enable Replay and perform another View bridge capture. The durable-segment
   count must include the records written before the restart.
3. Set `setStorageMaxBytes(1024 * 1024)` and repeatedly generate captures.
   Confirm the app remains usable and older segment files are removed once the
   private `ft_session_replay/segments` directory reaches its quota.
4. Verify each retained `*.json` parses to a segment with `version:1`, one
   `context` object, and a non-empty `records` array. No `*.tmp` file may
   remain after restarting the app.

## P8 Replay intake upload verification

1. Configure the demo SDK with a valid DataKit or Dataway endpoint and a RUM
   app ID. Alternatively, configure `setUploadUrl()` with a controlled HTTP
   capture proxy that accepts multipart requests and responds `200`.
2. Enable Replay, use **Capture through RUM View Bridge**, then use **Upload
   Durable Replay Segments**. The result must report one or more acknowledged
   segments and zero (or fewer) durable segments remaining.
3. Inspect the request in the intake or proxy. It must be `POST` to
   `v1/write/rum/replay`, use `multipart/form-data`, include a binary `segment`
   part plus `start`, `end`, `records_count`, `app_id`, `session_id`, `view_id`,
   `env`, `sdk_name`, and `source:harmonyos`. Inflate the `segment` bytes and
   confirm it is newline-delimited JSON with Android-compatible Replay
   envelopes and record types.
4. Make the endpoint unreachable (or have the proxy return `500`), capture a
   new segment, and upload. The page must report a failed acknowledgement and
   retain the same durable segment count. Restore `200` and upload again; the
   retained segments must then be acknowledged and removed.

## P9 automatic upload scheduling verification

1. Configure a working intake or controlled `200` proxy. Initialize Replay
   with `setUploadIntervalMs(1000)` for this test, then create a durable
   segment through the RUM View bridge.
2. Do not tap **Upload Durable Replay Segments**. Wait up to two seconds and
   inspect the proxy or intake: it must receive the same Replay multipart
   request. The durable-segment count must fall after the HTTP `200` response.
3. Configure `setUploadIntervalMs(0)`, create another segment, and wait at
   least two seconds. No automatic request may be sent and the segment must
   remain until the upload button (or `flush()`) is invoked.
4. Return a non-`200` response while automatic upload is enabled. Confirm the
   segment remains locally and that a later timer cycle retries it; after a
   `200` response, it is removed exactly once.

## P10 error-sampled rolling-window verification

1. Initialize Replay with `setSampleRate(0).setSessionReplayOnErrorSampleRate(1)`
and a working intake. Create a RUM View bridge capture but do not report an
error. The POC must display a positive **deferred error segments** count and
no Replay request may reach the intake, even after the automatic upload period.
The closed View must not contain Replay metadata.
2. During a new error-sampled View, wait long enough to create several records,
then trigger **Capture through RUM Error Bridge**. The deferred count must fall
as its latest one-minute window moves to durable segments. The next explicit or
scheduled upload must send those segments; the related RUM View must contain
`has_replay:true`, a positive `records_count`, and
`sampled_on_reply_error:true`.
3. Leave an error-sampled View without an error, restart the application, and
inspect `filesDir/ft_session_replay/error_segments`. It must contain the
deferred JSON segments while `segments` remains unchanged. After one minute of
continued error-sampled recording, older complete deferred segments must be
removed from this directory.
4. Simulate a failed promotion by filling the normal Replay quota, trigger an
   error, and confirm the source deferred segments remain. Free space and trigger
   another error: the retained data must then be promoted and uploaded without
   silently discarding it.

## P11 upload retry and endpoint recovery verification

1. Set `setUploadIntervalMs(1000)`, retain at least one regular durable
   segment, and configure the proxy to return `500`. Verify attempts occur at
   roughly 1, 2, 4, 8 seconds (up to the 60-second cap) and the segment is not
   removed. Repeat with `429` and with a network-disconnected device.
2. Restore a `200` response. The next upload must remove the segment; create a
   second segment and confirm the following scheduled attempt returns to the
   configured one-second base interval rather than the prior backoff delay.
3. Start with no DataKit/Dataway URL and no `setUploadUrl()` override. Confirm
   no HTTP request is made and the durable segment remains. Configure an
   endpoint at runtime, wait up to 60 seconds, and verify the same queue resumes
   without restarting the app.
4. Return `400` from the proxy. Confirm the segment remains for diagnosis but
   attempts use the normal configured interval instead of the exponential
   backoff cadence.

## P12 ArkWeb Browser Replay verification

1. In the demo `EntryAbility` (or a test application startup path), initialize
   Replay with `FTSessionReplay.getInstance().init(new
   FTSessionReplayConfig().setSampleRate(1), this.context.filesDir)`. Configure
   a non-empty RUM App ID, enable WebView tracing with
   `setEnableTraceWebView(true)`, and configure `setAllowWebViewHost([...])`
   to include the test page host. Then open the demo's **WebView Test** page
   loading a Browser SDK page with Session Replay enabled. Initializing at app
   startup is important: the POC page's Enable/Disable control is intentionally
   scoped to its own ArkUI-root demonstration.
2. In WebView DevTools or the page's diagnostic console, verify
   `window.FTWebViewJavascriptBridge.getAllowedWebViewHosts()` returns the
   configured JSON host list, `getPrivacyLevel()` returns `mask` with the
   default Replay configuration, and `getCapabilities()` returns
   `["records"]`. Change the host to one outside the allow-list and confirm
   the Browser SDK sends neither RUM nor Replay data through the native bridge.
3. Generate a Browser full snapshot and an interaction. Inspect the controlled
   Replay intake request after calling `flush()` (or waiting for automatic
   upload). Inflate its `segment` part and confirm the Browser records keep
   their rrweb `type`/`data` structure, carry a non-empty `slotId` beginning
   `harmony-web-`, and are enveloped with the Browser RUM `view_id`, current
   session ID, and RUM App ID. They must not be converted into ArkUI
   `wireframes`.
4. Configure `enableLinkRUMKeys(['order_id'])`, attach that value to Browser
   RUM data, and generate another Browser Replay record. Confirm only
   `order_id` is included in the Replay envelope's `globalContext`; an
   unconfigured Browser tag/field must not appear.
5. Navigate away from the WebView, then cause the page to emit a delayed
   `session_replay` message within two seconds and another after more than two
   seconds. The former may be persisted; the latter must be ignored. Reopen or
   rebind the WebView and confirm a new active latest slot resumes recording.
6. Configure `setSampleRate(0).setSessionReplayOnErrorSampleRate(1)`. While
   the WebView is active, observe its page hook or DevTools for
   `DATAFLUX_RUM.takeSubsequentFullSnapshot()` roughly every ten seconds.
   Navigate away and confirm those calls stop. Before a RUM Error, Browser
   Replay remains in `error_segments`; after an Error it promotes and uploads
   with the same rolling-window behavior documented in P10.

## P13 Replay resource asset verification

1. In a test startup path, initialize Replay with a private `filesDir` and a
   valid DataKit/Dataway endpoint. Construct the same `SessionReplayContext`
   used by a recorded View and call `queueResource(context, new Uint8Array([1,
   2, 3, 4]), 'image/png')` twice. Both calls must return the same 64-character
   SHA-256 file name, and `getStoredResources()` must contain one pending
   resource for that `wgt_id` route.
2. With a controlled proxy, return `200` from
   `v1/check/rum/replay_assets` with `{"content":{"<hash>":true}}`. Call
   `flushResources()` and confirm no upload request follows, the pending asset
   is removed, and its private `resources/data/<hash>.bin` file is deleted when
   no other route references it.
3. Queue the asset again. This time return
   `{"content":{"<hash>":false}}` from the check request, then return `200`
   from `v1/write/rum/replay_assets`. Confirm the check body contains `app_id`,
   `files:["<hash>"]`, and `tags` when linked context is configured. Confirm
   the upload is multipart with `app_id`, serialized `tags`, and a `files` part
   named exactly by the hash with the original four bytes and MIME type.
4. Return `500` or disconnect the proxy during either check or upload. The
   resource metadata and binary file must remain. Restore `200` and wait for
   the scheduled drain (or call `flushResources()`); the same hash must be
   checked/uploaded again and then removed exactly once.
5. Queue the same bytes under a different `wgt_id`. Confirm the local byte file
   is still deduplicated, but the proxy receives a separate check/upload group
   with that route's `tags`. This verifies that backend asset routing is not
   accidentally shared across workspaces.
