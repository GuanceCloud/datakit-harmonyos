import { FTTraceHandler } from './FTTraceHandler';
import { FTTraceContext, FTTraceHeaderHandler, FTTraceRequestContext } from './FTTraceHeaderHandler';
import { FTTraceConfigManager } from './FTTraceConfigManager';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { SDKTaskPriority, SDKTaskRunner, SDKTaskScheduler, SDKTaskType } from '../thread/SDKTaskScheduler';
import {
  createSDKWorkerTaskBridgeHandler,
  createSDKWorkerTaskFallbackRunner,
  createSDKWorkerTaskRequest
} from '../thread/SDKWorkerTaskBridge';
import {
  SDKDedicatedPoolType,
  SDKWorkerCommand
} from '../thread/SDKWorkerProtocol';

const TAG = Constants.LOG_TAG_PREFIX + "FTTraceManager";
const CUSTOM_LANE_TRACE_PREFIX = "<FT-CUSTOM-LANE>";
const TRACE_CLEANUP_SERIAL_KEY = "trace-handler-cleanup";
const TRACE_CLEANUP_SINGLE_FLIGHT_KEY = "trace-handler-cleanup";
const TRACE_CLEANUP_INTERVAL_MS = 300000;

interface TraceContextGenerationResult {
  handler: FTTraceHeaderHandler;
  traceContext: FTTraceContext;
}

/**
 * Trace handler container
 */
class FTTraceManagerContainer {
  private handler: FTTraceHeaderHandler;
  private traceContext: FTTraceContext | null;
  private createTime: number;
  
  constructor(handler: FTTraceHeaderHandler, traceContext: FTTraceContext | null = null) {
    this.handler = handler;
    this.traceContext = traceContext;
    this.createTime = Date.now();
  }
  
  public getHandler(): FTTraceHeaderHandler {
    return this.handler;
  }

  public getTraceContext(): FTTraceContext | null {
    return this.traceContext;
  }
  
  public getCreateTime(): number {
    return this.createTime;
  }
  
  public isExpired(maxAge: number = 300000): boolean { // 5 minutes expired
    return Date.now() - this.createTime > maxAge;
  }
}

/**
 * Size-limited concurrent Map
 */
class SizeLimitedConcurrentMap<K, V> {
  private map: Map<K, V> = new Map();
  private maxSize: number;
  
  constructor(maxSize: number) {
    this.maxSize = maxSize;
  }
  
  public   put(key: K, value: V): void {
    if (this.map.size >= this.maxSize) {
      // Remove oldest entries
      const keys = Array.from(this.map.keys());
      if (keys.length > 0) {
        this.map.delete(keys[0]);
      }
    }
    this.map.set(key, value);
  }
  
  public get(key: K): V | undefined {
    return this.map.get(key);
  }
  
  public has(key: K): boolean {
    return this.map.has(key);
  }
  
  public delete(key: K): boolean {
    return this.map.delete(key);
  }
  
  public clear(): void {
    this.map.clear();
  }
  
  public size(): number {
    return this.map.size;
  }
  
  public keys(): IterableIterator<K> {
    return this.map.keys();
  }
  
  public values(): IterableIterator<V> {
    return this.map.values();
  }
  
  public entries(): IterableIterator<[K, V]> {
    return this.map.entries();
  }
}

/**
 * Trace Manager
 * Responsible for managing Trace handlers and Header generation
 */
export class FTTraceManager {
  private static instance: FTTraceManager | null = null;
  private static customTaskSequence: number = 0;
  private cleanupTimer: number | null = null;
  
  /**
   * Trace handler mapping table, limited to 1000 entries
   */
  private handlerMap: SizeLimitedConcurrentMap<string, FTTraceManagerContainer> = 
    new SizeLimitedConcurrentMap(1000);
  
  private constructor() {
    // Periodically clean up expired handlers
    this.startCleanupTimer();
  }
  
  /**
   * Get singleton instance
   */
  public static getInstance(): FTTraceManager {
    if (FTTraceManager.instance === null) {
      FTTraceManager.instance = new FTTraceManager();
    }
    return FTTraceManager.instance;
  }
  
  /**
   * Add Trace handler
   * @param key Resource ID
   * @param handler Trace handler
   */
  public putTraceHandler(key: string, handler: FTTraceHeaderHandler, traceContext: FTTraceContext | null = null): void {
    if (!key || !handler) {
      FTInnerLogger.w(TAG, "Invalid key or handler");
      return;
    }
    
    const container = new FTTraceManagerContainer(handler, traceContext);
    this.handlerMap.put(key, container);
    FTInnerLogger.d(TAG, `Added trace handler for key: ${key}`);
  }

