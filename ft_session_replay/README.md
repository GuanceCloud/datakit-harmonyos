# HarmonyOS Session Replay POC

This HAR validates an ArkUI-to-Android Session Replay protocol path. It does not
persist or upload records yet.

When `FTSessionReplayPOC.start()` is called, it registers the optional core SDK
bridge. RUM View starts and Error reports then capture a Full Snapshot using the
registered ArkUI root and mark their RUM View/Action output with `has_replay`.
Without a registered bridge, the core SDK invokes a NoOp and preserves its
existing behavior.

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
