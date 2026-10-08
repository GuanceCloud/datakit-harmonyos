import { ArrayList, HashMap } from "@kit.ArkTS";

export class Constants {
  static readonly LOG_TAG_PREFIX = "[FT-SDK]";
  /**
   * SDK name
   */
  static readonly SDK_NAME: String = "df_harmonyos_rum_sdk";
  /**
   * Invalid value
   */
  static readonly FT_KEY_VALUE_NULL = "null";
  /**
   * Line protocol, measurement
   */
  static readonly MEASUREMENT = "measurement";
  /**
   * Line protocol time
   */
  static readonly TIME = "time";
  /**
   * Line protocol all measurement data
   */
  static readonly FIELDS = "fields";
  /**
   * Line protocol all tag data
   */
  static readonly TAGS = "tags";
  /**
   * Final data separator
   */
  static readonly SEPARATION = " ";
  /**
   * Final data line protocol single data separator
   */
  static readonly SEPARATION_REAL_LINE_BREAK = "\n"; // Line break flag for log display

  /**
   * Sync data HTTP request header user-agent
   */
  static readonly USER_AGENT: String = Constants.SDK_NAME;
  
  /**
   * Sync data HTTP request headers for trace
   */
  static readonly SYNC_DATA_TRACE_HEADER = "X-Pkg-Id";
  static readonly SYNC_DATA_TRACE_HEADER_FORMAT = "rumm-%s";
  static readonly SYNC_DATA_DEVICE_TIME = "X-Client-Timestamp";
  static readonly SYNC_DATA_CONTENT_TYPE_HEADER = "Content-Type";
  static readonly SYNC_DATA_CONTENT_ENCODING_HEADER = "Content-Encoding";
  
  /**
   * Default log measurement name
   */
  static readonly FT_LOG_DEFAULT_MEASUREMENT = "df_rum_harmonyos_log";
  static readonly FT_RANDOM_USER_ID = "ft.user.session.id";
  static readonly FT_USER_USER_ID = "ft.user.userid";
  static readonly FT_USER_USER_NAME = "ft.user.username";
  static readonly FT_USER_USER_EMAIL = "ft.user.email";
  static readonly FT_USER_USER_EXT = "ft.user.extdata";
  /** Persisted remote configuration payload. */
  static readonly FT_REMOTE_CONFIG = "ft.localCache.remoteConfig";
  /** Persisted remote configuration fetch time, in seconds. */
  static readonly FT_REMOTE_CONFIG_FETCH_TIME = "ft.localCache.remoteConfigFetchTime";
  /** DataKit/Dataway endpoint used to fetch SDK remote configuration. */
  static readonly URL_ENV_VARIABLE = "v1/env_variable";
  /** DataKit/Dataway endpoint used to fetch remote data-filter rules. */
  static readonly URL_DATAKIT_PULL = "v1/datakit/pull";
  
  // RUM related constants
  
  /**
   * View root name
   */
  static readonly VIEW_NAME_ROOT = "root";
  /** Synthetic View used by cold and hot launch Actions, matching Android. */
  static readonly VIEW_NAME_APPLICATION_LAUNCH = "ApplicationLaunch";
  static readonly VIEW_NAME_BACKGROUND = "BackgroundView";
  static readonly VIEW_NAME_ROOT_FALLBACK = "RootView";
  
  /**
   * RUM measurement types
   */
  static readonly FT_MEASUREMENT_RUM_VIEW = "view";
  static readonly FT_MEASUREMENT_RUM_ACTION = "action";
  static readonly FT_MEASUREMENT_RUM_RESOURCE = "resource";
  static readonly FT_MEASUREMENT_RUM_ERROR = "error";
  static readonly FT_MEASUREMENT_RUM_LONG_TASK = "long_task";
  
  /**
   * RUM session identifier
   */
  static readonly KEY_RUM_SESSION_ID = "session_id";
  static readonly KEY_RUM_SESSION_TYPE = "session_type";

  /**
   * RUM view related keys
   */
  static readonly KEY_RUM_VIEW_ID = "view_id";
  static readonly KEY_RUM_VIEW_NAME = "view_name";
  static readonly KEY_RUM_VIEW_REFERRER = "view_referrer";
  static readonly KEY_RUM_VIEW_DURATION = "duration";
  static readonly KEY_RUM_VIEW_LOAD_TIME = "loading_time";
  static readonly KEY_RUM_VIEW_ACTION_COUNT = "view_action_count";
  static readonly KEY_RUM_VIEW_ERROR_COUNT = "view_error_count";
  static readonly KEY_RUM_VIEW_RESOURCE_COUNT = "view_resource_count";
  static readonly KEY_RUM_VIEW_LONG_TASK_COUNT = "view_long_task_count";
  static readonly KEY_RUM_VIEW_LONG_TASK_RATE = "view_long_task_rate";
  