  public putTraceContext(key: string, traceContext: FTTraceContext): void {
    if (!key || !traceContext) {
      FTInnerLogger.w(TAG, "Invalid key or trace context");
      return;
    }

    this.putTraceHandler(key, new FTTraceHandler(), traceContext);
  }

  private createTraceContext(
    urlString: string,
    requestContext?: FTTraceRequestContext
  ): TraceContextGenerationResult {
    const handler = new FTTraceHandler();
    const resolvedRequestContext: FTTraceRequestContext = requestContext || {
      url: urlString,
      method: "GET",
      headers: {}
    };
    const traceContext = this.applyTraceHeaderHandler(handler, resolvedRequestContext);
    return {
      handler: handler,
      traceContext: traceContext
    };
  }

  private applyTraceHeaderHandler(
    defaultHandler: FTTraceHandler,
    requestContext: FTTraceRequestContext
  ): FTTraceContext {
    const traceHeaderHandler: FTTraceHeaderHandler | null = FTTraceConfigManager.getInstance().getTraceHeaderHandler();
    if (!traceHeaderHandler) {
      return defaultHandler.getTraceContext(requestContext.url);
    }

    try {
      const processedContext = traceHeaderHandler.getTraceContext(requestContext);
      return FTTraceHandler.createTraceContextFromHeaders(
        processedContext.headers,
        processedContext.traceId,
        processedContext.spanId
      );
    } catch (error) {
      FTInnerLogger.e(TAG, `Error processing trace header: ${error}`);
      return defaultHandler.getTraceContext(requestContext.url);
    }
  }

