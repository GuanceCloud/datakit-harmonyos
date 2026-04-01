// RUM module exports
// FTRUMInnerManager is internal only, not exported (aligned with Android design)
// External users should use FTRUMGlobalManager instead
export { FTRUMGlobalManager } from './FTRUMGlobalManager';

// Bean exports
export { ActiveViewBean } from './bean/ActiveViewBean';
export { ActiveActionBean } from './bean/ActiveActionBean';
export { ResourceBean } from './bean/ResourceBean';

// Enum exports
export { 
  ErrorType,
  ErrorSource,
  AppState,
  ActionType,
  ResourceType,
  CollectType,
  SessionState,
  RUMMeasurement,
  NetworkMethod,
  ViewLoadType,
  PerformanceMetricType,
  RUMEventPriority,
  DeviceType,
  NetworkType,
  NetworkQuality,
  BatteryStatus,
  MemoryWarningLevel,
  RUMEnumUtils
} from './enum/RUMEnums';