  /**
   * RUM action related keys
   */
  static readonly KEY_RUM_ACTION_ID = "action_id";
  static readonly KEY_RUM_ACTION_NAME = "action_name";
  static readonly KEY_RUM_ACTION_TYPE = "action_type";
  static readonly KEY_RUM_ACTION_DURATION = "duration";
  static readonly KEY_RUM_ACTION_ERROR_COUNT = "action_error_count";
  static readonly KEY_RUM_ACTION_RESOURCE_COUNT = "action_resource_count";
  static readonly KEY_RUM_ACTION_LONG_TASK_COUNT = "action_long_task_count";
  static readonly KEY_RUM_ACTION_ERROR_IDS = "action_error_ids";
  static readonly KEY_RUM_ACTION_RESOURCE_IDS = "action_resource_ids";
  static readonly KEY_RUM_ACTION_LONG_TASK_IDS = "action_long_task_ids";
  
  /**
   * RUM resource related keys
   */
  static readonly KEY_RUM_RESOURCE_ID = "resource_id";
  static readonly KEY_RUM_RESOURCE_URL = "resource_url";
  static readonly KEY_RUM_RESOURCE_URL_HOST = "resource_url_host";
  static readonly KEY_RUM_RESOURCE_URL_PATH = "resource_url_path";
  static readonly KEY_RUM_RESOURCE_URL_QUERY = "resource_url_query";
  static readonly KEY_RUM_RESOURCE_TYPE = "resource_type";
  static readonly KEY_RUM_RESOURCE_METHOD = "resource_method";
  static readonly KEY_RUM_RESOURCE_STATUS = "resource_status";
  static readonly KEY_RUM_RESOURCE_STATUS_GROUP = "resource_status_group";
  static readonly KEY_RUM_RESOURCE_SIZE = "resource_size";
  static readonly KEY_RUM_RESOURCE_REQUEST_SIZE = "resource_request_size";
  static readonly KEY_RUM_RESOURCE_HTTP_PROTOCOL = "resource_http_protocol";
  static readonly KEY_RUM_RESOURCE_CONNECTION_REUSE = "resource_connection_reuse";
  static readonly KEY_RUM_RESOURCE_DURATION = "duration";
  static readonly KEY_RUM_RESOURCE_DNS = "resource_dns";
  static readonly KEY_RUM_RESOURCE_DNS_TIME = "resource_dns_time";
  static readonly KEY_RUM_RESOURCE_TCP = "resource_tcp";
  static readonly KEY_RUM_RESOURCE_TCP_TIME = "resource_tcp_time";
  static readonly KEY_RUM_RESOURCE_SSL = "resource_ssl";
  static readonly KEY_RUM_RESOURCE_SSL_TIME = "resource_ssl_time";
  static readonly KEY_RUM_RESOURCE_TTFB = "resource_ttfb";
  static readonly KEY_RUM_RESOURCE_TRANS = "resource_trans";
  static readonly KEY_RUM_RESOURCE_FIRST_BYTE = "resource_first_byte";
  static readonly KEY_RUM_RESOURCE_FIRST_BYTE_TIME = "resource_first_byte_time";
  static readonly KEY_RUM_RESOURCE_CONNECT_TIME = "resource_connect_time";
  static readonly KEY_RUM_RESOURCE_DOWNLOAD_TIME = "resource_download_time";
  static readonly KEY_RUM_RESOURCE_TRACE_ID = "trace_id";
  static readonly KEY_RUM_RESOURCE_SPAN_ID = "span_id";
  static readonly KEY_RUM_RESOURCE_REQUEST_HEADER = "request_header";
  static readonly KEY_RUM_RESOURCE_RESPONSE_HEADER = "response_header";
  /** Resource network snapshot fields (aligned with Android). */
  static readonly KEY_RUM_RESOURCE_NETWORK_AVAILABLE = "network_available";
  static readonly KEY_RUM_RESOURCE_NETWORK_VALIDATED = "network_validated";
  static readonly KEY_RUM_RESOURCE_NETWORK_DOWNLINK_KBPS = "network_downlink_kbps";
  static readonly KEY_RUM_RESOURCE_NETWORK_UPLINK_KBPS = "network_uplink_kbps";
  static readonly KEY_RUM_RESOURCE_NETWORK_SIGNAL_STRENGTH = "network_signal_strength";
  
