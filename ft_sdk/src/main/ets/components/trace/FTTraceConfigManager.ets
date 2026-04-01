/**
 * HarmonyOS SDK Trace Configuration Manager
 * Reference HarmonyOS SDK: FTTraceConfigManager
 */
import { FTTraceConfig } from '../Configs';
import { TraceType } from './TraceType';
import { FTInnerLogger } from '../log/FTLogger';
import { HeaderHandler } from './FTTraceInterceptor';

const TAG = "FTTraceConfigManager";

/**
 * Trace configuration manager
 * Manages trace configuration and provides trace-related functionality
 */
export class FTTraceConfigManager {
  private static instance: FTTraceConfigManager | null = null;
  private config: FTTraceConfig | null = null;

  private constructor() {
    // Private constructor for singleton pattern
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): FTTraceConfigManager {
    if (!FTTraceConfigManager.instance) {
      FTTraceConfigManager.instance = new FTTraceConfigManager();
    }
    return FTTraceConfigManager.instance;
  }

  /**
   * Initialize with trace configuration
   * @param config Trace configuration
   */
  public initWithConfig(config: FTTraceConfig): void {
    try {

      this.config = config;
      FTInnerLogger.d(TAG, `Trace config initialized: samplingRate=${config.getSamplingRate()}, traceType=${config.getTraceType()}, enableAutoTrace=${config.isEnableAutoTrace()}`);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize trace config: ${error}`);
      throw new Error(`Failed to initialize trace config: ${error}`);
    }
  }

  /**
   * Get current trace configuration
   */
  public getConfig(): FTTraceConfig | null {
    return this.config;
  }

  /**
   * Get override header handler for custom trace interceptor
   */
  public getOverrideHeaderHandler(): HeaderHandler | null {
    if (!this.config) return null;
    const headerHandler: HeaderHandler | null = this.config.getOkHttpTraceHeaderHandler();
    if (!headerHandler) return null;
    return headerHandler;
  }

  /**
   * Check if auto trace is enabled
   */
  public isAutoTraceEnabled(): boolean {
    return this.config ? this.config.isEnableAutoTrace() : false;
  }

  /**
   * Check if RUM data linking is enabled
   */
  public isRUMDataLinkingEnabled(): boolean {
    return this.config ? this.config.isEnableLinkRUMData() : false;
  }

  /**
   * Get sampling rate
   */
  public getSamplingRate(): number {
    return this.config ? this.config.getSamplingRate() : 1.0;
  }

  /**
   * Get trace type as string (for backward compatibility)
   */
  public getTraceType(): string {
    return this.config ? this.config.getTraceType().toString() : TraceType.DDTRACE.toString();
  }

  /**
   * Get trace type as enum (for accurate type checking)
   */
  public getTraceTypeEnum(): TraceType {
    return this.config ? this.config.getTraceType() : TraceType.DDTRACE;
  }

  /**
   * Get service name
   */
  public getServiceName(): string {
    return this.config ? this.config.getServiceName() : 'harmonyos-app';
  }

  /**
   * Get global context
   */
  public getGlobalContext(): Map<string, object> {
    if (!this.config) return new Map<string, object>();
    const context: Map<string, object> = this.config.getGlobalContext();
    return context;
  }

  /**
   * Get supported trace content types
   */
  public getTraceContentTypes(): string[] {
    return this.config ? this.config.getTraceContentType() : [];
  }

  /**
   * Check if web trace is enabled
   */
  public isWebTraceEnabled(): boolean {
    return this.config ? this.config.isEnableWebTrace() : false;
  }

  /**
   * Reset configuration
   */
  public reset(): void {
    this.config = null;
    FTInnerLogger.d(TAG, "Trace config reset");
  }
}
