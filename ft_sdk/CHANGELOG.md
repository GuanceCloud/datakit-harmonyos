# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [0.1.14] - 2026-07-17
- Released the stable `ft_sdk` 0.1.14 package, consolidating the capabilities delivered during the 0.1.14 pre-release cycle.
- Removed high-frequency internal Debug logs from normal Error and Resource collection paths.

## [0.1.14-alpha07] - 2026-07-09
- Added `FTSDKConfig.setCompressIntakeRequests(...)`; data intake requests now use zlib-wrapped `deflate` compression by default and safely fall back to plaintext when compression is unavailable.
- Added `FTSDK.setAutoSync(...)` to enable or disable automatic cached-data upload after SDK initialization.
- Added `FTSDKConfig.setCustomSyncPageSize(...)` for custom upload page sizes; predefined sizes remain available through `setSyncPageSize(...)`.
- Added upload-only network routing configuration through `FTSDKConfig.setProxy(...)`, `setProxyAuthenticator(...)`, and `setDns(...)`.
- Changed automatic cached-data uploads to use a 10-second aggregation window, aligned with the Android SDK; manual `flushSyncData()` continues to request an immediate poll.
- Updated the internal thread-pool and serialized DB task processing to improve data consistency under high concurrency.
- Added idle reclamation for the low-frequency ANR Worker (90 seconds) and bursty Crash Worker (120 seconds); Workers are recreated on demand, and Native Crash diagnostic log collection now follows the App Crash tracking switch.
- Added configurable SDK debugging through `FTSDKConfig.setSdkLogLevel(...)` and `FTSDKConfig.setEnableInnerLogFile(...)`.

## [0.1.14-alpha06] - 2026-05-14
- Added `FTTraceConfig.setTraceHeaderHandler(...)` for custom Trace context generation after the SDK generates default Trace Headers.
- Moved RUM cache count configuration to `FTRUMConfig.setRumCacheLimitCount(...)`; Log cache count remains on `FTLoggerConfig.setLogCacheLimitCount(...)`.
- Added root `Index.ets` exports for WebView integration, advanced RCP interceptor assembly, and low-level trace interceptor types so public examples can avoid deep imports.
- Added the versioned `FTSDKExtensionBridge` integration contract for extension modules.
- Added a versioned extension contract export so `ft_sdk_ext` can avoid depending on internal `ft_sdk/src/main` paths.

## [0.1.14-alpha05] - 2026-05-11
- No changes, aligned with the ft_sdk_ext version

## [0.1.14-alpha04] - 2026-04-30
- Fixed missing dynamic attributes, including user data, during View data confirmation.
- Fixed occasional instability in randomly assigned user IDs.

## [0.1.14-alpha03] - 2026-04-14
- Split HarmonyOS NetworkKit `HttpInterceptor` APIs out of `ft_sdk` into the new `ft_sdk_ext` module so older compilers can continue consuming the core SDK.
- Kept RCP and axios compatibility auto-track helpers in `ft_sdk`, while moving `createFTHttpInterceptorChain`, `applyFTHttpTrack`, and the axios chain bridge to the extension package.
- Added shared network auto-track helpers to preserve behavior across core and extension modules without exposing new compiler-only symbols in `ft_sdk`.

## [0.1.14-alpha02] - 2026-04-10
- Added `applyFTAxiosTrack` for `@ohos/axios` versions without `interceptorChain`, 
   enabling axios auto-track through request/response interceptors.
- Kept the existing `interceptorChain`-based axios path for newer `@ohos/axios` 
   versions so compat and chain integrations can coexist.

## [0.1.14-alpha01] - 2026-04-02
- Added HTTP auto-track support based on @kit.NetworkKit interceptors.
- Added @ohos/axios auto-track support via reusable HTTP interceptor chains.
- Unified FT network tracking APIs, including RCP and HTTP helper exports.

## [0.1.13-alpha01] - 2026-03-13
- The ft_native library is decoupled from ft_sdk and will automatically capture native crashes based on the dependency situation.
- ft_native:>=0.1.0-alpha02

## [0.1.12-alpha01] - 2026-02-09

### Fixed

#### JavaScript Crash Duplicate Reporting
- **Fixed JavaScript crashes being reported as native crashes**: JavaScript errors were incorrectly passed from `ft_native` to `ft_sdk` and reported as `native_crash`
  - Root cause: `ft_native` module's `FTNativeCrashHandler` was forwarding all crash events (including JS crashes) to ArkTS layer
  - Fix: Added crash type filtering in `FTNativeCrashHandler.cpp` to skip `crash_type: "JsError"` events
  - JavaScript crashes are now only handled by `errorManager` (reported as `crash`)
  - Native crashes (SIGSEGV, SIGABRT, etc.) are handled by `FTNativeCrashAdapter` (reported as `native_crash`)
  - See `ft_native/CHANGELOG.md` for detailed C++ layer changes


## [0.1.11-alpha01] - 2025-12-30

### Fixed

#### Resource ID Uniqueness
- **Fixed non-unique `resourceId` causing `rum_action` data residue**: Fixed critical issue where concurrent HTTP requests to the same URL would share the same `resourceId`, causing `resourceActionMap` entries to be overwritten
  - Changed `resourceId` generation from `${method}_${url}` to `${method}_${url}_${uuid}` format
  - Each HTTP request now generates a unique UUID using `Utils.generateUUID()` to ensure uniqueness
  - `RCPTraceInterceptor` (executes first) generates UUID and stores it in `X-FT-Resource-ID` header
  - `RCPResourceInterceptor` (executes second) reads UUID from header to reuse the same `resourceId`
  - Ensures both interceptors use the same `resourceId` for proper trace handler correlation
  - Aligned with Android SDK: Android uses `ResourceID` tag with UUID when available, otherwise falls back to URL-based ID
  - Prevents `resourceActionMap` from being overwritten when multiple requests use the same URL concurrently
  - Fixes `rum_action` data residue issue where actions could not be closed because `pending_resource` was never decremented due to incorrect `actionId` fallback

#### Resource Action Mapping
- **Fixed `resourceActionMap` cleanup and memory management**: Improved `resourceActionMap` lifecycle management
  - Added size limit check (`Constants.MAX_MAP_SIZE_RESOURCE`) before adding new entries to prevent memory leaks
  - Map entries are automatically deleted after resource processing completes
  - Prevents unbounded growth of `resourceActionMap` in high-load scenarios
  - Ensures correct `actionId` fallback when `ResourceBean` is deleted before `stopResource` is called