  /**
   * RUM error related keys
   */
  static readonly KEY_RUM_ERROR_TYPE = "error_type";
  static readonly KEY_RUM_ERROR_SOURCE = "error_source";
  static readonly KEY_RUM_ERROR_SITUATION = "error_situation";
  static readonly KEY_RUM_ERROR_MESSAGE = "error_message";
  static readonly KEY_RUM_ERROR_STACK = "error_stack";
  static readonly KEY_RUM_ERROR_FOREGROUND_CRASH_FREE_DURATION = "foreground_crash_free_duration";
  static readonly KEY_RUM_ERROR_BACKGROUND_CRASH_FREE_DURATION = "background_crash_free_duration";
  static readonly KEY_RUM_ERROR_IS_PRE_CRASH = "is_pre_crash";
  
  /**
   * HTTP request and response headers
   */
  static readonly KEY_RUM_REQUEST_HEADER = "request_header";
  static readonly KEY_RUM_RESPONSE_HEADER = "response_header";
  static readonly KEY_RUM_RESPONSE_CONNECTION = "response_connection";
  static readonly KEY_RUM_RESPONSE_CONTENT_TYPE = "response_content_type";
  static readonly KEY_RUM_RESPONSE_CONTENT_ENCODING = "response_content_encoding";
  
  /**
   * Session replay related
   */
  static readonly KEY_HAS_REPLAY = "has_replay";
  // Public RUM Replay availability field; keep KEY_HAS_REPLAY for cached metadata.
  static readonly KEY_SESSION_HAS_REPLAY = "session_has_replay";
  static readonly KEY_SESSION_REPLAY_RECORDS_COUNT = "records_count";
  static readonly KEY_SAMPLED_FOR_ERROR_REPLAY = "sampled_on_reply_error";
  
  /**
   * Log status key
   */
  static readonly KEY_STATUS = "status";

  /**
   * RUM, user access monitoring, datakit request URL
   **/
  static readonly URL_MODEL_RUM = "v1/write/rum";
  /**
   * Log, logging, datakit request URL
   **/
  static readonly URL_MODEL_LOG = "v1/write/logging";

  /**
   * Trace related constants
   */
  static readonly FT_TRACE_DEFAULT_MEASUREMENT = "df_rum_harmonyos_trace";

  /**
   * Trace field keys
   */
  static readonly KEY_TRACE_DURATION = "duration";
  /**
   * Default service name, field service
   */
  static readonly DEFAULT_SERVICE_NAME = "df_rum_harmonyos";
  /**
   * Default database cache size limit, 100MB.
   */
  static readonly DEFAULT_CACHE_LIMIT_SIZE = 100 * 1024 * 1024;
  /**
   * Minimum database cache size limit, 30MB.
   */
  static readonly MINI_CACHE_LIMIT_SIZE = 30 * 1024 * 1024;
  /**
   * Maximum log cache limit
   */
  static readonly DEFAULT_DB_LOG_CACHE_NUM = 5000;
  /**
   * Maximum view cache limit
   */
  static readonly DEFAULT_DB_VIEW_CACHE_NUM = 1000;
  /**
   * Maximum action cache limit
   */
  static readonly DEFAULT_DB_ACTION_CACHE_NUM = 2000;
  /**
   * Minimum log cache limit
   */
  static readonly MINI_DB_LOG_CACHE_NUM = 1000;
  /**
   * Default RUM cache limit (aligned with Android: DEFAULT_DB_RUM_CACHE_NUM = 100_000)
   */
  static readonly DEFAULT_DB_RUM_CACHE_NUM = 100000;
  /**
   * Minimum RUM cache limit (aligned with Android: MINI_DB_RUM_CACHE_NUM = 10_000)
   */
  static readonly MINI_DB_RUM_CACHE_NUM = 10000;
  /**
   * Database old cache remove count (aligned with Android: DB_OLD_CACHE_REMOVE_COUNT = 100)
   */
  static readonly DB_OLD_CACHE_REMOVE_COUNT = 100;
  /**
   * Maximum size for Set collections to prevent memory leak
   * Used for deduplication Sets (e.g., uploadedDataIds, processedActionIds)
   * @deprecated Use specific size constants instead (MAX_SET_SIZE_UPLOAD, MAX_SET_SIZE_ACTION, etc.)
   */
  static readonly MAX_SET_SIZE: number = 1000; // Limit to 1k entries per Set (deprecated, kept for backward compatibility)
  /**
   * Maximum size for Map collections to prevent memory leak
   * Used for deduplication Maps (e.g., insertedDataIds, processedClickIds)
   * @deprecated Use specific size constants instead (MAX_MAP_SIZE_DB, MAX_MAP_SIZE_CLICK, etc.)
   */
  static readonly MAX_MAP_SIZE: number = 1000; // Limit to 1k entries per Map (deprecated, kept for backward compatibility)
  /**
   * Maximum size for queue collections to prevent memory leak
   * Used for log queues and other buffered data
   */
  static readonly MAX_QUEUE_SIZE: number = 1000; // Limit to 1k entries per Queue
  
