/**
 * Inner test configuration set
 * Reference: com.ft.sdk.InnerConfigSet (Android SDK)
 *
 * @author FT SDK Team
 */

import { NetworkUtils } from '../main/ets/components/utils/NetworkUtils';

export class InnerConfigSet {
  /**
   * Enable network for testing
   * In HarmonyOS, this is handled by the test framework
   */
  public static enableNetwork(): void {
    // In HarmonyOS test environment, network is controlled by system
    // We don't need to manually set network state like Android
    // This method is kept for API compatibility with Android SDK
  }
}
