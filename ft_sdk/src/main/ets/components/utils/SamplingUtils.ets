import { FTInnerLogger } from '../log/FTLogger';

const TAG = "SamplingUtils";

/**
 * Session keep result class
 */
export class SessionKeepResult {
  public sessionCollect: boolean;
  public sessionErrorCollect: boolean;

  constructor(sessionCollect: boolean, sessionErrorCollect: boolean) {
    this.sessionCollect = sessionCollect;
    this.sessionErrorCollect = sessionErrorCollect;
  }
}

/**
 * Sampling utility class for HarmonyOS SDK
 * Provides sampling rate control for HarmonyOS SDK
 */
export class SamplingUtils {
  private static instance: SamplingUtils | null = null;

  private constructor() {}

  public static getInstance(): SamplingUtils {
    if (!SamplingUtils.instance) {
      SamplingUtils.instance = new SamplingUtils();
    }
    return SamplingUtils.instance;
  }

  /**
   * Check if sampling should be enabled based on sampling rate
   * Enable trace sampling rate
   * 
   * @param sampleRate Sampling rate (0.0 - 1.0)
   * @returns true if sampling should be enabled, false otherwise
   */
  public static enableTraceSamplingRate(sampleRate: number): boolean {
    if (sampleRate <= 0) {
      return false;
    } else if (sampleRate >= 1) {
      return true;
    }

    // Use a continuous value so percentages such as 0.1% retain their
    // intended probability instead of being rounded to one of 101 buckets.
    return Math.random() < sampleRate;
  }

  /**
   * Generate a random number for compatibility with existing internal callers.
   * Generate random number for sampling
   * 
   * @returns Random number between 0 (inclusive) and 1 (exclusive)
   */
  public static generateRandomNumber(): number {
    return Math.random();
  }

  /**
   * Check if session should be kept based on sampling rate
   * Check session keep status
   * 
   * @param sessionId Session ID
   * @param sampleRate Normal sampling rate
   * @param errorSampleRate Error sampling rate
   * @returns Object containing session collection flags
   */
  public static checkSessionKeep(sessionId: string, sampleRate: number, errorSampleRate: number): SessionKeepResult {
    const sessionCollect = SamplingUtils.enableTraceSamplingRate(sampleRate);
    let sessionErrorCollect = false;
    
    // Aligned with Android: Only check error sampling rate when session is NOT collected by normal sampling
    // When session is not sampled by normal sampling rate, check if error sampling rate allows collection
    if (!sessionCollect) {
      sessionErrorCollect = SamplingUtils.enableTraceSamplingRate(errorSampleRate);
    }

    FTInnerLogger.d(TAG, `Session keep check result: sessionId=${sessionId}, sampleRate=${sampleRate}, errorSampleRate=${errorSampleRate}, sessionCollect=${sessionCollect}, sessionErrorCollect=${sessionErrorCollect}`);

    return new SessionKeepResult(sessionCollect, sessionErrorCollect);
  }

}
