# ft_sdk

Guance HarmonyOS core SDK for application monitoring, analytics, logging, and tracing.

## Introduction

`@guancecloud/ft_sdk` is the core Guance HarmonyOS SDK. It provides RUM, logging, tracing, common network tracking helpers, and related monitoring capabilities for HarmonyOS applications.
Native crash monitoring is optional and lives in `@guancecloud/ft_native`.

## Features

- Real User Monitoring (RUM)
- Log collection
- Distributed tracing
- Performance and lifecycle monitoring
- HarmonyOS application integration

## Package

- Name: `@guancecloud/ft_sdk`
- License: `Apache-2.0`

## Installation

```bash
ohpm install @guancecloud/ft_sdk
```

Short form:

```bash
ohpm i @guancecloud/ft_sdk
```

## Import

```ts
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceManager,
  FTTraceRequestContext,
  EnvType,
  SDKLogLevel,
  TraceType
} from '@guancecloud/ft_sdk/Index'
```

## Quick Start

Initialize the SDK in `UIAbility.onCreate` as early as possible:

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import type Want from '@ohos.app.ability.Want'
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceManager,
  FTTraceRequestContext,
  EnvType,
  SDKLogLevel,
  TraceType
} from '@guancecloud/ft_sdk/Index'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
      .setEnv(EnvType.PROD)
      .setServiceName('your_service_name')

    FTSDK.install(sdkConfig, this.context)

    const rumConfig = new FTRUMConfig()
      .setRumAppId('YOUR_RUM_APP_ID')
      .setSessionSamplingRate(100)
      .setSessionOnErrorSamplingRate(0)
      .setEnableTraceUserView(true)
      .setEnableTraceUserAction(true)
      .setEnableTraceUserResource(true)
      .setEnableTrackAppCrash(true)

    const loggerConfig = new FTLoggerConfig()
      .setLogSamplingRate(100)
      .setEnableCustomLog(true)
    const traceConfig = new FTTraceConfig()
      .setTraceSamplingRate(100)
      .setEnableAutoTrace(true)
      .setTraceType(TraceType.DDTRACE)

    FTSDK.installRUMConfig(rumConfig)
    FTSDK.installLogConfig(loggerConfig)
    FTSDK.installTraceConfig(traceConfig)
  }
}
```

### Network Resource status

Native network auto-tracking reports `resource_status=0` when no HTTP response is received (for example, timeout or connection failure). The final Resource and its associated Network Error retain this value. Zero has no `resource_status_group`; real HTTP responses retain their status and existing `2xx`/`4xx`/`5xx` grouping. The full URL path remains in `resource_url_path`; only `resource_url_path_group` normalizes numeric segments.

Following the existing SDK contract, a collected Resource generates one linked Network Error for HTTP status >=400, or for status 0 with a non-empty error stack. A manually supplied status 0 without an error stack does not alone create an Error. Auto-tracking supplies the failure message and stack (or the available platform failure description), and links both records through `resource_id`.

### Resource transport fields

Resource records can also report request size, negotiated HTTP protocol, and
connection reuse as Fields. RCP platform values take precedence; RCP, Axios,
and NetworkKit HTTP Chain integrations can supply explicit values when the
platform does not expose them.

For manual reporting, use `ResourceParams.setRequestBodySize(...)`,
`setRequestHeaderSize(...)` or `setRequestSize(...)`, `setHttpProtocol(...)`, and
`setConnectionReuse(...)`. Byte counts must be non-negative safe integers.
Protocol aliases are normalized; unknown protocol/reuse values remain absent.
These reserved measurements cannot be replaced through generic properties or
global tags.

### Resource network snapshots

Automatically tracked RCP, NetworkKit HTTP Chain and Axios requests, and manual
Resources started with `startResource`, include network information without
additional configuration. It reflects the network at request start,
even if the network changes before the request completes.

| Resource Field | Description |
| --- | --- |
| `network_available` | Whether a network is available. |
| `network_validated` | Whether the system has confirmed Internet connectivity. |
| `network_downlink_kbps` | Estimated downlink bandwidth in kb/s. |
| `network_uplink_kbps` | Estimated uplink bandwidth in kb/s. |
| `network_signal_strength` | Signal level: Wi-Fi 0–4, cellular 0–5; not dBm. |

Fields unavailable from the system are omitted. When no network is available,
only `network_available=false` is recorded.

### Filter local Network Errors

`FTNetworkErrorHandler` can suppress only the Error derived from a local
transport failure. It is called only when the request has no HTTP response, so
HTTP 4xx and 5xx Resources keep their existing Error behavior.

```ts
import {
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkErrorKind,
  FTNetworkResourceFields
} from '@guancecloud/ft_sdk/Index'

