/**
 * Thread execution callback interface
 * Used by thread pool for execution callbacks
 * Runner Complete Callback for HarmonyOS
 */
import { FTCrashFreeCommit } from '../../monitor/FTCrashFreeState';

export interface RunnerCompleteCallBack {
  /** Host-only metadata; attached after Worker serialization, never to Line Protocol. */
  crashFreeCommit?: FTCrashFreeCommit;
  /**
   * Called after Runner call ends
   */
  onComplete(): void;
}
