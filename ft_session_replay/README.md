# HarmonyOS Session Replay POC

This HAR validates an ArkUI-to-Android Session Replay protocol path. It does not
persist or upload records yet.

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
