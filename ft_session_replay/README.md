# HarmonyOS Session Replay POC

This HAR validates an ArkUI-to-Android Session Replay protocol path. It keeps a
bounded in-memory record stream per View but does not persist or upload records
yet.

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
  .setSessionReplayOnErrorSampleRate(0));

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