  /**
   * Maximum size for uploaded data IDs Set (SyncTaskManager.uploadedDataIds)
   * This Set tracks uploaded data IDs to prevent duplicate uploads
   * Cleanup strategy: Keep 50% of entries when trimming
   * Updated: 10000 (from 3000) to reduce cleanup frequency from ~13s to ~45s
   * This reduces memory fragmentation caused by frequent cleanup operations
   */
  static readonly MAX_SET_SIZE_UPLOAD: number = 10000;
  
  /**
   * Maximum size for Action-related Sets (FTRUMInnerManager.processedActionIds, insertedActionIds)
   * These Sets track processed/inserted action IDs to prevent duplicates
   * Updated: 5000 (from 2000) to reduce cleanup frequency from ~28s to ~70s
   * This reduces memory fragmentation caused by frequent cleanup operations
   */
  static readonly MAX_SET_SIZE_ACTION: number = 5000;
  
  /**
   * Maximum size for View-related Sets (FTRUMInnerManager.processedViewIds, insertedViewIds)
   * These Sets track processed/inserted view IDs to prevent duplicates
   * View data frequency is low, so 1000 is sufficient
   */
  static readonly MAX_SET_SIZE_VIEW: number = 1000;
  
  /**
   * Maximum size for auxiliary resource-related maps.
   * Active RUM resourceBeanMap is not cleared by this limit; it is removed per resource completion.
   */
  static readonly MAX_MAP_SIZE_RESOURCE: number = 1000;
  
  /**
   * Maximum size for database insertion deduplication Map (FTDBManager.insertedDataIds)
   * This Map tracks inserted data IDs to prevent duplicate database insertions
   * Updated: 5000 (from 1500) to reduce cleanup frequency from ~15s to ~50s
   * This reduces memory fragmentation caused by frequent cleanup operations
   */
  static readonly MAX_MAP_SIZE_DB: number = 5000;
  
  /**
   * Maximum size for click event deduplication Map (FTActionTracker.processedClickIds)
   * This Map tracks processed click events to prevent duplicates
   * Click events are high frequency, but have 1-second expiration cleanup
   * Recommended: 2000
   */
  static readonly MAX_MAP_SIZE_CLICK: number = 2000;
  
  /**
   * Maximum size for log queue (TrackLogManager.logQueue)
   * Log queue is consumed quickly, 1000 is sufficient
   */
  static readonly MAX_QUEUE_SIZE_LOG: number = 1000;
  /**
   * Duration, unit nanoseconds
   */
  static readonly KEY_TIME_COST_DURATION = "duration";

  /**
   * Battery consumption percentage: 100 minus the remaining battery SOC.
   */
  static readonly KEY_BATTERY_USE = "battery_use";
  /* Page lifecycle start =======> */

