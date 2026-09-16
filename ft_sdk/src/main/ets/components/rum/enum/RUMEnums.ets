/**
 * RUM-related enum definitions
 */

/**
 * Error type enum
 */
export enum ErrorType {
  JS = "js",
  NETWORK = "network",
  CONSOLE = "console",
  JS_CRASH = "js_crash",
  NATIVE_CRASH = "native_crash",
  ANR_CRASH = "anr_crash",
  ANR_ERROR = "anr_error",
  CUSTOM = "custom"
}

/**
 * Error source enum
 */
export enum ErrorSource {
  SOURCE = "source",
  NETWORK = "network",
  WEBVIEW = "webview",
  CONSOLE = "console",
  LOGGER = "logger",
  AGENT = "agent",
  CUSTOM = "custom"
}

/**
 * Application state enum
 */
export enum AppState {
  RUN = "run",
  BACKGROUND = "background",
  UNKNOWN = "unknown"
}

/**
 * Action type enum
 */
export enum ActionType {
  CLICK = "click",
  SCROLL = "scroll",
  SWIPE = "swipe",
  CUSTOM = "custom",
  LAUNCH = "launch",
  NAVIGATE = "navigate"
}

/**
 * Resource type enum
 */
export enum ResourceType {
  NETWORK = "network",
  IMAGE = "image",
  JS = "js",
  CSS = "css",
  FONT = "font",
  DOCUMENT = "document",
  OTHER = "other"
}

/**
 * Collection type enum
 */
export enum CollectType {
  ALL = "all",
  SAMPLING = "sampling", 
  DROP = "drop"
}

/**
 * Session state enum
 */
export enum SessionState {
  ACTIVE = "active",
  INACTIVE = "inactive",
  EXPIRED = "expired"
}

/**
 * RUM measurement type enum
 */
export enum RUMMeasurement {
  VIEW = "view",
  ACTION = "action", 
  RESOURCE = "resource",
  ERROR = "error",
  LONG_TASK = "long_task"
}

/**
 * Network method enum
 */
export enum NetworkMethod {
  GET = "GET",
  POST = "POST",
  PUT = "PUT",
  DELETE = "DELETE",
  HEAD = "HEAD",
  OPTIONS = "OPTIONS",
  PATCH = "PATCH"
}

/**
 * View loading type enum
 */
export enum ViewLoadType {
  INITIAL_LOAD = "initial_load",
  ROUTE_CHANGE = "route_change",
  ACTIVITY_DISPLAY = "activity_display",
  ACTIVITY_RESUME = "activity_resume"
}

/**
 * Performance metric type enum
 */
export enum PerformanceMetricType {
  DNS = "dns",
  TCP = "tcp",
  SSL = "ssl",
  TTFB = "ttfb",
  TRANS = "trans",
  FIRST_BYTE = "first_byte",
  DOWNLOAD = "download",
  TOTAL = "total"
}

/**
 * RUM event priority enum
 */
export enum RUMEventPriority {
  LOW = "low",
  NORMAL = "normal", 
  HIGH = "high",
  CRITICAL = "critical"
}

/**
 * Device type enum
 */
export enum DeviceType {
  MOBILE = "mobile",
  TABLET = "tablet",
  DESKTOP = "desktop",
  TV = "tv",
  WATCH = "watch",
  UNKNOWN = "unknown"
}

/**
 * Network type enum
 */
export enum NetworkType {
  WIFI = "wifi",
  CELLULAR = "cellular",
  ETHERNET = "ethernet", 
  BLUETOOTH = "bluetooth",
  VPN = "vpn",
  UNKNOWN = "unknown",
  NONE = "none"
}

/**
 * Network quality enum
 */
export enum NetworkQuality {
  EXCELLENT = "excellent",
  GOOD = "good",
  FAIR = "fair",
  POOR = "poor",
  UNKNOWN = "unknown"
}

/**
 * Battery status enum
 */
export enum BatteryStatus {
  CHARGING = "charging",
  DISCHARGING = "discharging",
  NOT_CHARGING = "not_charging",
  FULL = "full",
  UNKNOWN = "unknown"
}

/**
 * Memory warning level enum
 */
export enum MemoryWarningLevel {
  NORMAL = "normal",
  LOW = "low",
  CRITICAL = "critical"
}

/**
 * Enum utility class
 */
export class RUMEnumUtils {
  
