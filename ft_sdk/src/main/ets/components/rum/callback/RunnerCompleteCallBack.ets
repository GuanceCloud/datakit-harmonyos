/**
 * Thread execution callback interface
 * Used by thread pool for execution callbacks
 * Runner Complete Callback for HarmonyOS
 */
export interface RunnerCompleteCallBack {
  /**
   * Called after Runner call ends
   */
  onComplete(): void;
}
