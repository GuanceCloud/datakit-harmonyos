/**
 *  HarmonyOS SDK - Public API Exports
 * 
 * This file exports all public APIs that should be accessible to SDK users.
 * DO NOT export internal implementation classes or utilities.
 */

// ============================================================================
// Imports (must be at the top)
// ============================================================================

import BuildProfile from './BuildProfile';

// ============================================================================
// SDK Version Constant
// ============================================================================

const HAR_VERSION: string = BuildProfile.HAR_VERSION;

// ============================================================================
// Core SDK Classes
// ============================================================================

export { FTSDK } from './src/main/ets/components/FTSDK';

// ============================================================================
// Configuration Classes
// ============================================================================

export { 
  FTSDKConfig,
  FTRUMConfig,
  FTLoggerConfig,
  FTTraceConfig,
  FTProxyConfig,
  FTProxyAuthenticator,
  FTDnsConfig,
  FTInnerLogFileConfig,
  FTDataFilters,
  LogGlobalContextDictionary,
  LogGlobalContextValue
} from './src/main/ets/components/Configs';
export { RemoteConfigBean } from './src/main/ets/components/remote/RemoteConfigBean';
export { FTRemoteConfigFetchResult } from './src/main/ets/components/remote/RemoteConfigTypes';

// ============================================================================
// RUM Manager
// ============================================================================

export { FTRUMGlobalManager } from './src/main/ets/components/rum/FTRUMGlobalManager';
export { ActionEventWrapper } from './src/main/ets/components/rum/bean/ActionEventWrapper';
export { HandlerView } from './src/main/ets/components/rum/bean/HandlerView';
export { ActionSourceType } from './src/main/ets/components/rum/enum/ActionSourceType';
export { FTActionTrackingHandler } from './src/main/ets/components/rum/handler/FTActionTrackingHandler';
export { FTViewTrackingHandler } from './src/main/ets/components/rum/handler/FTViewTrackingHandler';
export { FTViewTrackingType } from './src/main/ets/components/rum/enum/FTViewTrackingType';

// ============================================================================
// Logger
// ============================================================================

export { FTLogger } from './src/main/ets/components/log/FTLogger';

// ============================================================================
// Trace Manager
// ============================================================================

export { FTTraceManager } from './src/main/ets/components/trace/FTTraceManager';
export { FTTraceConfigManager } from './src/main/ets/components/trace/FTTraceConfigManager';
export {
  FTTraceContext,
  FTTraceHeaderHandler,
  FTTraceRequestContext
} from './src/main/ets/components/trace/FTTraceHeaderHandler';
export { TraceType } from './src/main/ets/components/trace/TraceType';
export {
  FTTraceInterceptor,
  DefaultFTTraceInterceptor,
  HeaderHandler,
  HttpRequestData,
  HttpResponseData
} from './src/main/ets/components/trace/FTTraceInterceptor';

// ============================================================================
// Enums
// ============================================================================

export {
  EnvType,
  SyncPageSize,
  LogCacheDiscard,
  RUMCacheDiscard,
  DBCacheDiscard,
  DetectFrequency,
  SDKLogLevel
} from './src/main/ets/components/enum/Enums';

// RUM Enums
export {
  ErrorType,
  AppState,
  CollectType,
  ActionType
} from './src/main/ets/components/rum/enum/RUMEnums';

export {
  ErrorMonitorType
} from './src/main/ets/components/rum/enum/ErrorMonitorType';

export {
  DeviceMetricsMonitorType
} from './src/main/ets/components/rum/enum/DeviceMetricsMonitorType';

// ============================================================================
// Bean Classes (Data Models)
// ============================================================================

// Status class for log levels (used by FTLogger)
export { Status } from './src/main/ets/components/bean/Status';
export { UserData } from './src/main/ets/components/rum/bean/UserData';
export { ResourceParams } from './src/main/ets/components/rum/bean/ResourceParams';
export { NetStatusBean } from './src/main/ets/components/rum/bean/NetStatusBean';

// ============================================================================
// Data Modifiers (Optional)
// ============================================================================

export {
  DataModifier,
  DataModifierValue,
  LineDataModifier
} from './src/main/ets/components/DataModifier';

// ============================================================================
// WebView Interface
// ============================================================================

export { JsReceiver } from './src/main/ets/components/web/WebAppInterface';
export { FTWebViewHandler } from './src/main/ets/components/web/FTWebViewHandler';

// ============================================================================
// Network Auto Track Helpers
// ============================================================================

export {
  createFTRCPInterceptors,
  RCPTraceInterceptor,
  RCPResourceInterceptor,
  applyFTAxiosTrack,
  createFTRCPTrackConfig,
} from './src/main/ets/components/network/FTHttpAutoTrack';

// ============================================================================
// Extension Integration Contract
// ============================================================================
// Versioned integration contract consumed by @guancecloud/ft_sdk_ext.
// FTSDKExtensionBridge is the stable bridge surface; function facade exports
// are deprecated/internal compatibility exports and should not be used by new code.

export {
  FT_SDK_EXTENSION_CONTRACT_VERSION,
  FTSDKExtensionBridge,
  FTSDKExtensionAutoTrackOptions,
  FTSDKExtensionResolvedAutoTrackOptions,
  FTSDKExtensionRequestInput,
  FTSDKExtensionPreparedRequest,
  FTSDKExtensionResponseInput,
} from './src/main/ets/components/integration';

// ============================================================================
// SDK Version
// ============================================================================

export { HAR_VERSION };

// ============================================================================
// Internal Utilities (for advanced use cases)
// ============================================================================

// String wrapper for global context
export { StringWrapper } from './src/main/ets/components/utils/StringWrapper';

// ============================================================================
// NOTE: The following are internal classes and should NOT be used by SDK users
// ============================================================================
// - FTRUMInnerManager (use FTRUMGlobalManager instead)
// - FTTrackInner (internal tracking)
// - FTDBManager (internal database)
// - All thread pool classes (internal use only)
// - All utility classes (internal use only)
// - Test classes (internal use only)
// ============================================================================