  /**
   * Get Trace HTTP request Header parameters
   * @param key Resource ID
   * @param urlString URL address
   * @returns Header key-value pairs
   */
  public getTraceHeader(
    key: string,
    urlString: string,
    method: string = "GET",
    requestContext?: FTTraceRequestContext
  ): Record<string, string> {
    try {
      const resolvedRequestContext: FTTraceRequestContext = requestContext || {
        url: urlString,
        method: method,
        headers: {}
      };
      const generatedContext = this.createTraceContext(urlString, resolvedRequestContext);
      this.putTraceHandler(key, generatedContext.handler, generatedContext.traceContext);
      return generatedContext.traceContext.headers;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error getting trace header for key ${key}: ${error}`);
      return {} as Record<string, string>;
    }
  }
  
  /**
   * Get Trace HTTP request Header parameters (without storing handler)
   * @param urlString URL address
   * @returns Header key-value pairs
   */
  public getTraceHeaderDirect(urlString: string): Record<string, string> {
    try {
      return this.getTraceContextDirect(urlString).headers;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error getting trace header: ${error}`);
      return {} as Record<string, string>;
    }
  }

  /**
   * Generate default Trace context without invoking the configured Trace Header handler.
   * This is safe to call inside FTTraceHeaderHandler.getTraceContext(request).
   */
  public getTraceContextDirect(urlString: string): FTTraceContext {
    const handler = new FTTraceHandler();
    return handler.getTraceContext(urlString);
  }
  
  /**
   * Get handler
   * @param key Resource ID
   * @returns Trace handler
   */
  public getHandler(key: string): FTTraceHeaderHandler | null {
    const container = this.handlerMap.get(key);
    if (container) {
      if (container.isExpired()) {
        this.handlerMap.delete(key);
        FTInnerLogger.d(TAG, `Handler for key ${key} expired and removed`);
        return null;
      }
      return container.getHandler();
    }
    return null;
  }

  /**
   * Get generated Trace context
   * @param key Resource ID
   * @returns Trace context
   */
  public getTraceContext(key: string): FTTraceContext | null {
    const container = this.handlerMap.get(key);
    if (container) {
      if (container.isExpired()) {
        this.handlerMap.delete(key);
        FTInnerLogger.d(TAG, `Trace context for key ${key} expired and removed`);
        return null;
      }
      return container.getTraceContext();
    }
    return null;
  }
  
  /**
   * Remove handler
   * @param key Resource ID
   * @returns Whether successfully removed
   */
  public removeHandler(key: string): boolean {
    const result = this.handlerMap.delete(key);
    if (result) {
      FTInnerLogger.d(TAG, `Removed trace handler for key: ${key}`);
    }
    return result;
  }
  
  /**
   * Check if handler exists
   * @param key Resource ID
   * @returns Whether handler exists
   */
  public hasHandler(key: string): boolean {
    const container = this.handlerMap.get(key);
    if (container && container.isExpired()) {
      this.handlerMap.delete(key);
      return false;
    }
    return container !== undefined;
  }
  
  /**
   * Get all handler keys
   * @returns Handler key list
   */
  public getAllHandlerKeys(): string[] {
    const keys: string[] = [];
    for (const key of this.handlerMap.keys()) {
      keys.push(key);
    }
    return keys;
  }
  
  /**
   * Get handler count
   * @returns Handler count
   */
  public getHandlerCount(): number {
    return this.handlerMap.size();
  }
  
  /**
   * Clear all handlers
   */
  public clearAllHandlers(): void {
    this.handlerMap.clear();
    FTInnerLogger.d(TAG, "Cleared all trace handlers");
  }
  
  /**
   * Clear expired handlers
   */
  public cleanupExpiredHandlers(): void {
    const keysToRemove: string[] = [];
    
    const entries = Array.from(this.handlerMap.entries());
    for (let i = 0; i < entries.length; i++) {
      const key = entries[i][0];
      const container = entries[i][1];
      if (container.isExpired()) {
        keysToRemove.push(key);
      }
    }
    
    for (const key of keysToRemove) {
      this.handlerMap.delete(key);
    }
    
    if (keysToRemove.length > 0) {
      FTInnerLogger.d(TAG, `Cleaned up ${keysToRemove.length} expired handlers`);
    }
  }
  
  /**
   * Start cleanup timer
   */
  private startCleanupTimer(): void {
    if (this.cleanupTimer !== null) {
      clearInterval(this.cleanupTimer);
    }

    this.cleanupTimer = setInterval(() => {
      this.submitCustomTask('trace.cleanupExpiredHandlers', () => {
        this.cleanupExpiredHandlers();
      });
    }, TRACE_CLEANUP_INTERVAL_MS);
  }

  private submitCustomTask(name: string, task: SDKTaskRunner): void {
    const traceName = this.nextCustomTaskName(name);
    const command = SDKWorkerCommand.CUSTOM_RUN;
    const runTask = async () => {
      const startTime = Date.now();
      let result = 'success';
      let errorMessage = '';
      try {
        await Promise.resolve(task());
      } catch (error) {
        result = 'failed';
        errorMessage = String(error);
        throw new Error(errorMessage);
      } finally {
        const costTime = Math.max(0, Date.now() - startTime);
        const errorPart = errorMessage.length > 0 ? ` error=${errorMessage}` : '';
        this.traceCustomLane(
          `[CONSUMED] name=${traceName} result=${result}${errorPart} cost=${costTime}ms handlers=${this.getHandlerCount()}`
        );
      }
    };
    const pendingBefore = this.getHandlerCount();
    this.traceCustomLane(`[ENQUEUE] name=${traceName} handlers=${pendingBefore}`);
    SDKTaskScheduler.getInstance().submitTask({
      type: SDKTaskType.CUSTOM,
      name: traceName,
      priority: SDKTaskPriority.BACKGROUND,
      serialKey: TRACE_CLEANUP_SERIAL_KEY,
      singleFlightKey: TRACE_CLEANUP_SINGLE_FLIGHT_KEY,
      costHint: 'light',
      workerRequest: createSDKWorkerTaskRequest(
        SDKDedicatedPoolType.BACKGROUND,
        command,
        traceName,
        SDKTaskPriority.BACKGROUND
      ),
      workerFallbackRunner: createSDKWorkerTaskFallbackRunner(traceName, command, runTask),
      workerBridgeHandler: createSDKWorkerTaskBridgeHandler(traceName, command, runTask)
    });
  }

  private nextCustomTaskName(name: string): string {
    FTTraceManager.customTaskSequence++;
    return `${name}#${FTTraceManager.customTaskSequence}`;
  }

  private traceCustomLane(message: string): void {
    FTInnerLogger.i(TAG, `${CUSTOM_LANE_TRACE_PREFIX} ${message}`);
  }
  
  /**
   * Get manager status
   * @returns Status information
   */
  public getStatus(): FTTraceManagerStatus {
    return {
      handlerCount: this.getHandlerCount(),
      maxSize: 1000,
      allKeys: this.getAllHandlerKeys()
    };
  }
  
  /**
   * Destroy manager
   */
  public destroy(): void {
    if (this.cleanupTimer !== null) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    this.clearAllHandlers();
    FTTraceManager.instance = null;
    FTInnerLogger.i(TAG, "FTTraceManager destroyed");
  }
}

/**
 * FTTraceManager status interface
 */
export interface FTTraceManagerStatus {
  handlerCount: number;
  maxSize: number;
  allKeys: string[];
}

/**
 * Convenience method to get FTTraceManager instance
 */
export function getFTTraceManager(): FTTraceManager {
  return FTTraceManager.getInstance();
}
