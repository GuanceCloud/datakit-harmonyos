/**
 * Monitor type enum definitions
 */

/**
 * Error monitor types
 */
export enum ErrorMonitorType {
  CRASH = "CRASH",                     // Crash monitoring
  EXCEPTION = "EXCEPTION",             // Exception monitoring
  ANR = "ANR",                         // ANR monitoring
  NATIVE_CRASH = "NATIVE_CRASH"        // Native crash monitoring
}

/**
 * Device metrics monitor types
 */
export enum DeviceMetricsMonitorType {
  CPU = "CPU",                         // CPU monitoring
  MEMORY = "MEMORY",                   // Memory monitoring
  BATTERY = "BATTERY",                 // Battery monitoring
  FPS = "FPS",                         // Frame rate monitoring
  NETWORK = "NETWORK",                 // Network monitoring
  STORAGE = "STORAGE"                  // Storage monitoring
}

/**
 * Performance monitor types
 */
export enum PerformanceMonitorType {
  PAGE_LOAD = "PAGE_LOAD",             // Page load monitoring
  API_CALL = "API_CALL",               // API call monitoring
  RESOURCE_LOAD = "RESOURCE_LOAD",     // Resource load monitoring
  USER_INTERACTION = "USER_INTERACTION", // User interaction monitoring
  BACKGROUND_TASK = "BACKGROUND_TASK"  // Background task monitoring
}

/**
 * Network monitor types
 */
export enum NetworkMonitorType {
  HTTP_REQUEST = "HTTP_REQUEST",        // HTTP request monitoring
  WEBSOCKET = "WEBSOCKET",             // WebSocket monitoring
  DNS_LOOKUP = "DNS_LOOKUP",           // DNS lookup monitoring
  CONNECTION_POOL = "CONNECTION_POOL", // Connection pool monitoring
  BANDWIDTH = "BANDWIDTH"              // Bandwidth monitoring
}

/**
 * Storage monitor types
 */
export enum StorageMonitorType {
  DATABASE = "DATABASE",               // Database monitoring
  FILE_SYSTEM = "FILE_SYSTEM",         // File system monitoring
  CACHE = "CACHE",                     // Cache monitoring
  SHARED_PREFERENCES = "SHARED_PREFERENCES" // Shared preferences monitoring
}

/**
 * Security monitor types
 */
export enum SecurityMonitorType {
  PERMISSION = "PERMISSION",           // Permission monitoring
  ENCRYPTION = "ENCRYPTION",           // Encryption monitoring
  CERTIFICATE = "CERTIFICATE",         // Certificate monitoring
  NETWORK_SECURITY = "NETWORK_SECURITY" // Network security monitoring
}

/**
 * Business monitor types
 */
export enum BusinessMonitorType {
  USER_BEHAVIOR = "USER_BEHAVIOR",     // User behavior monitoring
  BUSINESS_METRICS = "BUSINESS_METRICS", // Business metrics monitoring
  FEATURE_USAGE = "FEATURE_USAGE",     // Feature usage monitoring
  CONVERSION = "CONVERSION"            // Conversion rate monitoring
}

/**
 * Monitor levels
 */
export enum MonitorLevel {
  LOW = "LOW",                         // Low level monitoring
  NORMAL = "NORMAL",                   // Normal level monitoring
  HIGH = "HIGH",                       // High level monitoring
  CRITICAL = "CRITICAL"                // Critical level monitoring
}

/**
 * Monitor status
 */
export enum MonitorStatus {
  DISABLED = "DISABLED",               // Monitoring disabled
  ENABLED = "ENABLED",                 // Monitoring enabled
  PAUSED = "PAUSED",                   // Monitoring paused
  ERROR = "ERROR"                      // Monitoring error
}

/**
 * Monitor configuration interface
 */
export interface MonitorConfig {
  type: string;                        // Monitor type
  level: MonitorLevel;                 // Monitor level
  enabled: boolean;                    // Whether enabled
  frequency: number;                   // Detection frequency (milliseconds)
  threshold: number;                   // Threshold
  alert: boolean;                      // Whether to alert
  log: boolean;                        // Whether to log
  upload: boolean;                     // Whether to upload data
}

/**
 * Monitor result interface
 */
export interface MonitorResult {
  type: string;                        // Monitor type
  timestamp: number;                   // Timestamp
  value: number;                       // Monitor value
  unit: string;                        // Unit
  status: MonitorStatus;               // Monitor status
  message: string;                     // Monitor message
  threshold: number;                   // Threshold
  alert: boolean;                      // Whether to alert
  metadata: Record<string, object>;       // Metadata
}

/**
 * Monitor manager interface
 */
export interface IMonitorManager {
  // Enable monitoring
  enableMonitor(type: string): void;
  
  // Disable monitoring
  disableMonitor(type: string): void;
  
  // Pause monitoring
  pauseMonitor(type: string): void;
  
  // Resume monitoring
  resumeMonitor(type: string): void;
  
  // Get monitor status
  getMonitorStatus(type: string): MonitorStatus;
  
  // Get monitor result
  getMonitorResult(type: string): MonitorResult | null;
  
  // Get all monitor results
  getAllMonitorResults(): Record<string, MonitorResult>;
  
  // Set monitor configuration
  setMonitorConfig(config: MonitorConfig): void;
  
  // Get monitor configuration
  getMonitorConfig(type: string): MonitorConfig | null;
  
  // Check if monitoring is enabled
  isMonitorEnabled(type: string): boolean;
  
  // Add monitor listener
  addMonitorListener(type: string, listener: (result: MonitorResult) => void): void;
  
  // Remove monitor listener
  removeMonitorListener(type: string, listener: (result: MonitorResult) => void): void;
  
  // Clear monitor data
  clearMonitorData(type?: string): void;
  
  // Get monitor statistics
  getMonitorStatistics(): Record<string, object>;
}
