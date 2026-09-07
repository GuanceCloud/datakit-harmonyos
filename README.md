# GuanceCloud SDK HarmonyOS

![](https://img.shields.io/badge/dynamic/json?label=agent&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/agent/version.json&link=https://github.com/GuanceCloud/datakit-harmonyos) ![](https://img.shields.io/badge/dynamic/json?label=agent&color=orange&query=$.version&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/native/version.json&link=https://github.com/GuanceCloud/datakit-harmonyos) ![](https://img.shields.io/badge/dynamic/json?label=min.sdk&color=green&query=$.mini_sdk&uri=https://static.guance.com/ft-sdk-package/badge/harmonyos/agent/info.json&link=https://github.com/GuanceCloud/datakit-harmonyos)

## Introduction

GuanceCloud Application Monitoring can collect metric data from HarmonyOS applications and analyze application performance, user experience, logs, and crash information in a visualized way.

## Example

This repository contains the HarmonyOS SDK source modules, including `@guancecloud/ft_sdk`, `@guancecloud/ft_sdk_ext`, and `@guancecloud/ft_native`.

## Installation

Choose the package that matches your scenario:

- `@guancecloud/ft_sdk`: core SDK for RUM, logging, tracing, and lifecycle monitoring
- `@guancecloud/ft_sdk_ext`: extension package for newer compiler/platform capabilities, built on top of `@guancecloud/ft_sdk`
- `@guancecloud/ft_native`: native crash collection module

Install with `ohpm install`:

```bash
ohpm install @guancecloud/ft_sdk
ohpm install @guancecloud/ft_sdk_ext
ohpm install @guancecloud/ft_native
```

Or use the short form `ohpm i`:

```bash
ohpm i @guancecloud/ft_sdk
ohpm i @guancecloud/ft_sdk_ext
ohpm i @guancecloud/ft_native
```

Then declare the dependency in your app `oh-package.json5` if needed:

```json5
{
  "dependencies": {
    "@guancecloud/ft_sdk": "latest",
    "@guancecloud/ft_sdk_ext": "latest",
    "@guancecloud/ft_native": "latest"
  }
}
```

`@guancecloud/ft_sdk_ext` depends on `@guancecloud/ft_sdk`. If you only need the core monitoring capability, install `@guancecloud/ft_sdk` alone.
`@guancecloud/ft_native` is optional and only needed when you want native crash monitoring. Once it is packaged with the app, `ft_sdk` initializes the native crash module internally when crash tracking is enabled.

For cold-launch phase timing, enable the Guance Hvigor compiler plugin. It
injects the required Ability lifecycle and first-frame hooks during the build,
so the host application does not add timing calls. See the module
[cold-launch timing guide](ft_sdk/README.md#cold-launch-timing).

## Bytecode HAR Integration

SDK HARs are configured to build as bytecode HARs. An application that depends on any of these packages must enable normalized OHMUrl in its root `build-profile.json5`:

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

Bytecode HAR requires HarmonyOS API 12 or later. Keep the dependency aliases identical to the package names in `oh-package.json5`, and use only APIs exported from each package `Index.ets`.

## Release Obfuscation

Release builds enable ArkGuard obfuscation for all SDK HAR modules. The public APIs exported through `Index.ets`, plus the native crash Node-API bridge, are retained so the obfuscated HAR remains compatible with integrating applications. Do not remove the module `consumer-rules.txt` files: Hvigor packages them as `obfuscation.txt` and applies the required keep rules when an integrating application also enables obfuscation.

## Quick Start

For most HarmonyOS applications, start with `@guancecloud/ft_sdk` and initialize it in `UIAbility.onCreate`:

```ts
import UIAbility from '@ohos.app.ability.UIAbility'
import type Want from '@ohos.app.ability.Want'
import {
  FTSDK,
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
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
      .setEnableTraceUserView(true)
      .setEnableTraceUserAction(true)
      .setEnableTraceUserResource(true)
      .setEnableTrackAppCrash(true)

    const loggerConfig = new FTLoggerConfig().setEnableCustomLog(true)
    const traceConfig = new FTTraceConfig().setEnableAutoTrace(true).setTraceType(TraceType.DDTRACE)

    FTSDK.installRUMConfig(rumConfig)
    FTSDK.installLogConfig(loggerConfig)
    FTSDK.installTraceConfig(traceConfig)
  }
}
```

## Automatic Console and HiLog Collection

HarmonyOS collects application `console.*` and `hilog.*` calls through the standalone Guance Hvigor compiler plugin. This follows Android's `setEnableConsoleLog` model: the switch enables collection, while the build plugin supplies the instrumentation. There is no runtime monkey-patching fallback.

Install `@guancecloud/ft-hvigor-plugin` in the project-level `hvigor/hvigor-config.json5` (this is a Hvigor tool dependency, not an `oh-package.json5` runtime dependency), then register it in the application HAP module's `hvigorfile.ts`:

```ts
import { hapTasks } from '@ohos/hvigor-ohos-plugin'
import { ftConsoleLogPlugin } from '@guancecloud/ft-hvigor-plugin'

export default {
  system: hapTasks,
  plugins: [ftConsoleLogPlugin()]
}
```

Then install the log configuration:

```ts
const loggerConfig = new FTLoggerConfig()
  .setEnableCustomLog(true) // Controls manual FTLogger reporting only.
  .setEnableConsoleLog(true, '[business]') // Controls auto-collected console/HiLog only.

FTSDK.installLogConfig(loggerConfig)
```

The plugin rewrites direct calls in the application's `src/main/ets` sources without changing files on disk. It supports `console.log/debug/info/warn/error/trace` and `hilog.debug/info/warn/error/fatal` imported from `@ohos.hilog` or `@kit.PerformanceAnalysisKit`. Original console/HiLog output is retained. The optional prefix filters automatic collection only.

| Setup | `console` / `hilog` automatic collection | Manual `FTLogger` reporting |
| --- | --- | --- |
| Plugin installed + `setEnableConsoleLog(true)` | Enabled | Controlled by `setEnableCustomLog(...)` |
| Plugin installed + `setEnableConsoleLog(false)` | Disabled | Controlled by `setEnableCustomLog(...)` |
| Plugin absent | Disabled; the SDK emits one diagnostic after log configuration | Controlled by `setEnableCustomLog(...)` |

Without the plugin, the SDK deliberately does not pretend to collect console logs. Use `FTLogger` for manual reporting, or add the plugin when automatic coverage is required. See the [core SDK guide](ft_sdk/README.md#automatic-console-and-hilog-collection) for verification steps and HiLog privacy behavior.

## Automatic View Filtering

When automatic View tracking is enabled, Router pages and `Navigation`
destinations can be independently renamed or filtered. Return a `HandlerView`
to collect the automatic View; return `null` to skip it. With no handler set,
the SDK keeps the default behavior and reports the final route segment.

```ts
import {
  FTRUMConfig,
  FTViewRouterTrackingHandler,
  FTViewNavigationTrackingHandler,
  HandlerView
} from '@guancecloud/ft_sdk/Index'

const routerHandler: FTViewRouterTrackingHandler = {
  resolveHandlerView: (routeName: string): HandlerView | null => {
    if (routeName === 'LoginPage') {
      return null // Do not collect this Router page
    }
    return new HandlerView(`Router_${routeName}`)
  }
}

const navigationHandler: FTViewNavigationTrackingHandler = {
  resolveHandlerView: (destinationName: string): HandlerView | null => {
    return destinationName === 'OrderDetail'
      ? new HandlerView('Order Detail')
      : null
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserView(true)
  .setViewRouterTrackingHandler(routerHandler)
  .setViewNavigationTrackingHandler(navigationHandler)
```

## Automatic Action Filtering

When automatic Action tracking is enabled, configure
`FTRUMConfig.setActionTrackingHandler(...)` to filter click Actions.
The handler is called for each automatically tracked user operation. Return
`null` to skip collection; return `undefined` to continue through the SDK's
original automatic Action collection path, including name, properties,
position, and View association.

```ts
import {
  ActionEventWrapper,
  FTActionTrackingHandler,
  FTRUMConfig
} from '@guancecloud/ft_sdk/Index'

const actionHandler: FTActionTrackingHandler = {
  resolveHandlerAction: (event: ActionEventWrapper): null | undefined => {
    // Do not collect clicks from this component.
    if (event.getSource()?.getId() === 'ignore_action_view') {
      return null
    }

    // Continue through the original automatic Action collection path.
    return undefined
  }
}

const rumConfig = new FTRUMConfig()
  .setEnableTraceUserAction(true)
  .setActionTrackingHandler(actionHandler)
```

## SDK Debug Logs

Enable internal SDK logs in debug builds, then filter HiLog/LogCat with `[FT-SDK]`:

```ts
const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDebug(true)
  .setSdkLogLevel(SDKLogLevel.D)
```

`V` and `D` show all current SDK diagnostics; `I`, `W`, and `E` progressively reduce output to those levels and above. Debug logs include the masked upload endpoint, RUM/Log/Trace configuration summaries, Resource lifecycle events, and upload results. Never enable these logs in a production build unless troubleshooting is required.

## Update the Reporting Endpoint at Runtime

After `FTSDK.install(...)`, update the active reporting endpoint without recreating the SDK:

```ts
FTSDK.setDatakitUrl('https://datakit.example.com')
FTSDK.setDatawayUrl('https://dataway.example.com', 'YOUR_CLIENT_TOKEN')
```

DataKit and Dataway modes are mutually exclusive. The endpoint must be a complete `http://` or `https://` URL; Dataway also requires a client token. The value is kept in memory only. Automatic uploads resume after a valid endpoint is set, and `FTSDK.flushSyncData()` can request an immediate upload.

## Remote Configuration and Runtime Endpoint

Enable remote configuration with `FTSDKConfig.setRemoteConfiguration(true)`. Once RUM is installed, the SDK requests `v1/env_variable` with the RUM app ID, persists a valid response, and applies supported updates. The default refresh interval is 12 hours.

```ts
const sdkConfig = FTSDKConfig.builder()
  .setRemoteConfiguration(true)

FTSDK.install(sdkConfig, this.context)
FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId('YOUR_RUM_APP_ID'))

// It is also valid to supply the upload endpoint later.
FTSDK.setDatakitUrl('https://datakit.example.com')
// Or: FTSDK.setDatawayUrl('https://dataway.example.com', 'CLIENT_TOKEN')
```

Call `FTSDK.updateRemoteConfig()` for a manual interval-respecting refresh. `FTSDK.setEnableAccessDeviceID(...)` updates the runtime `device_uuid` selection between a system identifier (when available) and the SDK privacy UUID.

## Local Data Filtering

The core SDK supports Android-compatible local filtering for logging and RUM data. Filters are enabled by default and discard matching points after `LineDataModifier` and before local-cache persistence.

```ts
const filters = new Map<string, Array<string>>()
filters.set('logging', ["{ message match ['.*password.*'] }"])
filters.set('rum', ["{ source in [resource] and resource_status in ['404', '503'] }"])

const sdkConfig = FTSDKConfig.builder('YOUR_DATAKIT_OR_DATAWAY_URL')
  .setDataFilters(filters)
// .setEnableDataFilter(false) disables filtering while retaining these rules.
```

Rules use the `logging` and `rum` categories and support `in`, `not in`, `match`, `not match`, `and`, and `or`. See the `ft_sdk` README for rule-field semantics and full details.
## Data Modification and Masking

`FTSDKConfig.setDataModifier(...)` masks or replaces a value by key for every raw Log, native RUM, and WebView RUM tag/field. Return `null` to leave a value unchanged. `setLineDataModifier(...)` receives the merged record and returns a patch for existing keys when a rule needs to inspect multiple values.

Configure both callbacks before `FTSDK.install(...)`. The core-package guide includes the full ArkTS example and exact patch semantics: [Data Modification and Masking](ft_sdk/README.md#data-modification-and-masking).

## Package Guide

- `@guancecloud/ft_sdk`: standard SDK initialization, RUM, logging, tracing, and common network helpers
- `@guancecloud/ft_sdk_ext`: add when you need HarmonyOS `HttpInterceptor` chain integration
- `@guancecloud/ft_native`: add when you need native crash monitoring through the implicit `libftnativecrash.so` integration

## Native Crash Monitoring

```ts
import { FTRUMConfig } from '@guancecloud/ft_sdk/Index'

const rumConfig = new FTRUMConfig()
  .setRumAppId('YOUR_RUM_APP_ID')
  .setEnableTrackAppCrash(true)
```

Add `@guancecloud/ft_native` to the application dependencies so `libftnativecrash.so` is packaged with the app. When crash tracking is enabled, `ft_sdk` initializes the native crash module internally.

## Regression Gates

HarmonyOS on-device Hypium tests are the RUM regression gate. Run the
`ft_sdk_test` Instrument Test module before merging or releasing changes to RUM
initialization, event construction, context, modifiers, serialization or upload.
The checked-in test entry is `ft_sdk/src/ohosTest/ets/test/List.test.ets`.
There is no separate Node Host gate required by this repository.

`DataSyncTest`, `DataModifierTest`, `RcpAutoTrackDeviceTest` and
`UserDataManagerPersistenceTest` use `helpers/RumAttributeAssert.ets` to verify
SDK-generated records and upload payloads. The independent contract requires
SDK/app/device/session/user/network tags, sampling fields and event-specific
attributes. Cases that provide optional fields must also assert them. Zero and
false are valid values; absent resource size/timings and status-zero Resource
records retain their documented behavior. Do not pre-fill SDK public attributes
in test fixtures or generate the required-key list from the producer.

Upload checks match measurement plus the event's `sdk_data_id` (allowing the
upload package prefix), then compare stored tags, fields and timestamp with the
uploaded event. A Resource's URL appearing in a network Error does not satisfy
its upload assertion. Missing, empty, mistyped or lost attributes fail the case.
New business paths must use the same assertion and keep their scenario-specific
checks. Intentional schema changes must update both the contract and the
corresponding cases with an explanation.

The shared `MockCollector` injects HTTP results into the real upload Worker.
Event production, Worker processing, database writes, upload assembly and row
commit/deletion run on the device. This verifies the assembled upload payload;
real HTTP delivery and backend acceptance require `RealBackendSmokeTest` with
its explicit runtime parameters. Its disabled default is not backend evidence.
Await `collector.stop()` before resetting SDK state or deleting test data.
`SdkTestLifecycle` clears Host singletons and Worker snapshots between cases;
reinstalling within a case requires restarting the collector after the reset.

`RealBackendSmokeTest` observes real upload Worker responses: the target record
must appear in a request returning HTTP 2xx and subsequently leave the database.
Log cases compare the original log payload, allowing only the upload package ID
prefix to change. Backend query/index visibility still requires checking the
unique `real_backend_*` marker in Studio; HTTP 2xx is not a query assertion.

Enable it with Instrument Test parameters `enableRealBackendSmoke=true`,
`realBackendDatawayUrl`, `realBackendClientToken`, and `realBackendRumAppId`.
When disabled, the suite registers no cases. When enabled, missing credentials
fail setup rather than passing a placeholder assertion. Use a per-case timeout
of at least 120 seconds for the recovery scenario.

`realBackendShouldRecoverUploadAfter503` additionally requires
`realBackendRecoveryControlUrl`. Point `realBackendDatawayUrl` at a test-owned
proxy that forwards uploads to your real Dataway. Its control URL must accept
`POST` JSON `{"mode":"fail"}` to make upload routes return HTTP 503 without
forwarding, and `{"mode":"recover"}` to resume real forwarding, acknowledging
both controls with HTTP 2xx. Use an isolated proxy for this run. The case checks
the exact log survives the real 503, then receives 2xx on retry and is deleted;
it restores forwarding even when assertions fail. No HTTP results are injected.
A missing control URL fails this case. This tests recovery from a server failure,
not an operating-system airplane-mode transition.

`realBackendShouldUploadHistoricalLogAfterSdkReinstall` creates a pending log,
reinitializes SDK/Worker state without clearing its database, checks its UUID,
timestamp and content, and verifies real upload after reinstall. It tests SDK
reinitialization within the process, not app process termination or device reboot.

For the core gate, run every case in the four suites above, plus
`WorkerIntegrationDeviceTest` and `SyncUploadChainDeviceTest`. Run
`ft_sdk_ext_test` for extension changes. Preserve the final Hypium report and
verify that every selected case ran with zero Failure/Error and no skipped
required case. Missing devices, missing reports, zero cases, compilation errors
or timeouts must fail the gate. A successful HAP build or
`TestFinished-ResultCode: 0` alone is not a passing test report.

With the DevEco Node/Java environment and `hdc` configured, build the core test
HAP, install it alongside the demo application, and select the required suites:

```bash
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=ft_sdk@ohosTest -p isOhosTest=true \
  -p product=default -p buildMode=test genOnDeviceTestHap --no-daemon
hdc install -r ft_sdk/build/default/outputs/ohosTest/ft_sdk-ohosTest-signed.hap
hdc shell aa force-stop com.guance.hm.example
hdc shell aa test -b com.guance.hm.example -m ft_sdk_test \
  -s unittest OpenHarmonyTestRunner \
  -s class DataModifierTest,DataSyncTest,RcpAutoTrackDeviceTest,UserDataManagerPersistenceTest,WorkerIntegrationDeviceTest,SyncUploadChainDeviceTest \
  -s timeout 60000 -w 900
```

Start each run in a fresh test process so a previous run cannot retain module
code, runner state or Worker resources. The per-case timeout is 60 seconds;
the default five seconds is shorter than
some existing multi-step upload cases. `DataModifierTest` also checks all RUM
event types across default/null/empty/modifying line callbacks and uses mutated
copies of real records to prove missing resources, missing/empty attributes,
wrong sampling types and duplicated payload events are rejected.

The core test HAP has no optional `ft_native` library. Its
`WorkerIntegrationDeviceTest.crashWorkerRecycleAndResumeCommands` verifies
Worker recycling and recreation. Run
`NativeWorkerIntegrationUITest.crashRecyclePreservesLogs`
in the `entry` Instrument Test module to verify native log preservation across
Worker recreation; that case requires the native library and checks both log
markers without skipping assertions. `duplicateWebViewShouldWriteOnce` verifies
that repeated Browser actions create one row and upload once; repeated views
remain collectable. `DBAssert` includes missing fragments and the closest stored line when a record
cannot be matched, so attribute failures identify the missing data.

## Entry UI upload regression

Run `RumUploadE2EUITest` in a fresh Demo process with launch parameters. The
test opens Demo pages and checks automatically collected view/action events,
manual long task/error events, and real GET resources from RCP, NetworkKit HTTP
Chain, Axios Compat and Axios Chain. Each event carries `ft_e2e_run` so the
records can also be found at the receiving endpoint.

The upload assertion waits up to 60 seconds for the real HTTP result and local
acknowledgement. A timeout does not mean the server rejected the data: check
`Sync Success-[code:200` and the reported upload lane state. HTTP resource targets
must actually return the expected 200/500 status; a transport timeout against
the test target can fail resource assertions before the explicit upload flush.
Use `resourceTestUrl` and `entryResourceErrorUrl` with a controlled test
server when the public HTTP test service is unavailable. These resource targets
do not replace the saved SDK upload endpoint.

Entry tests and the Demo use **one set of startup arguments and Preferences** in
`entry_ability_runtime_config`. The test launcher only forwards explicitly supplied
app arguments to `EntryAbility`; it does not inject defaults or resolve a second
configuration. Both entry points apply `explicit argument > saved value > Demo
default`, validate the result, and persist changed values. An empty string clears
that string setting. Launching again without arguments restores the saved result,
including automatic upload and sampling rates.

An explicit DataKit URL selects DataKit and clears the saved Dataway URL/token;
an explicit Dataway URL selects Dataway and can reuse the saved token. Do not
supply two non-empty endpoints together. There is no fallback localhost intake
or synthetic RUM app ID. Startup logs show value sources and mask the token.
Tests requiring upload report missing or invalid endpoints instead of inventing one.

| Shared startup argument | Default when not saved / behavior |
| --- | --- |
| `datakitUrl` | Empty; DataKit upload endpoint |
| `datawayUrl`, `clientToken` | Empty; Dataway upload endpoint and token |
| `appId` | Empty; RUM application ID required for RUM tests |
| `webViewUrl`, `traceUrl` | Empty; Demo WebView and trace request targets |
| `resourceTestUrl` | Empty; each Demo GET button uses its own fallback target |
| `autoSync` | `true`; persisted automatic upload switch |
| `logSamplingRate`, `rumSamplingRate`, `errorSamplingRate`, `traceSamplingRate` | `1`; persisted rates from `0` to `1` |
| `localDataFilterEnabled` | `true`; persisted local filtering switch |
| `localDataFilterLogRule`, `localDataFilterRumRule` | Empty; persisted filter expressions |
| `remoteConfigTestEnabled` | `false`; Demo remote-configuration debugging switch |
| `networkRouteTestEnabled`, `networkRouteTestMode`, `networkRouteTestHost` | `false`, `proxy`, empty; shared network route test configuration |

Boolean startup arguments accept `true`/`false`, `1`/`0`, or `on`/`off`.
Invalid flags and sampling rates report their parameter name before saving.
The former `entry...` aliases for these app settings and `entryUsePersistedConfig`
are removed. Use the same names for both Demo and instrument-test launches.

The following execution controls stay in the test runner; they are never forwarded
as application startup arguments or saved in Demo Preferences:

| Test execution argument | Default / behavior |
| --- | --- |
| `entryWebViewExpectedMarker` | `WebViewBridgeSmoke`; marker emitted by the configured SDK-integrated page |
| `entryResourceErrorUrl` | `https://httpbin.org/status/500`; temporary HTTP failure target restored after the case |
| `entryKeepData` | `false`; prevents test setup/teardown cleanup and overrides both cleanup switches |
| `entryClearDataBeforeTest` | `true`; controls shared per-case setup cleanup |
| `entryClearDataAfterTest` | `true`; controls teardown cleanup; upload E2E retains failures for diagnosis |
| `entryUploadE2EEnabled` | `false`; enables the real upload suite |

Execution flags accept `true` or `false`. Full-event upload E2E checks that the
shared configuration has `autoSync=false`, all sampling rates at `1`, and local
filtering/remote configuration disabled. It fails with a configuration message
rather than silently changing those values. Other fixed-count cases also need
full sampling and controlled uploads; use targeted suites for other configurations.

`TraceAutoTrackUITest` and `WebViewTrackUITest` preserve the shared `autoSync`
setting. Assertions inspect pending records and retain snapshots of records handled
by the real upload worker, so successful automatic upload does not hide evidence. The trace-ID case uses the configured `traceUrl`, with
no fixed `/api/user` path requirement. The WebView case requires a nonblank
`webViewUrl` whose page emits SDK bridge events, including `entryWebViewExpectedMarker`.

The saved **entry ohosTest All** IDE configuration keeps installed application data
(`KEEP_DATA=true`). Its shared startup arguments explicitly select the controlled
upload configuration below, and therefore save those values just like a Demo
launch. Remove those explicit app arguments to reuse your saved configuration.
With either cleanup switch disabled (or `entryKeepData=true`), destructive
`EntrySDKDBTest` and native crash-log reset tests are skipped and log the reason.
Successful uploads and normal SDK cache policies still consume/evict data;
`entryKeepData` only controls test cleanup.

For restart verification, retain app data in DevEco, set `entryKeepData=true`, and
keep `entryUploadE2EEnabled=false` when enabling `autoSync=true`. A new Demo or test
process reads the same saved endpoint and upload switch without resupplying them.
Do not uninstall or clear app storage. The existing upload suite runs within one
process; verify the previous event UUID at the receiver and its removal from the
pending database when checking a real restart.

Example DevEco **Test arguments** (semicolon-separated `key=value`; do not include
`-s` because DevEco supplies it). These explicit app settings are persisted:

```text
autoSync=false;entryKeepData=false;entryClearDataBeforeTest=true;entryClearDataAfterTest=true;entryUploadE2EEnabled=true;logSamplingRate=1;rumSamplingRate=1;errorSamplingRate=1;traceSamplingRate=1;localDataFilterEnabled=false;remoteConfigTestEnabled=false
```

For `hdc shell aa test`, pass `-s key value`. For a Demo launch with `aa start`,
pass `--ps key value`; for example, both accept `datakitUrl`, `appId` and `autoSync`
with identical meaning. Only the command-line syntax differs.

The resource page adds a `ft_source` query parameter only in UI-test mode
(identified automatically by the UI-test launcher) to distinguish
transports. Normal Demo launches do not add this parameter.
API 22's native HTTP interceptor context does not expose the request method, so
the NetworkKit Chain record currently expects `resource_method=UNKNOWN`;
RCP and both Axios paths expect `GET`. The success case requires status 200;
the failure cases exercise HTTP 500 and a real refused connection to
`http://127.0.0.1:1/resource`. A transport failure has no Resource status tag;
its linked Error carries status 0. All four resource paths require duration,
trace ID, span ID and request headers, with trace/span IDs matching the actual
outgoing Datadog headers.
The UI runner forwards explicit arguments to `EntryAbility.onCreate`, which reads
Preferences using its own UIAbility context and initializes the SDK. Tests wait
for the installed RUM configuration to match the resolved app ID; startup failures
are reported in the EntryAbility logs. The runner never reads
Preferences from its pre-launch delegator context. Explicit app arguments
are persisted through the same path used by a normal Demo launch. The E2E run requires `autoSync=false` until
the explicit flush. The success case checks 16 distinct events, including the
initiating Actions and closed Views; each failure case checks four Resources,
four corresponding network Errors, four Actions and their View (13 events).
The assertions inspect the complete bodies of successful real upload requests:
mandatory public/event attributes, tag/field types, all stored attributes and
timestamps, exactly one occurrence of each selected UUID, and removal of those
exact UUIDs from the pending database. Only the upload package prefix added to
`sdk_data_id` may differ from the stored record.

Uploaded events must share the expected app/session/user context. Actions,
Resources, Errors and long tasks must refer to uploaded parent Views/Actions;
parent counters must include those children. Every failed Resource must have
exactly one uploaded network Error with the same `resource_id`, URL, method,
status, timestamp and Session/View/Action identifiers. Error stacks are required
for transport failures. The error-target override is restored after each case.
This verifies client upload and acknowledgement; server-side
indexing is checked separately using `ft_e2e_run`.

Build and install **both** the Demo HAP and its test HAP. Installing only
`ft_sdk_test` does not provide the Demo's `EntryAbility`.

```bash
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap
node /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
hdc shell aa force-stop com.guance.hm.example
hdc shell aa test -b com.guance.hm.example -m entry_test \
  -s unittest OpenHarmonyTestRunner -s class RumUploadE2EUITest \
  -s timeout 150000 -w 450 \
  -s entryUploadE2EEnabled true \
  -s autoSync false -s localDataFilterEnabled false -s remoteConfigTestEnabled false \
  -s logSamplingRate 1 -s rumSamplingRate 1 -s errorSamplingRate 1 -s traceSamplingRate 1 \
  -s datakitUrl YOUR_DATAKIT_URL \
  -s appId YOUR_RUM_APP_ID \
  -s resourceTestUrl YOUR_HTTP_200_GET_URL \
  -s entryResourceErrorUrl YOUR_HTTP_500_GET_URL
```

In DevEco Instrument Test, use the same test arguments and a **150-second**
case timeout. For Dataway, replace `datakitUrl` with `datawayUrl` and
`clientToken`. Use a test installation: UI cases clear the Demo's pending
telemetry by default unless the cleanup/keep-data arguments above disable it. Failed E2E records remain available
for diagnosis if the SDK retains them; E2E teardown does not clear pending data.
Ordinary UI cases and the native worker case initialize the
Demo in their own suite hooks; no root fixture, SDK reinstallation or original
configuration restoration is involved.

## Release Checklist

- Pass the HarmonyOS on-device RUM gate and the required module/build checks before releasing the core SDK.
- Ensure package names, versions, descriptions, author, and license in each module `oh-package.json5` are correct before `ohpm publish`.
- Keep the published version compliant with semantic versioning.
- Verify dependency versions stay aligned. In particular, `@guancecloud/ft_sdk_ext` should depend on the same `@guancecloud/ft_sdk` version that is being released.
- Confirm the public documentation page is ready and matches the published package behavior.
- Clean local build artifacts such as `build/` and `oh_modules/` from the release package or release branch if they are not meant to be shipped.
- Recheck compatibility claims against the demo project settings before release.

## Documentation

[Documentation Center](https://docs.guance.com/real-user-monitoring/harmonyos/app-access/)
