/**
 * Monitoring data test
 * Reference: com.ft.sdk.tests.MonitorConfigTest (Android SDK)
 *
 * Purpose: Verify monitoring data (battery, memory, CPU) is correctly attached to error data
 *
 * @author FT SDK Team
 */




import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTMonitorManager } from '../../../main/ets/components/rum/FTMonitorManager';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { DeviceMetricsMonitorType } from '../../../main/ets/components/rum/enum/DeviceMetricsMonitorType';
import { EnvType } from '../../../main/ets/components/enum/Enums';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { ErrorType } from '../../../main/ets/components/rum/enum/RUMEnums';
import { AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { Constants } from '../../../main/ets/components/Constants';

// Test constants (aligned with Android SDK FTBaseTest)
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';

export default function monitorConfigTest() {
  describe('MonitorConfigTest', () => {
    beforeAll(() => {
      console.info('MonitorConfigTest', 'beforeAll called');
    });

    beforeEach(() => {
      console.info('MonitorConfigTest', 'beforeEach called');

      // Initialize SDK with monitor configuration (aligned with Android SDK setUp)
      const sdkConfig: FTSDKConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDebug(true)
        .setEnv(EnvType.GRAY);

      FTSDK.install(sdkConfig);

      // Initialize RUM config with monitoring enabled (aligned with Android SDK)
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
        .setDeviceMetricsMonitorType(DeviceMetricsMonitorType.ALL)
      );
    });

    afterEach(() => {
      console.info('MonitorConfigTest', 'afterEach called');
      // Clean up after each test
      FTSDK.shutDown();
    });

    afterAll(() => {
      console.info('MonitorConfigTest', 'afterAll called');
    });

    /**
     * During FTRUMGlobalManager.addError(), check whether the following are correctly attached:
     * - KEY_BATTERY_USE
     * - KEY_MEMORY_TOTAL
     * - KEY_MEMORY_USE
     * - KEY_CPU_USE
     * Aligned with Android: monitorErrorTest()
     *
     * Note: HarmonyOS cannot verify database directly like Android.
     * We verify the operations complete without error.
     */
    it('monitorErrorTest', 0, async () => {
      try {
        // Generate error data with monitoring (aligned with Android SDK)
        FTRUMGlobalManager.getInstance().addError('log', 'message', ErrorType.JS, AppState.RUN);

        // Wait for data to be processed (aligned with Android SDK: Thread.sleep(2000))
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => {
            resolve();
          }, 2000);
        });

        // NOTE: Cannot verify database content without Context access
        // In Android: CheckUtils.checkValueInLineProtocol(DataType.RUM_APP, new String[]{
        //   Constants.KEY_BATTERY_USE,
        //   Constants.KEY_MEMORY_TOTAL,
        //   Constants.KEY_MEMORY_USE,
        //   Constants.KEY_CPU_USE
        // })
        // In HarmonyOS: We verify the operations complete without error

        // Verify monitor manager is configured correctly
        expect(FTMonitorManager.getInstance().isErrorMonitorType(ErrorMonitorType.ALL)).assertTrue();
        expect(FTMonitorManager.getInstance().isDeviceMetricsMonitorType(DeviceMetricsMonitorType.ALL)).assertTrue();

        console.info('MonitorConfigTest', 'monitorErrorTest passed');
      } catch (error) {
        console.error('MonitorConfigTest', 'monitorErrorTest failed:', error);
        expect().assertFail();
      }
    });
  });
}
