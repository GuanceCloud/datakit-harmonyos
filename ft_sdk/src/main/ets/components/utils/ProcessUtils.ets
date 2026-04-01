import { process } from '@kit.ArkTS';
import { FTInnerLogger, FTLogger } from '../log/FTLogger';

const TAG = "ProcessUtils";

/**
 * Process utility class for HarmonyOS
 * Used to determine if current process is the main process
 */
export class ProcessUtils {
  // Store main process PID
  private static mainProcessId: number | null = null;

  /**
   * Check if current process is the main process
   * @returns true if current process is main process, false otherwise
   */
  public static isMainProcess(): boolean {
    if (ProcessUtils.mainProcessId === null) {
      // If main process ID is not initialized, assume current process is main process
      // This can happen if initMainProcessId() was not called
      FTInnerLogger.w(TAG, "Main process ID not initialized, assuming current process is main process");
      ProcessUtils.mainProcessId = process.pid;
      return true;
    }
    const isMain = process.pid === ProcessUtils.mainProcessId;
    FTInnerLogger.i(TAG, `Current PID: ${process.pid}, Main PID: ${ProcessUtils.mainProcessId}, Is Main: ${isMain}`);
    return isMain;
  }

  /**
   * Get current process PID
   * @returns current process PID
   */
  public static getCurrentProcessId(): number {
    return process.pid;
  }

  /**
   * Get main process PID
   * @returns main process PID, or null if not initialized
   */
  public static getMainProcessId(): number | null {
    return ProcessUtils.mainProcessId;
  }
}

