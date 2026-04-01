/**
 * Log status enumeration
 */
export class Status {
  public readonly name: string;
  public readonly level: number;
  
  private constructor(name: string, level: number) {
    this.name = name;
    this.level = level;
  }
  
  // Predefined status constants
  public static readonly TRACE = new Status("trace", 0);
  public static readonly DEBUG = new Status("debug", 1);
  public static readonly INFO = new Status("info", 2);
  public static readonly WARN = new Status("warn", 3);
  public static readonly ERROR = new Status("error", 4);
  public static readonly FATAL = new Status("fatal", 5);
  
  /**
   * Get all statuses
   */
  public static getAllStatuses(): Status[] {
    return [
      Status.TRACE,
      Status.DEBUG,
      Status.INFO,
      Status.WARN,
      Status.ERROR,
      Status.FATAL
    ];
  }
  
  /**
   * Get status by name
   */
  public static fromName(name: string): Status | null {
    const normalizedName = name?.toLowerCase();
    switch (normalizedName) {
      case "trace":
        return Status.TRACE;
      case "debug":
        return Status.DEBUG;
      case "info":
        return Status.INFO;
      case "warn":
      case "warning":
        return Status.WARN;
      case "error":
        return Status.ERROR;
      case "fatal":
      case "critical":
        return Status.FATAL;
      default:
        return null;
    }
  }
  
  /**
   * Check if current status equals specified status
   */
  public equals(other: Status): boolean {
    return this.level === other.level && this.name === other.name;
  }
  
  /**
   * Convert to string
   */
  public toString(): string {
    return this.name;
  }
}
