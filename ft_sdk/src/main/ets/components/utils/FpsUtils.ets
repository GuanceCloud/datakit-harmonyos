import { hidebug } from '@kit.PerformanceAnalysisKit';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';

const TAG = Constants.LOG_TAG_PREFIX + "FpsUtils";

/**
 * FPS statistics interface
 */
interface FpsStats {
  current: number;
  average: number;
  min: number;
  max: number;
  frameCount: number;
}

/**
 * FPS monitoring utility for HarmonyOS
 * Based on @ohos.hidebug API for performance analysis
 */
export class FpsUtils {
  private static instance: FpsUtils | null = null;
  private isInitialized: boolean = false;
  private frameCount: number = 0;
  private lastFrameTime: number = 0;
  private fpsHistory: number[] = [];
  private maxHistorySize: number = 60; // Keep 60 frames of history

  private constructor() {
    // Private constructor for singleton
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): FpsUtils {
    if (!FpsUtils.instance) {
      FpsUtils.instance = new FpsUtils();
    }
    return FpsUtils.instance;
  }

  /**
   * Initialize FPS monitoring
   */
  public async init(): Promise<void> {
    try {
      // Initialize FPS monitoring (simulated for now)
      this.isInitialized = true;
      this.frameCount = 0;
      this.lastFrameTime = 0;
      this.fpsHistory = [];
      FTInnerLogger.d(TAG, "FPS monitoring initialized successfully");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize FPS monitoring: ${error}`);
      this.isInitialized = false;
    }
  }

  /**
   * Start FPS monitoring
   */
  public start(): void {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "FPS monitoring not initialized");
      return;
    }

    try {
      // Reset counters
      this.frameCount = 0;
      this.lastFrameTime = Date.now();
      this.fpsHistory = [];
      FTInnerLogger.d(TAG, "FPS monitoring started");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to start FPS monitoring: ${error}`);
    }
  }

  /**
   * Stop FPS monitoring
   */
  public stop(): void {
    try {
      this.frameCount = 0;
      this.lastFrameTime = 0;
      this.fpsHistory = [];
      FTInnerLogger.d(TAG, "FPS monitoring stopped");
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to stop FPS monitoring: ${error}`);
    }
  }

  /**
   * Record a frame for FPS calculation
   */
  public recordFrame(): void {
    if (!this.isInitialized) {
      return;
    }

    try {
      const currentTime = Date.now();
      this.frameCount++;

      if (this.lastFrameTime > 0) {
        const frameTime = currentTime - this.lastFrameTime;
        if (frameTime > 0) {
          const fps = 1000 / frameTime; // Convert ms to FPS
          this.fpsHistory.push(fps);

          // Keep only recent history
          if (this.fpsHistory.length > this.maxHistorySize) {
            this.fpsHistory.shift();
          }
        }
      }

      this.lastFrameTime = currentTime;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to record frame: ${error}`);
    }
  }

  /**
   * Get current FPS
   * @returns Current FPS value
   */
  public getFps(): number {
    if (!this.isInitialized || this.fpsHistory.length === 0) {
      return -1;
    }

    try {
      const currentFps = this.fpsHistory[this.fpsHistory.length - 1];
      FTInnerLogger.d(TAG, `Current FPS: ${currentFps}`);
      return currentFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get current FPS: ${error}`);
      return -1;
    }
  }

  /**
   * Get average FPS
   * @returns Average FPS value
   */
  public getAverageFps(): number {
    if (!this.isInitialized || this.fpsHistory.length === 0) {
      return -1;
    }

    try {
      const sum = this.fpsHistory.reduce((acc, fps) => acc + fps, 0);
      const averageFps = sum / this.fpsHistory.length;
      FTInnerLogger.d(TAG, `Average FPS: ${averageFps}`);
      return averageFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get average FPS: ${error}`);
      return -1;
    }
  }

  /**
   * Get minimum FPS
   * @returns Minimum FPS value
   */
  public getMinFps(): number {
    if (!this.isInitialized || this.fpsHistory.length === 0) {
      return -1;
    }

    try {
      const minFps = Math.min(...this.fpsHistory);
      FTInnerLogger.d(TAG, `Minimum FPS: ${minFps}`);
      return minFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get minimum FPS: ${error}`);
      return -1;
    }
  }

  /**
   * Get maximum FPS
   * @returns Maximum FPS value
   */
  public getMaxFps(): number {
    if (!this.isInitialized || this.fpsHistory.length === 0) {
      return -1;
    }

    try {
      const maxFps = Math.max(...this.fpsHistory);
      FTInnerLogger.d(TAG, `Maximum FPS: ${maxFps}`);
      return maxFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get maximum FPS: ${error}`);
      return -1;
    }
  }

  /**
   * Get FPS statistics
   * @returns FPS statistics object
   */
  public getFpsStats(): FpsStats {
    const result: FpsStats = {
      current: this.getFps(),
      average: this.getAverageFps(),
      min: this.getMinFps(),
      max: this.getMaxFps(),
      frameCount: this.frameCount
    };
    return result;
  }

  /**
   * Release resources
   */
  public async release(): Promise<void> {
    try {
      if (this.isInitialized) {
        this.isInitialized = false;
        this.frameCount = 0;
        this.lastFrameTime = 0;
        this.fpsHistory = [];
        FTInnerLogger.d(TAG, "FPS monitoring released");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to release FPS monitoring: ${error}`);
    }
  }

  /**
   * Check if FPS monitoring is available
   * @returns true if available, false otherwise
   */
  public isAvailable(): boolean {
    return this.isInitialized;
  }
}