class LocalFailureFilter implements FTNetworkErrorHandler {
  onExceptionWithFilter(
    context: FTNetworkErrorContext,
    resourceFields: FTNetworkResourceFields
  ): boolean {
    resourceFields['network_failure_kind'] = context.kind
    resourceFields['network_failure_code'] = String(context.errorCode || '')
    return context.kind === FTNetworkErrorKind.TIMEOUT ||
      context.kind === FTNetworkErrorKind.CANCELED
  }
}

const networkErrorHandler = new LocalFailureFilter()
```

Configure it once on `FTRUMConfig` to make it the default for automatic RCP,
Axios, and NetworkKit HTTP collection. This mirrors Android's global
`setOkHttpResourceContentHandler(...)` configuration while applying to all
HarmonyOS automatic network integrations:

```ts
const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTraceUserResource(true)
  .setNetworkErrorHandler(networkErrorHandler)

FTSDK.installRUMConfig(rumConfig)
```

An individual automatic collection entry point can override that default:

```ts
// RCP
const session = rcp.createSession(createFTRCPTrackConfig({ networkErrorHandler }))

// Axios compatibility interceptor
applyFTAxiosTrack(axiosClient, { networkErrorHandler })

// NetworkKit HTTP interceptor chain (from @guancecloud/ft_sdk_ext)
applyFTHttpTrack(httpRequest, { networkErrorHandler })
// or: createFTHttpInterceptorChain({ networkErrorHandler })
```

An explicit handler has priority over the `FTRUMConfig` default. Pass
`networkErrorHandler: null` on a Session, Axios Client, or NetworkKit chain to
keep the global default configured for the app but opt that integration out.

The context includes the URL, method, source (`rcp`, `http_chain`, or `axios`),
original failure value, optional platform error code, message, stack, and a
portable kind: `dns`, `timeout`, `canceled`, `certificate`, `connection`, or
`unknown`. Returning `true` keeps the Resource lifecycle intact, including its
duration, status `0`, error details, and callback fields, then suppresses only
the linked `network_error`. It never changes the business request result or
replaces its thrown error.

Returning `false`, omitting the handler, or throwing from the handler retains
the default behavior. A callback exception is logged in a controlled manner and
is treated as `false`. Callback fields pass through the normal `DataModifier`
flow, but SDK-owned Resource, session, view, and action keys are ignored.

The **HTTP Interceptor Test** demo page has a Local Error Filter switch and
RCP, NetworkKit, and Axios actions that use an unused loopback port. With the
switch on, verify one status-0 Resource with `demo_network_error_*` fields and
no linked Error; with it off, verify the linked Error returns. Both switch
positions override the application's global handler explicitly. Existing 404
actions must keep their Resource and Error in either mode.

### Filter automatically tracked Resources

Use `FTRUMConfig.setResourceUrlHandler(...)` to exclude URLs from automatically tracked RCP, Axios, and NetworkKit HTTP Resources. The handler follows the Android contract: return `true` to skip Resource collection and `false` to collect. It does not affect Trace header injection or manually reported Resources.

```ts
class ResourceUrlFilter extends FTInTakeUrlHandler {
  public isInTakeUrl(url: string): boolean {
    return url.startsWith('https://telemetry.example.com/');
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserResource(true)
  .setResourceUrlHandler(new ResourceUrlFilter());
```

### Stop automatic Axios tracking

Register tracking when initializing the Axios client, after SDK initialization
and before sending requests:

```ts
const registration = applyFTAxiosTrack(axiosClient)
```

For a page- or feature-specific client, call `dispose()` in its cleanup method
(for example, the page's `aboutToDisappear()`) when tracking is no longer needed:

```ts
registration.dispose()
```

Keep tracking active for an app-wide shared client and across individual requests.
After SDK shutdown and reinitialization, call `applyFTAxiosTrack(...)` again.

## Read the Installed Log Configuration

`FTSDK.getLogConfig(): FTLoggerConfig | null` returns the current configuration
instance installed through `FTSDK.installLogConfig(...)`. It returns `null`
before a successful log installation, including after SDK reset or before logs
are configured again following SDK reinstallation.

The returned object is shared with the logging module. After changing settings,
pass it to `installLogConfig(...)` again to synchronize the logging context and
Workers while preserving the other settings:

```ts
const logConfig = FTSDK.getLogConfig()
if (logConfig !== null) {
  FTSDK.installLogConfig(logConfig.setEnableWebViewLog(true))
}
```

## Print Custom Logs to Console

`FTLoggerConfig.setPrintCustomLogToConsole(true)` also prints custom logs sent
through `FTLogger.logBackground(...)` to HiLog. It defaults to `false`. Enable
custom logging and SDK debug output as shown below; output levels follow
`FTSDKConfig.setSdkLogLevel(...)`.

```ts
const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDebug(true)
  .setSdkLogLevel(SDKLogLevel.D)
FTSDK.install(sdkConfig, this.context)

const loggerConfig = new FTLoggerConfig()
  .setEnableCustomLog(true)
  .setPrintCustomLogToConsole(true)
FTSDK.installLogConfig(loggerConfig)
```

This setting does not require the Hvigor plugin or enable automatic console/HiLog
collection (`setEnableConsoleLog(...)`). It does not apply to `FTLogger.d(...)`,
`i(...)`, `w(...)`, `e(...)`, or `batchLog(...)`.

## Hvigor Compiler Plugin

The Guance Hvigor compiler plugin provides automatic console/HiLog collection and cold-launch lifecycle tracking. `FTLoggerConfig.setEnableConsoleLog(...)` controls automatic application-console collection; `setEnableCustomLog(...)` remains independent and controls only manual `FTLogger` calls.

### Install the Hvigor Plugin

Install `@cloudcare/hvigor-ohos-plugin` in the project-level `hvigor/hvigor-config.json5`. This build-time tool package is separate from the `@guancecloud/ft_sdk` runtime HAR. Register it in the HAP module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@cloudcare/hvigor-ohos-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

The plugin instruments application code in `src/main/ets` without rewriting source files on disk or SDK dependencies. Each build also embeds the installed plugin version into `sdk_pkg_info.track`; when the plugin is absent, this entry is omitted. It supports:

- `console.log`, `debug`, `info`, `warn`, `error`, and `trace`
- `hilog.debug`, `info`, `warn`, `error`, and `fatal` when `hilog` is imported from `@ohos.hilog` or `@kit.PerformanceAnalysisKit`
- Cold-launch boundaries in `AbilityStage`, `UIAbility`, and other Ability `onCreate()` methods; `UIAbility.onWindowStageCreate()` also receives automatic first-frame observation.

Use a plugin version that supports the installed `@guancecloud/ft_sdk` version. The transformed call evaluates its arguments once, queues the Guance log, and keeps the original console/HiLog output.

### Configure and Verify

```ts
const loggerConfig = new FTLoggerConfig()
  .setEnableCustomLog(true) // Manual FTLogger only.
  .setEnableConsoleLog(true, '[business]') // Automatic console/HiLog only.

FTSDK.installLogConfig(loggerConfig)

console.info('[business] console example')
hilog.info(0x0000, 'Demo', '%{public}s', '[business] HiLog example')
```

Run a clean HAP build, install it on a device, and trigger both calls. Their original output must still appear in DevEco/HiLog. After upload, each generated log should have `log_source=console` or `log_source=hilog`; HiLog logs also have `domain` and `tag`. HiLog privacy is preserved: values without `%{public}` are recorded as `<private>`.

The optional second argument of `setEnableConsoleLog` accepts either a legacy message prefix or an automatic-collection allow rule. A plain string retains `startsWith` behavior. A value beginning with `{` uses the DataKit rule grammar: matching logs are retained, while non-matching logs are discarded before entering the SDK queue. Multiple rule blocks have OR semantics. Rules can use `message`, `log_source` (`console` or `hilog`), and—for HiLog—`tag` and `domain`. Log level is configured separately through `setLogLevelFilters(...)`.

```ts
const loggerConfig = new FTLoggerConfig().setEnableConsoleLog(true,
  "{ log_source = 'hilog' and tag = 'Network' and message match ['^HTTP'] }")
```

To verify the switches, repeat with `setEnableConsoleLog(false)` and confirm that no new automatic logs are uploaded. Keep `setEnableCustomLog(true)` and send an `FTLogger` log: it must still upload. Conversely, disabling `setEnableCustomLog(false)` must not affect auto-collected console/HiLog data while `setEnableConsoleLog(true)` is enabled.

If the compiler plugin is absent, automatic console/HiLog collection is unavailable even when `setEnableConsoleLog(true)` is set. The SDK emits one diagnostic when its log configuration is installed; this is intentional parity with Android's plugin prerequisite. There is no runtime interception fallback. Use `FTLogger` for manual logs, or install the plugin for automatic collection.
## Cold Launch Timing

Enable the [Hvigor compiler plugin](#hvigor-compiler-plugin) and initialize RUM
early with `FTRUMConfig.setEnableTraceUserAction(true)`. Startup timing is collected
automatically; no manual lifecycle timing calls are required.

- Configure an `AbilityStage` as the module's `srcEntry` to collect complete
  application-initialization timing.
- Automatic first-frame tracking requires API 22 or later. Without a first-frame
  observation, no cold-launch Action is reported.
- For background entries that need monitoring, initialize the SDK and RUM there.
  See [Device ID and Process Scope](#device-id-and-process-scope) for secondary-process setup.

The SDK reports at most one `launch_cold` Action per process, subject to session
sampling and Action filtering. Its `duration` is measured in nanoseconds from
process start to the first rendered UI frame using a monotonic clock.

`app_launch_type` identifies the original launch as `foreground` or `background`.
For a background launch, reporting waits for the first UI frame in that same
process, and `duration` includes the background wait. Later foregrounding does
not change the original launch type. A process that never renders UI does not
report a cold-launch Action.

Phase fields are included only when their timing boundaries are available:

- `app_pre_application_init_time`: process start to application initialization
- `app_application_init_time`: application initialization to first UIAbility creation
- `app_first_frame_init_time`: first UIAbility creation to first rendered frame

Hot-start Actions do not include these cold-launch phase fields.

## Automatic View Filtering

When automatic View tracking is enabled, Router pages and `Navigation`
destinations can be renamed or filtered with one handler. Choose whether it
applies to `ROUTER`, `NAVIGATION`, or `ALL`. Return a `HandlerView` to collect
the automatic View; return `null` to skip it. The handler receives a
source-specific context: Router Views expose the original `RouterPageInfo`,
and Navigation Views expose the original `NavDestinationSwitchInfo`. The
context includes the final normalized route segment as `viewName`. With no
handler set, the SDK keeps the default behavior and reports that final segment.

```ts
import {
  FTRUMConfig,
  FTViewTrackingContext,
  FTViewTrackingHandler,
  FTViewTrackingType,
  HandlerView
} from '@guancecloud/ft_sdk/Index'

const automaticViewHandler: FTViewTrackingHandler = {
  resolveHandlerView: (context: FTViewTrackingContext): HandlerView | null => {
    if (context.viewName === 'LoginPage') {
      return null // Do not collect this automatic View
    }
    if (context.trackingType === FTViewTrackingType.ROUTER &&
      context.routerPageInfo.path.startsWith('pages/internal/')) {
      return null // Filter directly by RouterPageInfo
    }
    if (context.trackingType === FTViewTrackingType.NAVIGATION) {
      const navigationInfo = context.navigationInfo
      const from = navigationInfo.from
      if (navigationInfo.operation === NavigationOperation.POP ||
        (typeof from !== 'string' && from.name === 'CheckoutPage')) {
        return null // Filter by operation or NavDestinationSwitchInfo.from
      }
    }
    return new HandlerView(`View_${context.viewName}`)
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserView(true)
  .setViewTrackingHandler(automaticViewHandler, FTViewTrackingType.ALL)
```

`originalViewName` preserves the name supplied by ArkUI, while `viewName` is
the normalized final route segment. When `trackingType` is `ROUTER`, use
`routerPageInfo` to filter by `name`, `path`, `index`, or `state`. When it is
`NAVIGATION`, use `navigationInfo` to filter by `from`, `to`, `operation`, or
the destination `param`, `navigationId`, and `navDestinationId`.

## Automatic Action Handler

When automatic Action tracking is enabled, configure
`FTRUMConfig.setActionTrackingHandler(...)` for automatic clicks and cold/hot
launch Actions. Return `HandlerAction` to customize the name and properties,
`null` to skip collection, or `undefined` to retain the SDK's default Action.
Launch events have a `null` source; distinguish them with `getSourceType()`.
Manual `addAction` and `startAction` calls do not invoke this handler. The SDK
retains launch type, duration, and cold-launch phase fields when a launch name
or properties are customized. For clicks, `HandlerAction` properties override
same-named component properties while retaining the others; return `undefined`
to keep all defaults.

```ts
import {
  ActionEventWrapper,
  ActionSourceType,
  FTActionTrackingHandler,
  FTRUMConfig,
  HandlerAction
} from '@guancecloud/ft_sdk/Index'

const actionHandler: FTActionTrackingHandler = {
  resolveHandlerAction: (event: ActionEventWrapper): HandlerAction | null | undefined => {
    if (event.getSourceType() === ActionSourceType.LAUNCH_COLD) {
      const properties: Record<string, object> = {}
      properties['channel'] = new String('startup')
      return new HandlerAction('custom_cold_launch', properties)
    }

    // Do not collect clicks from this component.
    if (event.getSource()?.getId() === 'ignore_action_view') {
      return null
    }

    // Keep the default click or hot-launch Action.
    return undefined
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserAction(true)
  .setActionTrackingHandler(actionHandler)
```

## SDK Debug Logs

Enable internal SDK diagnostics in debug builds, then filter HiLog/LogCat with `[FT-SDK]`:

```ts
const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDebug(true)
  .setSdkLogLevel(SDKLogLevel.D)
```

`V` and `D` output all SDK diagnostics. `I`, `W`, and `E` only output the selected severity and higher. The diagnostics cover the masked endpoint, RUM/Log/Trace configuration, Resource lifecycle, and data upload outcomes.

## Cache Governance and FileStore Migration

The default cache remains SQLite with the existing per-type record-count limits. Once a cache byte limit is enabled, `DISCARD` preserves existing pending data and rejects new data at the limit; `DISCARD_OLDEST` evicts eligible old records.

```ts
import { CacheDiscard, FTSDKConfig } from '@guancecloud/ft_sdk/Index'

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .enableLimitWithCacheSize(100 * 1024 * 1024)
  .setCacheDiscard(CacheDiscard.DISCARD_OLDEST)
```

`enableLimitWithCacheSize` and `setCacheDiscard` are the single cache-governance configuration, matching Android. `enableLimitWithDbSize`, `setDbCacheLimit`, and `setDbCacheDiscard` are deprecated compatibility aliases for the same settings; they do not establish an independent SQLite policy. With a byte limit enabled, the Log and RUM record-count limits do not participate in cache admission.

The meter follows the active store: SQLite mode uses SQLite page allocation; FileStore primary and Shadow modes use only FileStore sync payloads plus View/Action RUM aggregate files. SQLite copies, legacy cache files, spool files, FileStore metadata, and leases remain visible in physical-usage diagnostics but do not consume the configured cache budget.

FileStore rollout is opt-in. Start with shadow mode, which retains SQLite as the authority while mirroring sync payloads and the complete View/Action lifecycle to `files/ft_sdk_cache_v2`. A failed mirror is marked dirty and reconciled on the next operation; it must not be treated as a verified migration source.

```ts
const shadowConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setUseFileDataStore(false)
  .setFileDataStoreShadow(true)
```

After validating shadow data, enable FileStore as the primary durable store. Queries, upload pages and ACK/retry commits then operate directly on files; SQLite is not required after source reclamation completes. Existing SQLite payloads are cleared and their pages reclaimed once after the verified switch, including upgrades from the compatibility upload-index implementation. To copy an existing SQLite pending queue on the first FileStore launch, explicitly opt in to migration.

```ts
const fileStoreConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .enableFileDataStore()
  .setNeedTransformOldCache(true)
```

Migration uses durable `copying → verified → switched → completed` checkpoints. Commands (including manual/automatic upload) wait behind the same process lane and file lock. Existing SQLite data requires explicit migration opt-in; insufficient capacity leaves the source intact and migration incomplete. Increase the budget and restart to resume. Legacy NDJSON is imported before it is removed; corrupt legacy input blocks switching and retains its source for inspection.

In primary file mode, one physical-byte account covers payload/aggregate files, SQLite and its WAL/SHM files, legacy files, the failure spool, transaction/temp files and bounded quarantine. Admission reserves only the current transaction's net growth, largest atomic-replacement temporary file and journal; there is no fixed recovery reserve. `DISCARD_OLDEST` evicts unleased logs first (oldest timestamp, then ID), followed by other sync records; live View/Action state and in-flight upload versions are not silently evicted. If only protected data remains, new data is rejected. Lowering a limit below existing protected/control data reports pressure and rejects growth; it cannot make those bytes disappear.

Writes and upload commits use checksummed envelopes, fsync, rename and a forward-recovery journal. Stale ACKs do not delete a newer version of the same UUID. Network delivery remains at-least-once: if the server accepted a request before the client committed its ACK, that UUID can be sent again. `FTSDK.clearAllData()` clears persisted aggregates, sync payloads and the failure spool; stop producers before a manual empty-cache check.

Upload selection retains only page-sized candidate metadata plus the selected payloads; it does not load or rewrite the entire queue for an ACK. A record exceeding the configured upload-page byte limit is moved to the bounded quarantine and counted as rejected so it cannot block later valid records. Expired/orphaned upload leases are reclaimed. Directory enumeration and checksummed record scanning are still linear in the number of cached files; benchmark device latency separately from payload-memory bounds.

## Sampling Rates

> Availability: these percentage APIs are present in this source branch and
> are not yet tied to a published OHPM version. Use the release notes of the
> package you install to confirm availability.

Sampling configuration now uses a percentage `number` at its public boundary.
Every new value is a finite number in `[0, 100]`; decimal values are supported,
so `0.1` means **0.1%**, and `1` means **1%**. `NaN`, infinity, negative
values, and values over `100` are rejected with `RangeError` without changing
the previous configuration. Conversion to the SDK's internal `[0,1]`
probability happens once inside the configuration API.

| Capability | New setter / getter | Default |
| --- | --- | --- |
| RUM session | `setSessionSamplingRate` / `getSessionSamplingRate` | `100` |
| RUM session retained after an error | `setSessionOnErrorSamplingRate` / `getSessionOnErrorSamplingRate` | `0` |
| Log | `setLogSamplingRate` / `getLogSamplingRate` | `100` |
| Trace | `setTraceSamplingRate` / `getTraceSamplingRate` | `100` |

```ts
const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setSessionSamplingRate(20)          // 20%
  .setSessionOnErrorSamplingRate(0.1)  // 0.1%; only for a normally unsampled session

const loggerConfig = new FTLoggerConfig().setLogSamplingRate(99.9)
const traceConfig = new FTTraceConfig().setTraceSamplingRate(1)
```

`setSamplingRate` / `getSamplingRate` on RUM, Log, and Trace, plus
`setSessionErrorSampleRate` / `getSessionErrorSampleRate` on RUM, remain
available but are deprecated. They retain their original `[0,1]` probability
unit, defaults, and behavior: old `1` still means 100%. Do not select a unit
by value; migrate the method name as well. When both local forms are set, the
new percentage method wins regardless of call order. Session Replay sampling
is provided by the separate
[`@guancecloud/ft_session_replay`](../ft_session_replay/README.md#sampling-rates)
package through `FTSessionReplayConfig.setSampleRate` and
`setSessionReplayOnErrorSampleRate`. These Replay setters and getters use
`[0,100]` percentages: `1` means 1% and `100` means 100%, with no legacy
probability-unit compatibility.

## Remote Configuration and Runtime Endpoint

Remote configuration is opt-in. After RUM is installed, the SDK fetches `v1/env_variable` using the RUM app ID, caches a valid response, and applies the Android-compatible fields on the next initialization or, where supported, immediately. The default refresh interval is 12 hours.

```ts
const sdkConfig = FTSDKConfig.builder()
  .setRemoteConfiguration(true)
  .setRemoteConfigMiniUpdateInterval(43_200)

FTSDK.install(sdkConfig, this.context)
FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('YOUR_RUM_APP_ID'))

// Upload and remote-config fetching can be enabled after SDK initialization.
FTSDK.setDatakitUrl('https://datakit.example.com')
// Or: FTSDK.setDatawayUrl('https://dataway.example.com', 'CLIENT_TOKEN')
```

Use `FTSDK.updateRemoteConfig()` for an interval-respecting manual refresh, or pass `0` as the first argument to the overload to force a fetch. Switching to a valid runtime endpoint also refreshes remote configuration immediately; an in-flight response from the old endpoint is ignored.

### Remote sampling keys

Remote responses use the same percentage contract as the local APIs. The
following new keys take precedence over their deprecated `[0,1]` counterparts:

| New key (`[0,100]`) | Deprecated key (`[0,1]`) |
| --- | --- |
| `sessionSamplingRate` | `rumSampleRate` |
| `sessionOnErrorSamplingRate` | `rumSessionOnErrorSampleRate` |
| `logSamplingRate` | `logSampleRate` |
| `traceSamplingRate` | `traceSampleRate` |

For a period of old/new client coexistence, the control plane may double-write
equivalent values, such as `logSampleRate: 0.2` and
`logSamplingRate: 20`. A valid new key, including an explicit `0`, wins. If a
new key is present but invalid, the SDK does **not** fall back to the old key
from that response: it keeps the previous valid remote value when one exists,
or retains the effective local value when none exists. That safeguard also
applies to callback-modified remote configurations and cached startup data.

If both keys are absent in a later valid response, the remote override is
removed and the local setting becomes effective again. A valid remote sampling
value overrides both local API forms. The protocol continues to use only the
four HarmonyOS-supported RUM/Log/Trace keys above; Replay keys are not
implemented by this SDK.

## Device ID and Process Scope

Access to the system device ID is disabled by default. The SDK instead uses an
app-private `device_uuid` that remains stable across normal restarts. Enable the
system identifier with `.setEnableAccessDeviceID(true)` on `FTSDKConfig` before
installation, or switch at runtime with `FTSDK.setEnableAccessDeviceID(...)`.

By default, the SDK initializes only in the application's main process. Calls
to `FTSDK.install(...)` from secondary processes are ignored. To initialize the
SDK in secondary processes, call `.setOnlySupportMainProcess(false)` on
`FTSDKConfig` before `FTSDK.install(...)`.

## Update the Reporting Endpoint at Runtime

After `FTSDK.install(...)`, switch the active reporting endpoint without recreating the SDK:

```ts
// DataKit mode
FTSDK.setDatakitUrl('https://datakit.example.com')

// Dataway mode
FTSDK.setDatawayUrl('https://dataway.example.com', 'YOUR_CLIENT_TOKEN')
```

The two modes are mutually exclusive: setting a DataKit URL clears the Dataway URL and token; setting a Dataway URL clears the DataKit URL. Use a complete `http://` or `https://` URL. The new value is kept in memory only, so configure it again after an app restart if needed. Automatic upload resumes when the endpoint is valid; call `FTSDK.flushSyncData()` when you need to request an immediate upload.

## Data Filtering

Local data filtering is enabled by default. Configure rules before `FTSDK.install(...)`; a matching RUM or logging point is discarded after `LineDataModifier` runs and before the point enters the local cache.

```ts
const dataFilters = new Map<string, Array<string>>()
dataFilters.set('logging', [
  "{ source in ['df_rum_harmonyos_log'] and message match ['.*password.*'] }"
])
dataFilters.set('rum', [
  "{ source in [resource] and resource_status in ['404', '503'] }"
])

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataFilters(dataFilters)
```

- Supported categories are `logging` and `rum` (case-insensitive); other categories are ignored.
- A rule is enclosed in `{}`. Supported operators are `=`, `!=`, `in`, `not in`, `match`, and `not match`, combined with `and` / `or`. `match` uses regular expressions.
- Rule fields are resolved from tags and fields. `source`, `measurement`, and `class` refer to the Line Protocol measurement. For example, HarmonyOS custom logs use `df_rum_harmonyos_log`.
- While filtering is enabled and an endpoint is valid, the SDK also pulls remote `logging` and `rum` rules from `/v1/datakit/pull?filters=true`. Local and remote rules are combined: a point matching either is discarded. The next pull follows the server's `pull_interval`; an absent or invalid value retries in 10 seconds. A runtime endpoint switch clears rules from the old endpoint and immediately pulls rules from the new one.
- Call `.setEnableDataFilter(false)` to turn off both local and remote filtering without removing the configured rules. Call `.setDataFilters(null)` to clear local rules.
## Data Modification and Masking

Configure callbacks before `FTSDK.install(...)` to modify or mask data before it is cached and uploaded. `DataModifier` runs for every raw Log, native RUM, and WebView RUM tag/field. Return `null` to retain the original value.

`LineDataModifier` runs after SDK tags and fields have been merged. It receives one combined map and returns a patch: only returned values for existing keys are replaced. Returning `null`, an empty map, a `null` value, or an unknown key does not change the record.

```ts
import {
  DataModifier,
  DataModifierValue,
  FTSDK,
  FTSDKConfig,
  LineDataModifier
} from '@guancecloud/ft_sdk/Index'

class FieldMasker implements DataModifier {
  modify(key: string, _value: DataModifierValue): DataModifierValue | null {
    return key === 'password' || key === 'authorization' ? '[masked]' : null
  }
}

class RecordMasker implements LineDataModifier {
  modify(_measurement: string, data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    const patch = new Map<string, DataModifierValue>()
    if (data.get('message') === 'sensitive message') {
      patch.set('message', '[masked]')
    }
    return patch.size === 0 ? null : patch
  }
}

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataModifier(new FieldMasker())
  .setLineDataModifier(new RecordMasker())

FTSDK.install(sdkConfig, this.context)
```

Use `DataModifier` for global key-based rules; it is the lower-overhead option. Use `LineDataModifier` only when a decision needs multiple values in the same record. Neither callback can add, remove, or move a key between tags and fields.

## WebView Bridge Host Policy

Use `setAllowWebViewHost(...)` to choose which WebView hosts can send Browser SDK
data through the Native Bridge. Configure it before SDK installation:

```ts
import { FTSDK, FTSDKConfig, FTRUMConfig, FTLoggerConfig } from '@guancecloud/ft_sdk/Index'

const sdkConfig = FTSDKConfig.builder('http://YOUR_DATAKIT:9529')
  .setAllowWebViewHost(['example.com', 'second.example'])
FTSDK.install(sdkConfig, this.context)

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_APP_ID')
  .setEnableTraceWebView(true)
FTSDK.installRUMConfig(rumConfig)

// Optional: forward Browser SDK logs through the Native Bridge.
FTSDK.installLogConfig(new FTLoggerConfig().setEnableWebViewLog(true))
```

Bind the WebView using `FTWebViewHandler` to enable Bridge collection.

| Value | Allowed hosts |
| --- | --- |
| `null` | All hosts. |
| `[]` | No hosts; disable collection through the Bridge. |
| `['example.com']` | `example.com` and its subdomains. |

Pass hostnames only, without a protocol, path, port, or wildcard.

Remote `rumAllowWebViewHost` takes priority over local settings. For local
configuration, an explicit `FTSDKConfig` setting takes priority over the legacy
`FTRUMConfig.setAllowWebViewHost(...)` setting.

Changed settings apply to newly bound WebViews. To update an existing WebView,
call `clearWebController()`, recreate the WebView and controller, and bind again
before loading the page.

## Main Exports

- `FTSDK`: SDK bootstrap entry
- `FTSDKConfig`: base SDK configuration
- `FTDataFilters`: local data-filter rule type
- `FTRUMConfig`: RUM configuration
- `FTLoggerConfig`: logger configuration
- `FTTraceConfig`: trace configuration
- `SDKLogLevel`: SDK internal log threshold
- `FTTraceContext`: generated Trace Header and RUM linking ID context
- `FTTraceHeaderHandler`: custom Trace Header context handler interface
- `FTTraceRequestContext`: current request context passed to custom Trace Header handlers
- `FTRUMGlobalManager`: RUM reporting API
- `FTLogger`: custom log API
- `FTTraceManager` / `FTTraceManagerStatus`: trace helper API and its status shape
- `FTWebViewHandler`: WebView bridge integration API
- `createFTRCPTrackConfig` / `createFTRCPInterceptors`: RCP auto-track helpers
- `FTRCPSessionConfigurationOptions`: options for the RCP configuration factory
- `applyFTAxiosTrack` / `FTAutoTrackOptions` / `FTAxiosTrackRegistration`: Axios auto-track API, options, and registration result
- `RCPTraceInterceptor` / `RCPResourceInterceptor`: advanced manual RCP interceptor assembly
- `DefaultFTTraceInterceptor`: default low-level trace interceptor implementation

## Requirements

- HarmonyOS application project with `ohpm` support
- The `ft_sdk` HAR declares these normal permissions in its own `module.json5`:

  ```json5
  {
    "module": {
      "requestPermissions": [
        { "name": "ohos.permission.INTERNET" },
        { "name": "ohos.permission.GET_WIFI_INFO" },
        { "name": "ohos.permission.GET_NETWORK_INFO" }
      ]
    }
  }
  ```

  `INTERNET` uploads SDK data. `GET_NETWORK_INFO` supports network availability
  and transport-type collection, while `GET_WIFI_INFO` supports Wi-Fi signal
  collection. A consuming HAP does not need to duplicate these declarations;
  they are introduced by the `ft_sdk` HAR.
- Verify compatibility against your target HarmonyOS API level before release

## Notes

- Call `FTSDK.install(...)` before `installRUMConfig`, `installLogConfig`, and `installTraceConfig`
- Add `@guancecloud/ft_sdk_ext` when you need HarmonyOS `HttpInterceptor` chain integration
- Add `@guancecloud/ft_native` when you need native crash monitoring. `ft_sdk` initializes `libftnativecrash.so` internally when crash tracking is enabled:

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

## Documentation

- https://docs.guance.com/real-user-monitoring/harmonyos/app-access/

## License

- Apache-2.0