### Improved

#### Resource ID Generation
- **Improved resource ID generation mechanism**: Enhanced resource ID generation to ensure uniqueness and interceptor coordination
  - `RCPTraceInterceptor` generates UUID and stores it in request headers for `RCPResourceInterceptor` to reuse
  - Both interceptors now use the same `resourceId`, ensuring trace handler and resource tracking are properly correlated
  - Added detailed logging for UUID generation and reuse to aid debugging
  - Improved error handling: if UUID is not found in header (shouldn't happen), generates new UUID as fallback

## [0.1.10-alpha01] - 2025-12-29

### Fixed

#### Database Data Residue Issues
- **Fixed `sync_data_flat` table data residue**: Fixed issue where data in `sync_data_flat` table occasionally remained after upload
  - Fixed `deleteFtOperation` method: Changed from synchronous `DataBaseCallBack` to asynchronous `AsyncDataBaseCallBack`
  - Added `await` for each `rdbStore.delete()` operation to ensure deletions complete before returning
  - Added deletion count tracking to verify actual deletion success
  - Added warning logs when deletion count doesn't match expected count
  - Aligned with Android SDK: data deletion now properly waits for completion

- **Fixed `rum_action` table data residue**: Fixed issue where closed actions with `pending_resource > 0` remained in database
  - Fixed `cleanCloseActionData` method: Changed from synchronous `DataBaseCallBack` to asynchronous `AsyncDataBaseCallBack`
  - Added `await` for each `rdbStore.delete()` operation to ensure deletions complete
  - Added deletion count tracking and warning logs for mismatched deletion counts
  - Aligned with Android SDK: action data deletion now properly waits for completion

#### Long Task Start Time
- **Fixed long task start time being earlier than action start time**: Fixed logical inconsistency where longtask `start_time` could precede its associated action's `start_time`
  - Modified `addLongTask` method in `FTRUMInnerManager.ets` to ensure longtask start time is not earlier than action start time
  - Added check: if longtask is associated with an active (not closed) action, its calculated `start_time` is adjusted to be no earlier than the action's `start_time`
  - Added warning log when adjustment occurs
  - Prevents logical inconsistency in RUM data timeline

#### View Data Residue
- **Fixed `rum_view` table data residue**: Fixed issue where closed views with `pending_resource > 0` remained in database
  - Removed `data_upload_time > 0` condition from `cleanCloseViewData` deletion predicates (aligned with Android SDK)
  - Added stale view cleanup: deletes closed views older than 5 minutes even if `pending_resource > 0`
  - Prevents data residue in stress test scenarios where resources may never complete

### Added

#### Action Pending Resource Management
- **Added action pending resource delayed cleanup mechanism**: Implemented delayed cleanup for actions with pending resources
  - Added `getActionPendingResource(actionId)` method to get action's `pending_resource` count
  - Added `forceClearActionPendingResource(actionId)` method to force clear action's `pending_resource` to 0
  - Modified `closeAction` method to schedule delayed cleanup: when action is closed with `pending_resource > 0`, waits 30 seconds then forces clear if still > 0
  - Aligned with view cleanup mechanism: both view and action now use 30-second delayed cleanup
  - Prevents action data residue when resources never complete (e.g., network failures, timeouts)

#### View Pending Resource Management
- **Added view pending resource delayed cleanup mechanism**: Implemented delayed cleanup for views with pending resources
  - Added `getViewPendingResource(viewId)` method to get view's `pending_resource` count
  - Added `forceClearViewPendingResource(viewId)` method to force clear view's `pending_resource` to 0
  - Modified `closeView` method to schedule delayed cleanup: when view is closed with `pending_resource > 0`, waits 30 seconds then forces clear if still > 0
  - Prevents view data residue when resources never complete

### Improved

#### Database Operation Reliability
- **Improved database deletion reliability**: All database deletion operations now properly await completion
  - Changed all deletion callbacks from `DataBaseCallBack` to `AsyncDataBaseCallBack` where needed
  - Added proper `await` for all `rdbStore.delete()` operations
  - Added deletion count verification to detect and log deletion failures
  - Improved error handling and logging for database operations

## [0.1.9-alpha01] - 2025-12-25

### Fixed

#### SDK Package Info Format
- **Fixed `sdk_pkg_info` format alignment with Android SDK**: Unified JSON string format to match Android SDK behavior
  - Fixed comma escaping: commas in JSON strings are now properly escaped with spaces (e.g., `{\"agent\":\"0.1.9-alpha01\"\,\ "native\":\"1.1.2\"}`)
  - Fixed quote escaping: quotation marks in JSON strings are now properly escaped (e.g., `{\"agent\":\"0.1.9-alpha01\"}`)
  - Fixed space escaping: spaces after commas are now properly escaped in line protocol format
  - Aligned with Android SDK: `sdk_pkg_info` format now matches Android SDK exactly, including proper escaping of commas, spaces, and quotation marks

#### HTTP Error Data Generation
- **Fixed HTTP 4xx/5xx errors not generating RUM error data**: HTTP error status codes (400, 401, 500, etc.) now correctly generate RUM error data
  - Added logic to call `addResourceError` when `resourceStatus >= 400` or `resourceStatus === 0 && errorStack`
  - Aligned with Android SDK: HTTP errors now generate both resource data and error data
  - Fixed `error_message` format for HTTP errors: now uses concise format `[status][url]` (e.g., `[400][https://api.example.com/status/400]`)
  - Fixed response body handling: response body is now placed in `error_stack` field instead of `error_message`
  - Aligned with Android SDK: error message format and response body placement now match Android behavior

#### Trace Header Generation
- **Fixed duplicate trace headers for `ZIPKIN_SINGLE_HEADER`**: Resolved issue where `ZIPKIN_SINGLE_HEADER` was generating both `b3` and `X-B3-*` headers simultaneously
  - Fixed `RCPResourceInterceptor.intercept()` logic to explicitly handle `zipkin_single_header` type
  - `ZIPKIN_SINGLE_HEADER` now only generates `b3` header (format: `traceId-spanId-sampled`)
  - `ZIPKIN_MULTI_HEADER` correctly generates `X-B3-TraceId`, `X-B3-SpanId`, and `X-B3-Sampled` headers
  - Fixed trace type mapping in `RCPTraceInterceptor` to use enum directly instead of string conversion
  - Added `getTraceTypeEnum()` method in `FTTraceConfigManager` to return raw `TraceType` enum for accurate type checking
  - Aligned with Android SDK: trace header generation now correctly handles all trace types without duplicates

#### Trace Sampling Rate Zero Behavior
- **Fixed trace sampling rate zero behavior**: When `setSamplingRate(0)` is set, trace headers are still generated but marked as "not sampled"
  - Removed early return for `!this.enableTrace` in `getTraceHeader` to ensure headers are always generated
  - Headers are now generated with appropriate "not sampled" flags (e.g., `sampled=0` for Zipkin, `sampling-priority=0` for DDTRACE)
  - Aligned with Android SDK: trace headers are always generated regardless of sampling rate, with correct sampled flags

#### Trace Interceptor Duplicate Prevention
- **Fixed duplicate trace header injection**: Added logic to prevent duplicate header generation when headers already exist
  - Added `hasTraceHeaders()` helper method in `FTTraceInterceptor` to check for existing trace headers
  - Modified `interceptRequest` to check for existing headers before generating new ones
  - Prevents duplicate trace headers in request headers when multiple interceptors are involved

#### WebView Data Transmission
- **Fixed WebView data not being transmitted via JS bridge**: Uncommented `FTWebViewHandler.setWebView()` calls in `WebViewPage.ets`
  - WebView data is now correctly transmitted from WebView to native SDK via JavaScript bridge
  - Fixed missing `web` version in `sdk_pkg_info` for browser logs
  - Aligned with Android SDK: WebView data collection now works correctly

#### Resource Test Page Scrolling
- **Fixed Resource Test Page scrolling issue**: Fixed issue where Resource Test Page could not scroll to the bottom
  - Modified `Scroll` component layout to use `layoutWeight(1)` for proper height allocation
  - Added `width('100%')` for content `Column` to ensure proper width
  - Added `enableScrollInteraction(true)` to enable scrolling interaction
  - Resource Test Page now correctly scrolls to show all content

### Changed

#### Trace Test Page UI
- **Improved Trace Test Page UI**: Replaced `Select` component with `Radio` buttons for trace type selection
  - Changed from dropdown `Select` to `Radio` buttons within `RadioGroup` for better user experience
  - Trace type selection is now more intuitive and visible
  - Removed unused `TraceTypeSelectOption` interface

#### Trace Test Page Simplification
- **Simplified Trace Test Page test logic**: Removed comprehensive loops that tested all trace types
  - Each test button now only tests the currently selected trace type (via Radio buttons)
  - Removed loops from `testSamplingRateZero`, `testTraceTypes`, `testTraceManagerAPI`, `testTraceIDGeneration`, and `testRCPRequestWithTraceHeaders`
  - Added helper functions for generic verification: `verifyTraceIDFormat`, `extractTraceId`, `extractSpanId`, `verifySamplingRateZeroHeaders`
  - Test page is now simpler and more focused, allowing users to test one trace type at a time

#### Trace Test Page URL Standardization
- **Unified all HTTP request URLs in Trace Test Page**: All test functions now use the same URL
  - Added support for test tracing functionality
  - Standardized URL across all trace test functions for consistency

#### Trace Test Page Hardcoded Trace Types
- **Fixed hardcoded trace types in test functions**: All test functions now use the selected trace type
  - `testHttpClientWithTrace()`: Changed from `TraceType.DDTRACE` to `this.selectedTraceType`
  - `testTraceManagerAPI()`: Changed from `TraceType.DDTRACE` to `this.selectedTraceType`, made header verification generic
  - `testTraceIdInResourceData()`: Changed from `TraceType.DDTRACE` to `this.selectedTraceType`, made ID extraction generic
  - `testSamplingRate()`: Changed from `TraceType.DDTRACE` to `this.selectedTraceType`
  - `testSamplingRateZero()`: Changed initial test case to use `this.selectedTraceType`
  - All test functions now respect user's trace type selection

### Added

#### Trace Configuration Re-initialization
- **Added trace interceptor re-initialization on config update**: When `installTraceConfig` is called and auto-trace is enabled, trace interceptor is re-initialized
  - Ensures trace configuration changes are immediately applied
  - Aligned with Android SDK: trace configuration updates now take effect immediately

#### Package Utils
- **Added PackageUtils for native library detection**: Created utility functions for native library support detection
  - Added `isNativeLibrarySupport()` stub implementation
  - Added `getNativeLibVersion()` stub implementation
  - Provides foundation for future native library integration

### Improved

#### Trace Header Processing
- **Enhanced trace header processing logic**: Improved trace header generation and processing
  - Added clarifying comments in `addSamplingHeaders` and `generateZipkinSingleHeader`
  - Added defensive checks to ensure `ZIPKIN_SINGLE_HEADER` only generates `b3` header
  - Improved trace type enum handling to avoid string-to-enum conversion issues

#### Error Data Processing
- **Improved error data processing for HTTP errors**: Enhanced error data generation for HTTP 4xx/5xx responses
  - Added error timeline tracking
  - Added `error_situation` field for HTTP errors
  - Added RUM association tags for error data
  - Added `resource_url_path` field for error data
  - Improved error message format to be concise and consistent

#### Code Quality
- **Improved code organization and maintainability**: Enhanced code structure and documentation
  - Added helper methods for trace ID/span ID extraction and verification
  - Improved error handling and logging
  - Better separation of concerns in trace test page

## [0.1.8-alpha01] - 2025-12-17

### Added

#### Long Task Monitoring
- **Enhanced stack trace extraction for long tasks**: Added support for extracting `heaviest_stack` parameter from `MAIN_THREAD_JANK` system events
  - Priority order: `heaviest_stack` > `exception` > `stackTrace` > `stack` > `trace`
  - Added detailed logging for debugging stack trace extraction
  - Improved stack trace information when `MAIN_THREAD_JANK` events are received from the system

#### Error Reporting
- **Automatic stack trace capture for long tasks**: When `addLongTask` is called with a descriptive string instead of a stack trace, the SDK now automatically captures the current stack trace
  - Detects if the provided `log` parameter is a stack trace or a description string
  - Automatically appends stack trace to description strings
  - Falls back to `Error().stack` when no stack information is provided

#### Hot Start Detection
- **Hot start (warm start) support**: Added hot start detection and reporting, aligned with Android SDK behavior
  - Added sleep detection: app going to background for 10 seconds is considered as sleep
  - Added hot start time tracking: records start time when app returns from background
  - Calculates hot start duration from `onAbilityForeground` to `onAbilityWindowStageCreate`
  - Reports hot start as `launch_hot` action type with accurate duration and start time
  - Aligned with Android SDK: `LifeCircleTraceCallback.DELAY_SLEEP_MILLIS = 10000ms`

#### View State Tracking
- **Active view upload support**: Modified view upload logic to support `is_active` field tracking
  - Now uploads both closed views (`is_close=1`) and active views (`is_close=0`)
  - Closed views: uploaded when closed to get final counts
  - Active views: uploaded periodically to show `is_active=true`
  - Allows tracking view state changes (`is_active=true` when active, `is_active=false` when closed)

#### ANR Stack Trace Enhancement
- **Improved ANR stack trace extraction**: Enhanced ANR event processing to extract more useful stack information
  - Added extraction of main thread stack from `params.threads` array
  - Added support for reading `external_log` files when available
  - Added detailed parameter logging for debugging ANR events
  - Improved stack trace formatting with thread information

### Fixed

#### Error Fields
- **Fixed missing `error_situation` field**: Ensured `error_situation` is always set in error logs, even when `errorTagsData.error_situation` is `undefined`, `null`, or empty
  - Added fallback to `state.toString()` when `error_situation` is not provided
  - Improved conditional check to use explicit `!== undefined && !== null` comparison

#### Long Task Stack Trace
- **Fixed `long_task_stack` field content**: Improved handling of long task stack traces
  - When `log` parameter is empty, automatically captures current stack trace
  - When `log` parameter is a description string, appends stack trace to the description
  - When `log` parameter is already a stack trace, uses it as-is
  - Added detection logic to distinguish between stack traces and description strings

#### View Data Deduplication
- **Fixed view data deduplication issue**: Improved view data deduplication logic to prevent incorrect deduplication
  - Changed from using only `view_id` to using `view_id + view_update_time` as unique identifier
  - This is critical because the same `view_id` can have multiple versions:
    - `view_update_time=1`: `is_active=true` (when view is created)
    - `view_update_time=2`: `is_active=false` (when view is closed)
  - Without `view_update_time`, the closed view would be incorrectly deduplicated as a duplicate
  - Prevents data loss when the same view is created and closed multiple times

#### Action Property Handling
- **Fixed action property not being uploaded**: Fixed issue where properties passed to `addActionWithProperty` were not included in uploaded action data
  - Fixed `convertToActionBean()` method to copy properties from `ActiveActionBean.property` to `ActionBean.extraAttr`
  - Fixed `setProperty()` method to merge properties (aligned with Android's `putAll` behavior) instead of replacing
  - Added PropertyWrapper handling in `insertAction()` and `closeAction()` to extract `value` field from PropertyWrapper objects (ArkTS compatibility layer)
  - Aligned property processing mechanism with Android SDK:
    - Android: `activeAction.getProperty().putAll(property)` → `bean.property = this.property` → `new HashMap<>(bean.getProperty())`
    - HarmonyOS: `setProperty(property)` (merge) → `convertToActionBean()` (copy to extraAttr) → `insertAction()` (extract and convert)
  - Property values are now correctly uploaded as fields in action data (supports string, number, boolean, and complex objects via JSON.stringify)

### Improved

#### UI Block Detection
- **Enhanced `MAIN_THREAD_JANK` event handling**: Improved extraction of stack trace information from system events
  - Added support for `heaviest_stack` parameter (most reliable, provided by system)
  - Added support for `exception` parameter parsing
  - Added detailed logging for all available event parameters
  - Added logging for stack trace extraction results

#### Hot Start Logging
- **Enhanced hot start logging**: Improved logging for hot start detection and upload
  - Added INFO level logging for hot start calculation and upload
  - Added detailed duration and start time logging
  - Changed log level from DEBUG to WARN when RUM or action tracking is disabled

#### Code Quality
- **Added comprehensive debug logging**: Enhanced logging throughout the long task and error reporting flow
  - Added `<FT-LONGTASK-TEST>` debug tags for long task processing
  - Added `<FT-UI-BLOCK>` debug tags for UI block detection
  - Added parameter availability logging for `MAIN_THREAD_JANK` events
  - Added detailed ANR parameter logging for debugging

### Technical Notes

#### Platform Limitations
- **HarmonyOS stack trace limitations**: Documented the differences between Android and HarmonyOS in stack trace acquisition
  - Android: Can use `Thread.getAllStackTraces()` to get all thread stacks
  - HarmonyOS: No equivalent API available; relies on system events (`MAIN_THREAD_JANK`) for stack information
  - `Error().stack` in HarmonyOS only shows current execution point, not full async call chain

#### Event Configuration
- **`MAIN_THREAD_JANK` event behavior**: 
  - System triggers: >150ms generates sample stack, >450ms generates Trace file
  - SDK subscribes to these events to get `heaviest_stack` parameter
  - Timer-based detection is used as fallback when system events are not triggered

#### Hot Start Implementation
- **Hot start detection mechanism**:
  - Sleep detection: app in background for 10 seconds is considered sleep
  - Hot start: when app returns from background after sleep, it's a hot start
  - Duration calculation: from `onAbilityForeground` to `onAbilityWindowStageCreate`
  - Aligned with Android SDK: `LifeCircleTraceCallback.DELAY_SLEEP_MILLIS = 10000ms`

## [0.1.7-alpha01] - 2025-12-08

### Fixed
- **RUM Count Fields Database Updates**: Fixed issue where view and action count fields (error_count, resource_count, long_task_count, action_count) were not updated in database
  - Implemented atomic SQL updates for all RUM count fields in `FTDBManager`
  - **View-level counts**: Added `increaseViewError()`, `increaseViewResource()`, `increaseViewLongTask()`, `increaseViewAction()` methods with atomic SQL updates
  - **Action-level counts**: Added `increaseActionError()`, `increaseActionResource()`, `increaseActionLongTask()` methods for action-level counts
  - Changed from read-modify-write pattern to atomic SQL `UPDATE ... SET count = count + 1` to prevent race conditions
  - Ensured `FTRUMInnerManager.increaseErrorCount()`, `increaseResourceCount()`, `increaseLongTaskCount()`, and `increaseActionCount()` call database update methods
  - Fixed view count fields: `view_error_count`, `view_resource_count`, `view_long_task_count`, `view_action_count` are now accurately maintained
  - Fixed action count fields: `action_error_count`, `action_resource_count`, `action_long_task_count` are now accurately maintained
  - Aligned with Android SDK behavior: all count fields are now accurately maintained through atomic database operations
- **ANR Detection Threshold**: Fixed ANR detection threshold from 8 seconds to 5 seconds
  - Changed `ANR_THRESHOLD_MS` from 8000 to 5000 in `ANRDetector.ets`, `APMSubscriptionManager.ets`, `PerformanceMonitor.ets`, and `ANRWorker.ets`
  - Aligned with HarmonyOS system behavior: system crashes at 5 seconds, so detection threshold must be 5 seconds to catch ANR before crash
  - Ensures ANR detection occurs before system terminates the application
- **UI Block Detection Logic**: Fixed UI block detection to align with Android SDK behavior
  - Removed 5-second ANR threshold check in UI block detection
  - All UI blocks exceeding threshold (default 1 second) are now reported as `long_task`, regardless of duration
  - Aligned with Android SDK: UI block detection and ANR detection are separate mechanisms
  - UI block detection reports all blocking events as `long_task` (1s, 3s, 5s, 10s, etc.)
  - ANR detection is handled separately by `ANRDetector` with its own 5-second detection cycle

### Changed
- **ANR Error Type Naming**: Unified ANR error type naming to align with Android SDK
  - System-detected ANR (via `APP_FREEZE` event): `error_type=anr_crash`, `error_message=harmony_anr`
  - Custom-detected ANR (via `ANRDetector`): `error_type=anr_error`, `error_message=harmony_anr`
  - Aligned with Android SDK: `anr_crash` for system-detected ANR, `anr_error` for custom-detected ANR
- **UI Block Periodic Reporting**: Improved UI block reporting to support periodic reporting during continuous blocking
  - Implemented periodic reporting: reports `long_task` every threshold interval (default 1 second) during continuous blocking
  - Added `blockingStartTime`, `lastReportTime`, and `isBlocking` state variables to track blocking periods
  - When blocking starts, records start time and begins periodic reporting
  - During continuous blocking, reports `long_task` every threshold interval until blocking ends
  - When blocking ends, resets state and logs total blocking duration
  - Aligned with Android SDK behavior: periodic reporting during long blocking periods
- **UI Block Logging Optimization**: Optimized UI block detection logging verbosity
  - Changed delay logging threshold from 50ms to 500ms to reduce log spam
  - Changed log level from DEBUG to WARN for significant delays (>= 500ms)
  - Reduced unnecessary log output during normal operation while retaining important warnings

### Added
- **RUM Data Test Page**: Added comprehensive RUM data testing page
  - Created `RUMDataTestPage.ets` with buttons to send resource, error, and long task data
  - Added navigation button in main `Index.ets` page
  - Added route configuration in `main_pages.json`
  - Provides easy testing interface for RUM data collection functionality
- **MAIN_THREAD_JANK Event Subscription**: Integrated HarmonyOS system-level main thread timeout detection
  - Added `subscribeToMainThreadJankEvents()` method to subscribe to `MAIN_THREAD_JANK` events via `hiAppEvent.addWatcher`
  - Added `handleMainThreadJankEvents()` and `handleMainThreadJankEvent()` to process received events
  - Extracts `durationMs` and `stackTrace` from event parameters
  - Reports `MAIN_THREAD_JANK` events as `long_task` if duration exceeds threshold (default 1 second)
  - Provides system-level detection complement to timer-based detection
  - System triggers: >150ms generates sample stack, >450ms generates Trace file
  - Note: This is a supplementary mechanism; timer-based detection remains the primary method

### Improved
- **UI Block Detection Robustness**: Enhanced UI block detection error handling
  - Improved `getStackTrace()` method with better error handling and fallback mechanisms
  - Added independent try-catch blocks for `addLongTask()` calls to prevent crashes during prolonged UI blocks
  - Enhanced stack trace capture with multiple fallback strategies
  - Prevents crashes during 5-second or longer UI blocks
- **Database Count Field Accuracy**: Improved accuracy of RUM count fields (error_count, resource_count, long_task_count)
  - Atomic SQL updates ensure count fields are always accurate, even under high concurrency
  - Prevents race conditions where async count updates might overwrite correct values
  - Count fields are now reliably maintained in both memory and database

## [0.1.6-alpha01] - 2025-11-30

### Fixed
- **View Data Upload on App Exit**: Fixed issue where view data was not uploaded when app exits from the first page
  - Added `stopView()` call in `EntryAbility.onBackground()` to ensure view data is processed when app enters background
  - Added `stopView()` call in `EntryAbility.onDestroy()` to ensure view data is processed when app is destroyed
  - Aligned with Android SDK behavior: `onActivityPaused()` calls `stopView()` to ensure view data is processed even if user stays on the first page
  - This fixes the issue where the first page's view data was not uploaded after app restart if user never navigated away from the first page
- **StopView Idempotency**: Added idempotency check in `FTRUMInnerManager.stopView()` to prevent duplicate processing
  - Added check for `activeView.isClose()` before processing
  - If view is already closed, `stopView()` returns early without duplicate processing
  - Prevents duplicate database operations and data processing when `stopView()` is called multiple times (e.g., from `onBackground()` and `onDestroy()`)
  - Ensures safe multiple calls to `stopView()` without side effects
- **Memory Leak Prevention**: Fixed memory leaks in high-load scenarios during stress testing
  - Added size limits and cleanup mechanisms for Set and Map collections to prevent unbounded growth
  - Implemented categorized size limits for different collection types (upload deduplication, action/view tracking, resource monitoring, database insertion, click tracking)
  - Added periodic cleanup in session timer and real-time size checks before insertion
  - Collections are now trimmed when exceeding limits, keeping only the most recent 50% of entries
  - Fixed memory overflow issues during 10-30 minute stress tests
- **Log Queue Processing**: Fixed infinite loop and memory issues in `TrackLogManager.processQueue()`
  - Implemented dual-queue design (inputQueue and processingQueue) to isolate producer and consumer
  - Added atomic queue switching to create processing snapshots
  - Removed artificial timeout limits that caused premature exits
  - Prevents log queue accumulation and memory overflow under high load
- **Database Batch Insertion**: Optimized database insertion performance
  - Refactored `FTDBManager.insertFtOptList()` to use native `rdbStore.batchInsert()` for true bulk insertion
  - Changed from one-by-one insertion to batch insertion, significantly improving write performance
  - Updated callback mechanism to `AsyncDataBaseCallBack` to handle asynchronous batch operations
- **Upload Task Scheduling**: Fixed upload task stuck issue in `DataUploadThreadPool`
  - Added timeout mechanism (`SCHEDULE_TIMEOUT`) to detect and reset stuck tasks
  - Immediately reset `isScheduled` flag at the start of task execution to prevent stuck state
  - Fixed issue where upload tasks were not executing despite "Data available" logs

### Changed
- **Upload Speed Optimization**: Significantly improved data upload speed
  - Reduced upload interval (`SLEEP_TIME`) from 10 seconds to 2 seconds
  - Increased upload batch size (`pageSize`) from 30 to 100 items per batch
  - Updated `TrackLogManager.DEFAULT_BATCH_SIZE` from 20 to 100
  - Upload capacity increased from ~6% to ~60% of generated data during stress tests
- **Memory Collection Size Limits**: Optimized collection size limits based on stress test analysis
  - `MAX_SET_SIZE_UPLOAD`: 10000 (for uploaded data deduplication)
  - `MAX_SET_SIZE_ACTION`: 5000 (for action deduplication)
  - `MAX_SET_SIZE_VIEW`: 1000 (for view deduplication)
  - `MAX_MAP_SIZE_RESOURCE`: 1000 (for resource monitoring)
  - `MAX_MAP_SIZE_DB`: 5000 (for database insertion deduplication)
  - `MAX_MAP_SIZE_CLICK`: 2000 (for click event deduplication)
  - `MAX_QUEUE_SIZE_LOG`: 1000 (for log queue)
  - These limits balance memory usage and cleanup frequency, reducing memory fragmentation
- **Log Verbosity Reduction**: Significantly reduced log output for better performance
  - Removed high-frequency DEBUG logs from multiple components (`SyncTaskManager`, `TrackLogManager`, `DataUploadThreadPool`, `FTRUMInnerManager`, `FTTrackInner`, `FTDBManager`, `FTActionTracker`, `EventConsumerThreadPool`, `UnifiedConsumerThreadPool`, `SmartThreadPool`, `AdaptiveThreadPool`, `NetworkUtils`)
  - Consolidated multi-line upload logs into single-line format
  - Removed verbose deduplication logs, detailed step-by-step processing logs, and repetitive thread interruption logs
  - Retained only critical ERROR, WARN, and key INFO logs (e.g., `Upload SUCCESS`, `UPLOAD-STATS`)

### Added
- **Stress Test Infrastructure**: Added comprehensive stress testing infrastructure
  - Created `StressTestManager` singleton class for managing concurrent data generation
  - Supports 6 concurrent threads: 2 Log threads (50ms interval), 2 Action threads (20ms interval), 2 Resource threads (200ms interval)
  - Provides `run()`, `stop()`, `getElapsedSeconds()`, and `isStressTestRunning()` methods
  - Supports configurable test duration with auto-stop mechanism
- **Stress Test Pages**: Added stress test navigation pages
  - Created `RealAppStressTestPage` with start/stop controls and real-time elapsed time display
  - Created `StressTestAPage` and `StressTestBPage` for testing page navigation and view tracking
  - Implemented automatic loop navigation between pages using `router.replaceUrl()` to prevent page stack overflow
  - Auto-navigation stops when `StressTestManager` stops or when user clicks Back button
  - Added crash button for testing crash handling and view data upload
- **Memory Leak Debugging Tools**: Added memory leak debugging infrastructure
  - Created `MemoryMonitor` utility for real-time memory usage tracking and growth rate calculation
  - Created `MemoryLeakDebugPage` with UI controls to start/stop monitoring and toggle SDK modules for isolation
  - Supports disabling/enabling individual SDK modules (RUM, Log, Sync, Monitor, Network, Event) for debugging
  - Added base components control to stop core SDK background tasks (Network, Crash, Event, Sync)
- **Collection Size Management**: Added comprehensive collection size management
  - Consolidated all size limits into `Constants.ets` for centralized management
  - Implemented categorized size limits for different collection types
  - Added cleanup strategies (keep 50% of entries when trimming) to balance memory and performance
  - Added real-time size checks before insertion and periodic cleanup in session timer

### Improved
- Enhanced view lifecycle management to handle edge cases where view is already closed
  - Improved logging to indicate when duplicate `stopView()` calls are skipped
  - Better handling of app lifecycle transitions (foreground/background/destroy)
- **Stress Test Stability**: Improved stability during long-duration stress tests (10-30 minutes)
  - Fixed memory overflow issues through collection size limits and cleanup mechanisms
  - Improved upload speed to prevent data accumulation
  - Enhanced log processing reliability with dual-queue design
  - Reduced log verbosity to improve performance under high load
- **Database Performance**: Improved database write performance
  - Batch insertion significantly reduces database write time
  - Better handling of high-frequency data insertion scenarios
- **Upload Performance**: Improved upload throughput and reliability
  - Faster upload interval and larger batch size increase upload capacity
  - Better handling of upload task scheduling and execution
  - Reduced upload delay from 40ms to 30ms for better throughput

## [0.1.5-alpha01] - 2025-11-19

### Fixed
- **WebView Static Tags Replacement**: Fixed WebView data not using native static tags
  - Fixed issue where static tags from WebView data (e.g., `app_id`, `os`, `os_version`, `device`, `model`, `arch`, `sdk_name`, `env`, `version`, `device_uuid`, `application_uuid`, etc.) were not replaced with native SDK's static tags
  - Added logic in `initRUMConfig` to ensure `app_id` from `FTRUMConfig.getRumAppId()` is added to `rumTags`
  - All static tags in `rumTags` are now correctly used to replace WebView's corresponding tags in `RUM_WEBVIEW` data processing (except `service` which is preserved as `browser`)
  - Aligned with Android SDK behavior: WebView data now uses native static tags (app_id, os, device info, SDK info, etc.) instead of Web SDK's default values
- **sdk_pkg_info JSON Format**: Fixed JSON string format to match Android SDK
  - Added `formatJsonStringWithSpaces` method to ensure commas in JSON strings are followed by spaces (e.g., `{"web":"3.2.37", "agent":"0.1.4-alpha01"}`)
  - Fixed `parseAndAppendWebVersion` to use formatted JSON string with spaces after commas
  - Fixed `FTSDK.ets` to format `sdk_pkg_info` JSON string with spaces after commas
  - Aligned with Android SDK format: JSON strings in `sdk_pkg_info` now have spaces after commas, which are properly escaped in line protocol as `\,\ ` (comma + escaped space)
- **Environment Configuration (setEnv)**: Fixed `setEnv` method not working correctly
  - Fixed `setEnv` method to correctly handle `EnvType` enum values

### Improved
- Enhanced debugging logs for `app_id` replacement process in WebView data processing
  - Added logs to track `app_id` in `rumTags` and `mergeTags` before and after replacement
  - Added logs in `initRUMConfig` to track when `app_id` is added to `rumTags`

## [0.1.4-alpha01] - 2025-11-17

### Added
- **Action Tracking Enhancement**: Automatic click tracking now supports all UI components with `onClick` callback
  - All components with `onClick` callback (Button, Checkbox, Radio, Toggle, Text, Image, and any other components) can be automatically tracked as Action events
  - Action name format: `{ComponentType}/{id}` (e.g., `Button/button1`, `Text/text1`, `Image/image1`)
  - Supports custom action names via `customProperty` for better identification
  - Uses `willClick` event listener to capture all click events across the application
- **Documentation Updates**: Enhanced integration guide with image resource loading guidance
  - Added image resource loading section with RCP manual download approach
  - Added `setSessionErrorSampleRate` method documentation in RUM configuration section
  - Added important notice: system `Image` component cannot be monitored when loading network URLs directly
  - Added note about referencing Demo project for NetworkImage component implementation

### Fixed
- **Action Duplicate Upload Prevention**: Fixed duplicate action data upload issue
  - Added `insertedActionIds` Set to track inserted action IDs and prevent duplicate uploads
  - Ensures that even if `insertAction()` is called multiple times, the same action will only be uploaded once
  - Prevents duplicate action data in RUM reports when actions are processed multiple times

## [0.1.3-alpha01] - 2025-11-14

### Added
- **Page Lifecycle Auto-Tracking**: Enabled page lifecycle subscription to automatically call `stopView()`
  - Automatically calls `stopView()` when page switches (`navDestinationSwitch` event)
  - Automatically calls `stopView()` when page updates (`routerPageUpdate` event)
  - Aligned with Android SDK behavior: automatically closes view data when page is paused
  - Only executes when view tracking is enabled (checked via `FTSDK.isViewTrackingEnabled()`)

### Changed
- **Page Lifecycle Subscription Configuration**: Changed `enablePageLifecycle` from `false` to `true`
  - Enabled page lifecycle subscription in `FTSDK.initializeUIFeatures()`
  - Ensures view data is properly closed and uploaded when application exits

### Fixed
- **Private Property Access Issue**: Fixed compilation error when accessing private `FTSDK.rumConfig` in `HarmonyOSEventSubscription`
  - Added public method `FTSDK.isViewTrackingEnabled()` to check if view tracking is enabled
  - Encapsulated access to private `rumConfig`, improving code encapsulation

### Disabled
- **ErrorManager Feature**: Temporarily disabled ErrorManager (`FTExceptionHandler`) initialization
  - Commented out ErrorManager initialization code in `FTSDK.installRUMConfig()`
  - Crash handling falls back to original `hiAppEvent` mechanism (reported after app restart)
  - To re-enable, uncomment the related code

## [0.1.2-alpha01] - 2025-11-11

### Fixed
- **Log Data Formatting**: Fixed log data field formatting issues
  - Fixed field name escaping (spaces in field names are now properly escaped)
  - Fixed string value quoting in tags (removed unnecessary quotes)
  - Fixed StringWrapper object value extraction in `FTTrackInner.createSyncDataFromLogBean`
  - Fixed LogBean measurement field usage (now correctly uses `logBean.getMeasurement()` instead of hardcoded value)
- **RUM Tags in Logs**: Fixed RUM tags merging logic for log data
  - Fixed missing RUM tags (view_id, session_id, network_type, userid, is_signin) in log data when `isEnableLinkRumData()` is enabled
  - Aligned with Android SDK: RUM tags are now correctly merged in `SyncDataHelper.getBodyContent` for log data
- **ThreadPoolManager Initialization**: Fixed ThreadPoolManager initialization issue
  - Fixed "ThreadPoolManager has not been initialized" error when processing logs
  - Added fallback mechanism: if ThreadPoolManager is not initialized, logs are processed on main thread
  - Fixed log processing trigger after configuration updates
- **RUM View Fields**: Fixed view field names and formats to align with Android SDK
  - Fixed `time_spent` field name (was using incorrect constant)
  - Fixed `is_active` field name (was using incorrect constant)
  - Fixed `loading_time` field name (now uses `Constants.KEY_RUM_VIEW_LOAD_TIME`)
  - Fixed `view_update_time` field name (now uses `Constants.KEY_SDK_VIEW_UPDATE_TIME`)
  - Fixed device monitoring fields conditional output (CPU, Memory, Battery, FPS)
  - Fixed device monitoring fields duplication issue (removed `view_property_` prefix for device metrics)
  - Fixed missing `session_sample_rate` and `session_on_error_sample_rate` fields
- **RUM Resource Fields**: Fixed resource field names and formats to align with Android SDK
  - Fixed `resourceLoad` field calculation and field name (now uses `Constants.KEY_RUM_RESOURCE_DURATION`)
  - Fixed `resource_download_time` field name (now uses `Constants.KEY_RUM_DOWNLOAD_TIME`)
  - Fixed missing `resource_tcp`, `resource_ssl`, `resource_first_byte` fields
  - Fixed `resourceFirstByte` value (now equals `resourceTTFB` to align with Android)
  - Fixed resource performance metrics extraction from `FTHttpAutoTrack` property
  - Fixed `resourceConnectTime.start` calculation (now correctly calculates relative start times for DNS, TCP, SSL, First Byte, and Download based on their durations)
  - Fixed device and model field values (swapped `device=harmonyos` and `model=emulator` to correct values)
- **Trace ID Consistency**: Fixed trace_id inconsistency in resource request headers
  - Fixed `request_header` field to correctly capture trace headers with the same trace_id as resource data
  - Modified `RCPResourceInterceptor` to get trace_id and span_id from `FTTraceManager` handler instead of reading from `context.request.headers` (which may contain stale trace_id from previous requests)
  - Added logic to manually build trace headers from handler's trace_id/span_id to ensure consistency
  - Aligned with Android SDK: resource data trace_id and request_header trace_id are now consistent
- **RUM Action Fields**: Fixed action field formats to align with Android SDK
  - Fixed numeric field output format (now outputs as numbers without quotes when `integerCompatible` is true)
- **RUM Error Fields**: Fixed error field formats and device info collection
  - Fixed device info collection (`locale`, `carrier`, `memory_total`, `memory_use`, `cpu_use`, `battery_use`)
  - Fixed conditional device monitoring based on `ErrorMonitorType` configuration
- **RUM LongTask Fields**: Fixed longtask field names to use constants
  - Fixed `duration` field name (now uses `Constants.KEY_RUM_LONG_TASK_DURATION`)
  - Fixed `long_task_stack` field name (now uses `Constants.KEY_RUM_LONG_TASK_STACK`)
- **Time Units**: Fixed time unit consistency across all RUM data types
  - All time-related fields now use nanoseconds (aligned with Android SDK)
  - Fixed `ViewBean` time calculations (startTime, viewLoadTime, timeSpent) to use nanoseconds
  - Fixed `FTHttpAutoTrack` time conversion (milliseconds to nanoseconds for all resource timing metrics)
- **Line Protocol Format**: Fixed line protocol output format
  - Changed `integerCompatible` default value from `false` to `true` (aligned with Android SDK since 1.6.9)
  - Fixed numeric field output (now outputs as numbers without quotes when `integerCompatible` is true)
  - Fixed `getCustomHash` method to correctly parse string numbers and output them as numeric format

### Changed
- **SyncDataHelper**: Changed default value of `integerCompatible` from `false` to `true` to align with Android SDK behavior
- **ViewBean**: Changed all time calculations to use nanoseconds instead of milliseconds
  - `startTime` now uses `Utils.getCurrentNanoTime()` instead of `Date.now()`
  - `viewLoadTime` calculation now uses nanoseconds
  - `timeSpent` calculation now uses nanoseconds
- **FTHttpAutoTrack**: Changed time unit conversion for all resource timing metrics
  - All time values from RCP are now converted from milliseconds to nanoseconds
  - Removed raw `_timeInfo` storage in `resourceParams.property` (aligned with Android)

### Added
- Added `KEY_SESSION_ERROR_TIMESTAMP` constant for view error timestamp field
- Added `KEY_RUM_DOWNLOAD_TIME` constant for resource download time field
- Added `KEY_SESSION_SAMPLE_RATE` and `KEY_SESSION_ON_ERROR_SAMPLE_RATE` constants
- Added `KEY_MEMORY_TOTAL`, `KEY_DEVICE_LOCALE`, `KEY_DEVICE_CARRIER` constants for error device info
- Added `rumStaticFields` in `SyncDataHelper` to store session sampling rate fields
- Added `initRUMConfig` call in `FTSDK.installRUMConfig` to initialize `rumStaticFields`
- Added device monitoring field exclusion logic in `FTRUMInnerManager.insertView` to prevent duplication
- Added `collectDeviceInfoForError` method in `FTRUMInnerManager` to collect device info based on `ErrorMonitorType`
- Added trace header merging logic in `RCPResourceInterceptor` to get trace_id from handler and build headers manually

### Improved
- Improved log data processing reliability with ThreadPoolManager initialization checks
- Improved RUM field alignment with Android SDK (all field names now use constants)
- Improved resource performance metrics extraction and population
- Improved error handling in log processing with fallback mechanisms
- Improved trace_id consistency between resource data and request headers

## [0.1.1-alpha01] - 2025-11-10

### Changed
- **Breaking Change**: `rumCacheLimitCount` default value changed from `0` (unlimited) to `100000` to align with Android SDK
- `setRumCacheLimitCount` now enforces minimum value of `10000` (aligned with Android SDK behavior)

### Fixed
- Fixed `trace_id` inconsistency in `request_header` field of resource data. Now correctly captures the actual trace headers injected into HTTP requests
- Fixed error sampling logic (`sessionErrorSampleRate`) to align with Android SDK behavior
  - Error sampling is now only applied when normal session sampling fails
  - Fixed `checkSessionWillCollect` logic to correctly return `SAMPLING` vs `DROP` states
- Fixed `SamplingUtils.checkSessionKeep` logic to correctly check error sampling rate only when session is not collected by normal sampling

### Added
- Added logging points for error sampling data storage and conversion:
  - Log when data is stored as `RUM_APP_ERROR_SAMPLED`
  - Log when `RUM_APP_ERROR_SAMPLED` data is converted to `RUM_APP`
- Added `DEFAULT_DB_RUM_CACHE_NUM` constant (100000) and `MINI_DB_RUM_CACHE_NUM` constant (10000) in `Constants.ets`
- Added comprehensive Tracer network link tracking documentation
- Added WebView integration documentation with proper configuration guidance

### Improved
- Improved error sampling "1 minute before/after" data collection logic
- Enhanced documentation with detailed configuration examples and parameter descriptions
- Updated integration guide to align with Android SDK documentation format

## [0.1.0] - 2025-11-07

### Added
- Initial release of HarmonyOS SDK
- RUM (Real User Monitoring) functionality
  - View tracking: Automatic and manual view tracking
  - Action tracking: Automatic UI component click tracking (Button, Checkbox, Radio, Toggle)
  - Resource tracking: Automatic HTTP request tracking via RCP Interceptor
  - Error tracking: Automatic crash and ANR detection
  - LongTask tracking: Manual long task monitoring
- Log functionality
  - Custom log recording (ERROR, WARNING, INFO, DEBUG)
  - Console log capture
  - Log level filtering
  - Log association with RUM data
- Trace functionality
  - Support for multiple trace protocols: DDTRACE, ZIPKIN, JAEGER, TRACEPARENT, SKYWALKING
  - Automatic trace header injection for HTTP requests
  - Manual trace header retrieval
- WebView integration
  - WebView data collection
  - WebView and Native data association
  - JavaScript interface auto-registration
- User data binding
  - Bind user information
  - Clear user data
- Global context
  - Add custom tags for RUM and Log data
- Data synchronization
  - Automatic data sync
  - Manual data sync (flushSyncData)
- Cache management
  - Database cache limit configuration
  - RUM cache limit configuration
  - Log cache limit configuration
- Sampling rate configuration
  - RUM sampling rate
  - Error sampling rate
  - Trace sampling rate
  - Log sampling rate

### Technical Details
- Built with ArkTS
- Compatible with HarmonyOS API 5.0+
- HAR package format for easy integration
- Automatic permission handling (INTERNET, GET_WIFI_INFO, GET_NETWORK_INFO)
