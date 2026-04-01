/**
 * Utility module index file
 * Exports all utility classes related to system information
 */


// Monitoring type enums
export { 
  ErrorMonitorType,
  DeviceMetricsMonitorType,
  PerformanceMonitorType,
  NetworkMonitorType,
  StorageMonitorType,
  SecurityMonitorType,
  BusinessMonitorType,
  MonitorLevel,
  MonitorStatus,
  type MonitorConfig,
  type MonitorResult,
  type IMonitorManager
} from './MonitorTypes';

// General utilities
export { Utils } from './Utils';

// Device information utilities
export { DeviceUtils } from './DeviceUtils';

// Battery information utilities
export { BatteryUtils, type BatteryBean } from './BatteryUtils';

// CPU information utilities
export { CpuUtils, type CpuBean } from './CpuUtils';

// Network utilities (existing)
export { NetworkUtils } from './NetworkUtils';

// FTInnerLogger is internal only, not exported (aligned with Android design)
// External users should use FTLogger instead

// String wrapper utility
export { StringWrapper } from './StringWrapper';
