import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import displaySync from '@ohos.graphics.displaySync';

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
 * FPS monitoring utility for HarmonyOS.
 *
 * Android publishes one FPS value for each elapsed one-second frame window;
 * View monitors then aggregate those values. Keep the same calculation here
 * instead of treating each individual frame interval as a separate FPS value.
 */
export class FpsUtils {
  private static instance: FpsUtils | null = null;
  private isInitialized: boolean = false;
  private frameStartTime: number = 0;
  private framesRendered: number = 0;
  private currentFps: number = 0;
  private readonly fpsWindowMs: number = 1000;
  private displaySyncInstance: displaySync.DisplaySync | null = null;
  private readonly frameCallback: (info: displaySync.IntervalInfo) => void =
    (_info: displaySync.IntervalInfo): void => {
      this.recordFrame();
    };

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
      if (this.isInitialized) {
        return;
      }
      this.displaySyncInstance = displaySync.create();
      this.displaySyncInstance.on('frame', this.frameCallback);
      this.isInitialized = true;
      this.currentFps = 0;
      this.resetFrameWindow();
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize FPS monitoring: ${error}`);
      this.isInitialized = false;
    }
  }

  /**
   * Start FPS monitoring
   */
  public start(): boolean {
    if (!this.isInitialized) {
      FTInnerLogger.w(TAG, "FPS monitoring not initialized");
      return false;
    }

    try {
      this.resetFrameWindow();
      this.displaySyncInstance?.start();
      return true;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to start FPS monitoring: ${error}`);
      return false;
    }
  }

  /**
   * Stop FPS monitoring
   */
  public stop(): void {
    try {
      this.displaySyncInstance?.stop();
      this.resetFrameWindow();
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to stop FPS monitoring: ${error}`);
    }
  }

  /**
   * Records a frame and publishes an FPS sample when a one-second window has
   * elapsed, matching Android's Choreographer Metronome implementation.
   */
  public recordFrame(currentTime: number = Date.now()): void {
    if (!this.isInitialized) {
      return;
    }

    try {
      if (this.frameStartTime > 0) {
        const elapsedMs = currentTime - this.frameStartTime;
        this.framesRendered++;
        if (elapsedMs > this.fpsWindowMs) {
          this.currentFps = (this.framesRendered * 1000) / elapsedMs;
          this.frameStartTime = currentTime;
          this.framesRendered = 0;
        }
      } else {
        this.frameStartTime = currentTime;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to record frame: ${error}`);
    }
  }

  /**
   * Get current FPS
   * @returns Current FPS value
   */
  public getFps(): number {
    if (!this.isInitialized) {
      return 0;
    }

    try {
      return this.currentFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get current FPS: ${error}`);
      return 0;
    }
  }

  /**
   * Get average FPS
   * @returns Average FPS value
   */
  public getAverageFps(): number {
    if (!this.isInitialized || this.currentFps <= 0) {
      return 0;
    }

    try {
      return this.currentFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get average FPS: ${error}`);
      return 0;
    }
  }

  /**
   * Get minimum FPS
   * @returns Minimum FPS value
   */
  public getMinFps(): number {
    if (!this.isInitialized || this.currentFps <= 0) {
      return 0;
    }

    try {
      return this.currentFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get minimum FPS: ${error}`);
      return 0;
    }
  }

  /**
   * Get maximum FPS
   * @returns Maximum FPS value
   */
  public getMaxFps(): number {
    if (!this.isInitialized || this.currentFps <= 0) {
      return 0;
    }

    try {
      return this.currentFps;
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to get maximum FPS: ${error}`);
      return 0;
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
      frameCount: this.framesRendered
    };
    return result;
  }

  /**
   * Release resources
   */
  public async release(): Promise<void> {
    try {
      if (this.isInitialized) {
        this.displaySyncInstance?.off('frame', this.frameCallback);
        this.displaySyncInstance?.stop();
        this.displaySyncInstance = null;
        this.isInitialized = false;
        this.currentFps = 0;
        this.resetFrameWindow();
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

  private resetFrameWindow(): void {
    this.frameStartTime = 0;
    this.framesRendered = 0;
  }
}