  /**
   * Convert an error type string to an enum
   */
  static parseErrorType(type: string): ErrorType {
    const normalizedType = type?.toLowerCase();
    switch (normalizedType) {
      case "js":
      case "javascript":
        return ErrorType.JS;
      case "network":
        return ErrorType.NETWORK;
      case "console":
        return ErrorType.CONSOLE;
      case "js_crash":
        return ErrorType.JS_CRASH;
      case "native_crash":
        return ErrorType.NATIVE_CRASH;
      case "anr_crash":
        return ErrorType.ANR_CRASH;
      case "anr_error":
        return ErrorType.ANR_ERROR;
      default:
        return ErrorType.CUSTOM;
    }
  }
  
  /**
   * Convert an action type string to an enum
   */
  static parseActionType(type: string): ActionType {
    const normalizedType = type?.toLowerCase();
    switch (normalizedType) {
      case "click":
      case "tap":
        return ActionType.CLICK;
      case "scroll":
        return ActionType.SCROLL;
      case "swipe":
        return ActionType.SWIPE;
      case "launch":
        return ActionType.LAUNCH;
      case "navigate":
        return ActionType.NAVIGATE;
      default:
        return ActionType.CUSTOM;
    }
  }
  
  /**
   * Convert a network method string to an enum
   */
  static parseNetworkMethod(method: string): NetworkMethod {
    const normalizedMethod = method?.toUpperCase();
    switch (normalizedMethod) {
      case "GET":
        return NetworkMethod.GET;
      case "POST":
        return NetworkMethod.POST;
      case "PUT":
        return NetworkMethod.PUT;
      case "DELETE":
        return NetworkMethod.DELETE;
      case "HEAD":
        return NetworkMethod.HEAD;
      case "OPTIONS":
        return NetworkMethod.OPTIONS;
      case "PATCH":
        return NetworkMethod.PATCH;
      default:
        return NetworkMethod.GET;
    }
  }
  
  /**
   * Determine whether an HTTP status code indicates an error
   */
  static isHttpError(statusCode: number): boolean {
    return statusCode >= 400;
  }
  
  /**
   * Get the status group based on the HTTP status code
   */
  static getHttpStatusGroup(statusCode: number): string {
    if (statusCode <= 0) return "unknown";
    const group = Math.floor(statusCode / 100);
    return `${group}xx`;
  }
  
  /**
   * Determine whether it is a successful status code
   */
  static isHttpSuccess(statusCode: number): boolean {
    return statusCode >= 200 && statusCode < 300;
  }
  
  /**
   * Determine whether it is a client error
   */
  static isClientError(statusCode: number): boolean {
    return statusCode >= 400 && statusCode < 500;
  }
  
  /**
   * Determine whether it is a server error
   */
  static isServerError(statusCode: number): boolean {
    return statusCode >= 500 && statusCode < 600;
  }
  
  /**
   * Get all error types
   */
  static getAllErrorTypes(): ErrorType[] {
    return [
      ErrorType.JS,
      ErrorType.NETWORK,
      ErrorType.CONSOLE,
      ErrorType.JS_CRASH,
      ErrorType.NATIVE_CRASH,
      ErrorType.ANR_CRASH,
      ErrorType.ANR_ERROR,
      ErrorType.CUSTOM
    ];
  }

  /**
   * Crash-free duration belongs only to Error types representing a process
   * crash/freeze. Custom, network and ordinary ANR error reports are errors,
   * but must not reset the crash-free interval.
   */
  static isCrashErrorType(type: string | ErrorType): boolean {
    const value = String(type).toLowerCase();
    return value === ErrorType.JS_CRASH ||
      value === ErrorType.NATIVE_CRASH ||
      value === ErrorType.ANR_CRASH;
  }
  
  /**
   * Get all action types
   */
  static getAllActionTypes(): ActionType[] {
    return [
      ActionType.CLICK,
      ActionType.SCROLL,
      ActionType.SWIPE,
      ActionType.CUSTOM,
      ActionType.LAUNCH,
      ActionType.NAVIGATE
    ];
  }
  
  /**
   * Validate an enum value
   */
  static isValidErrorType(type: string): boolean {
    return Object.values(ErrorType).includes(type as ErrorType);
  }
  
  static isValidActionType(type: string): boolean {
    return Object.values(ActionType).includes(type as ActionType);
  }
  
  static isValidResourceType(type: string): boolean {
    return Object.values(ResourceType).includes(type as ResourceType);
  }
}
