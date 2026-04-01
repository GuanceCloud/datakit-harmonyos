import { FTTraceHandler } from './FTTraceHandler';
import { FTTraceHeaderHandler } from './FTTraceConfig';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { HashMap } from '@kit.ArkTS';

const TAG = Constants.LOG_TAG_PREFIX + "FTTraceManager";

/**
 * Trace handler container
 */
class FTTraceManagerContainer {
  private handler: FTTraceHeaderHandler;
  private createTime: number;
  
  constructor(handler: FTTraceHeaderHandler) {
    this.handler = handler;
    this.createTime = Date.now();
  }
  
  public getHandler(): FTTraceHeaderHandler {
    return this.handler;
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
  public putTraceHandler(key: string, handler: FTTraceHeaderHandler): void {
    if (!key || !handler) {
      FTInnerLogger.w(TAG, "Invalid key or handler");
      return;
    }
    
    const container = new FTTraceManagerContainer(handler);
    this.handlerMap.put(key, container);
    FTInnerLogger.d(TAG, `Added trace handler for key: ${key}`);
  }
  
  /**
   * Get Trace HTTP request Header parameters
   * @param key Resource ID
   * @param urlString URL address
   * @returns Header key-value pairs
   */
  public getTraceHeader(key: string, urlString: string): Record<string, string> {
    try {
      const handler = new FTTraceHandler();
      const headers = handler.getTraceHeader(urlString);
      this.putTraceHandler(key, handler);
      return headers;
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
      const handler = new FTTraceHandler();
      return handler.getTraceHeader(urlString);
    } catch (error) {
      FTInnerLogger.e(TAG, `Error getting trace header: ${error}`);
      return {} as Record<string, string>;
    }
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
    // Clean up expired handlers every 5 minutes
    setInterval(() => {
      this.cleanupExpiredHandlers();
    }, 300000);
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