  /**
   * Total memory size, device total capacity, unit GB
   */
  static readonly KEY_MEMORY_TOTAL = "memory_total";
  /**
   * Memory usage, percentage, current device total occupancy rate
   */
  static readonly KEY_MEMORY_USE = "memory_use";
  /**
   * Current application process CPU usage percentage, normalized by logical CPU cores.
   */
  static readonly KEY_CPU_USE = "cpu_use";
  /**
   * Current application's user-mode CPU clock ticks accumulated during a View.
   */
  static readonly KEY_CPU_TICK_COUNT = "cpu_tick_count";
  /**
   * Current application's user-mode CPU clock ticks per second during a View.
   */
  static readonly KEY_CPU_TICK_COUNT_PER_SECOND = "cpu_tick_count_per_second";
  /**
   * Average application resident memory during a View, in bytes.
   */
  static readonly KEY_MEMORY_AVG = "memory_avg";
  /**
   * Peak application resident memory during a View, in bytes.
   */
  static readonly KEY_MEMORY_MAX = "memory_max";
  /**
   * FPS minimum value, lower value indicates more severe stuttering
   */
  static readonly KEY_FPS_MINI = "fps_mini";
  /**
   * FPS average value, lower value indicates worse frame rate user experience
   */
  static readonly KEY_FPS_AVG = "fps_avg";
  /**
   * Average device battery current during a View, in mA.
   */
  static readonly KEY_BATTERY_CURRENT_AVG = "battery_current_avg";
  /**
   * Maximum device battery current during a View, in mA.
   */
  static readonly KEY_BATTERY_CURRENT_MAX = "battery_current_max";
  /* <======= Page lifecycle end */

  /**
   * Service name
   */
  static readonly KEY_SERVICE = "service";
  /**
   * Environment
   */
  static readonly KEY_ENV = "env";
  /**
   * Application UUID, same Build application_uuid is identical
   */
  static readonly KEY_APPLICATION_UUID = "application_uuid";

  static readonly KEY_APP_VERSION_NAME = "version";
  /**
   * SDK name used, fixed as
   */
  static readonly KEY_SDK_NAME = "sdk_name";
  /**
   * Log, main content
   */
  static readonly KEY_MESSAGE = "message";
  //     static readonly  KEY_BACKENDSAMPLE = "backend_sample";

  /**
   * Device UUID, used
   */
  static readonly KEY_DEVICE_UUID = "device_uuid";
  static readonly KEY_DEVICE_OS = "os";
  /**
   * OS version
   */
  static readonly KEY_DEVICE_OS_VERSION = "os_version";
  /**
   * OS major version
   */
  static readonly KEY_DEVICE_OS_VERSION_MAJOR = "os_version_major";
  /**
   * Device band
   */
  static readonly KEY_DEVICE_DEVICE_BAND = "device";
  /**
   * Device model
   */
  static readonly KEY_DEVICE_DEVICE_MODEL = "model";
  /**
   * OS architecture
   */
  static readonly KEY_DEVICE_DEVICE_ARCH = "arch";
  /**
   * Screen size
   */
  static readonly KEY_DEVICE_DISPLAY = "screen_size";
  /**
   * Mobile carrier， //TODO
   */
  static readonly KEY_DEVICE_CARRIER = "carrier";
  /**
   * Device locale ，//TODO
   */
  static readonly KEY_DEVICE_LOCALE = "locale";
  /**
   * Click event
   */
  static readonly EVENT_NAME_CLICK = "click";
  /**
   * Whether logged in status
   */
  static readonly KEY_RUM_IS_SIGN_IN = "is_signin";
  /**
   * User ID, generally the unique ID of the account
   */
  static readonly KEY_RUM_USER_ID = "userid";
  /**
   * User name
   */
  static readonly KEY_RUM_USER_NAME = "user_name";
  /**
   * User email
   */
  static readonly KEY_RUM_USER_EMAIL = "user_email";
  /**
   * RUM app_id, used by user access monitoring to distinguish
   */
  static readonly KEY_RUM_APP_ID = "app_id";
  /**
   * RUM custom key values
   */
  static readonly KEY_RUM_CUSTOM_KEYS = "custom_keys";

  /**
   * SDK package info (JSON string containing agent, track, native, web versions)
   */
  static readonly KEY_SDK_PACKAGE_INFO = "sdk_pkg_info";
  /**
   * ft-sdk module release version
   */
  static readonly KEY_SDK_PACKAGE_AGENT = "agent";
  /**
   * Guance Hvigor compiler-plugin release version.
   */
  static readonly KEY_RUM_SDK_PACKAGE_TRACK = "track";
  /**
   * ft-native module release version
   */
  static readonly KEY_RUM_SDK_PACKAGE_NATIVE = "native";
  /**
   * Web view uses web sdk release version
   */
  static readonly KEY_RUM_SDK_PACKAGE_WEB = "web";
  /**
   * SDK data flag [packageId].[instance].[packageDataCount].[nonce].[uuid].
   * The package-prefixed value selected for the first upload must remain
   * unchanged for every retry.
   */
  static readonly KEY_SDK_DATA_FLAG = "sdk_data_id";
  /**
   * SDK View update time
   */
  static readonly KEY_SDK_VIEW_UPDATE_TIME = "view_update_time";
  /**
   * SDK version number, here is the agent version
   */
  static readonly KEY_SDK_VERSION = "sdk_version";

  /**
   * Resource URL path grouping, automatically group similar URLs /?/path/query?params=x1
   */
  static readonly KEY_RUM_RESOURCE_URL_PATH_GROUP = "resource_url_path_group";
  /**
   * Host IP address
   */
  static readonly KEY_RUM_RESOURCE_HOST_IP = "resource_host_ip";

  /**
   * Long task duration, nanoseconds
   */
  static readonly KEY_RUM_LONG_TASK_DURATION = "duration";
  /**
   * Long task stack
   */
  static readonly KEY_RUM_LONG_TASK_STACK = "long_task_stack";
  /**
   * Network type, WIFI, 3G, 4G, etc.
   */
  static readonly KEY_RUM_NETWORK_TYPE = "network_type";

  /**
   * Line protocol data, additional properties
   */
  static readonly KEY_RUM_PROPERTY = "property";
  /**
   * Line protocol data tags, temporary storage for dynamic tags
   */
  static readonly KEY_RUM_TAGS = "tags";
  /** Internal Action/View persistence metadata; never included in RUM attributes. */
  static readonly KEY_RUM_COLLECT_TYPE = "collect_type";
  static readonly KEY_RUM_VIEW_MONOTONIC_START = "_sdk_view_monotonic_start_ns";
  static readonly KEY_RUM_VIEW_LONG_TASK_DURATION = "_sdk_view_long_task_duration_ns";
  /**
   * Cold start, action_type
   */
  static readonly ACTION_TYPE_LAUNCH_COLD = "launch_cold";
  /**
   * Hot start, action_type
   */
  static readonly ACTION_TYPE_LAUNCH_HOT = "launch_hot";
  /**
   * Cold start, action_name
   */
  static readonly ACTION_NAME_LAUNCH_COLD = "app cold start";
  /**
   * Hot start, action_name
   */
  static readonly ACTION_NAME_LAUNCH_HOT = "app hot start";

  /**
   * RUM view dwell time
   */
  static readonly KEY_RUM_VIEW_TIME_SPENT = "time_spent";

  /**
   * Whether RUM view is active
   */
  static readonly KEY_RUM_VIEW_IS_ACTIVE = "is_active";
  /**
   * Whether it is uploaded data from webview
   */
  static readonly KEY_RUM_VIEW_IS_WEB_VIEW = "is_web_view";
  /**
   * Session error time
   */
  static readonly KEY_SESSION_ERROR_TIMESTAMP = "session_error_timestamp";
  /**
   * Resource download time (aligned with Android: KEY_RUM_DOWNLOAD_TIME)
   */
  static readonly KEY_RUM_DOWNLOAD_TIME = "resource_download_time";
  /**
   * Session rum sampling rate (aligned with Android: KEY_SESSION_SAMPLE_RATE)
   */
  static readonly KEY_SESSION_SAMPLE_RATE = "session_sample_rate";
  /**
   * Session error sampling rate (aligned with Android: KEY_SESSION_ON_ERROR_SAMPLE_RATE)
   */
  static readonly KEY_SESSION_ON_ERROR_SAMPLE_RATE = "session_on_error_sample_rate";

  /**
   * Crash error context keys (for native crash reporting)
   */
  static readonly KEY_CRASH_TYPE = "crash_type";
  static readonly KEY_NATIVE_CRASH = "native_crash";
  static readonly KEY_BUNDLE_NAME = "bundle_name";
  static readonly KEY_BUNDLE_VERSION = "bundle_version";
  static readonly KEY_PID = "pid";
  static readonly KEY_UID = "uid";
  static readonly KEY_UUID = "uuid";
  static readonly KEY_FOREGROUND = "foreground";
  static readonly KEY_TIMESTAMP = "timestamp";
  static readonly KEY_HILOG_SIZE = "hilog_size";
  static readonly KEY_LOG_OVER_LIMIT = "log_over_limit";
  static readonly KEY_EXTERNAL_LOG = "external_log";
}

export type CommonSingleType = Object | String | Number | Boolean | null | undefined; // Common single union type

export type CommonAllType = CommonSingleType | Array<CommonSingleType> | ArrayList<CommonSingleType>
  | HashMap<CommonSingleType, CommonSingleType>;
