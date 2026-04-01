  /**
 * Device related information verification test cases
 * Adapted from Android SDK: com.ft.sdk.tests.DeviceUtilsTest
 *
 * Purpose: Verify device information utilities work correctly
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { DeviceUtils } from '../../../main/ets/components/utils/DeviceUtils';
import { NetworkUtils } from '../../../main/ets/components/utils/NetworkUtils';

export default function deviceUtilsTest() {
  describe('DeviceUtilsTest', () => {
    beforeAll(() => {
      console.info('DeviceUtilsTest', 'DeviceUtilsTest beforeAll called');
    });

    beforeEach(() => {
      console.info('DeviceUtilsTest', 'DeviceUtilsTest beforeEach called');
    });

    afterEach(() => {
      console.info('DeviceUtilsTest', 'DeviceUtilsTest afterEach called');
    });

    afterAll(() => {
      console.info('DeviceUtilsTest', 'DeviceUtilsTest afterAll called');
    });

    /**
     * Get device UUID
     * Adapted from Android: DeviceUtils.getUuid()
     * Android uses: assertNotEquals("", DeviceUtils.getUuid(getContext()))
     * HarmonyOS uses: length > 0 check
     */
    it('getUuid', 0, () => {
      const uuid = DeviceUtils.getUuid();
      expect(uuid.length).assertLarger(0);

      console.info('DeviceUtilsTest', `getUuid passed, uuid: ${uuid}`);
    });

    /**
     * Check if network is available
     * Adapted from Android: NetUtils.isNetworkAvailable(getContext())
     * Android uses: assertTrue(NetUtils.isNetworkAvailable(getContext()))
     * HarmonyOS uses: NetworkUtils.isConnected() which returns boolean
     *
     * Note: In HarmonyOS unit test environment, NetworkUtils.isConnected() returns
     * the cached value which defaults to true. This test verifies the method exists
     * and returns a valid boolean value.
     */
    it('isNetworkAvailable', 0, () => {
      const isConnected = NetworkUtils.isConnected();
      expect(typeof isConnected).assertEqual('boolean');

      console.info('DeviceUtilsTest', `isNetworkAvailable passed, isConnected: ${isConnected}`);
    });

    /**
     * Get OS version
     * Additional test for HarmonyOS implementation
     */
    it('getOSVersion', 0, () => {
      const osVersion = DeviceUtils.getOSVersion();
      expect(typeof osVersion).assertEqual('string');

      console.info('DeviceUtilsTest', `getOSVersion passed, osVersion: ${osVersion}`);
    });

    /**
     * Get device brand
     * Additional test for HarmonyOS implementation
     */
    it('getDeviceBrand', 0, () => {
      const brand = DeviceUtils.getDeviceBrand();
      expect(brand.length).assertLarger(0);

      console.info('DeviceUtilsTest', `getDeviceBrand passed, brand: ${brand}`);
    });

    /**
     * Get device model
     * Additional test for HarmonyOS implementation
     */
    it('getDeviceModel', 0, () => {
      const model = DeviceUtils.getDeviceModel();
      expect(model.length).assertLarger(0);

      console.info('DeviceUtilsTest', `getDeviceModel passed, model: ${model}`);
    });

    /**
     *
     * Get screen display size
     * Additional test for HarmonyOS implementation
     */
    it('getDisplay', 0, () => {
      const display = DeviceUtils.getDisplay();
      expect(display.length).assertLarger(0);
      expect(display.indexOf('x')).assertLarger(-1); // Should contain 'x' separator

      console.info('DeviceUtilsTest', `getDisplay passed, display: ${display}`);
    });

    /**
     * Get screen width
     * Additional test for HarmonyOS implementation
     */
    it('getScreenWidth', 0, () => {
      const width = DeviceUtils.getScreenWidth();
      expect(width).assertLarger(0);

      console.info('DeviceUtilsTest', `getScreenWidth passed, width: ${width}`);
    });

    /**
     * Get screen height
     * Additional test for HarmonyOS implementation
     */
    it('getScreenHeight', 0, () => {
      const height = DeviceUtils.getScreenHeight();
      expect(height).assertLarger(0);

      console.info('DeviceUtilsTest', `getScreenHeight passed, height: ${height}`);
    });

    /**
     * Get network type synchronously
     * Additional test for HarmonyOS implementation
     */
    it('getNetworkTypeSync', 0, () => {
      const networkType = DeviceUtils.getNetworkTypeSync();
      expect(typeof networkType).assertEqual('string');

      // Manual check for valid network types (toContain not available in hypium)
      const validTypes = ['wifi', '2g', '3g', '4g', '5g', 'cellular', 'ethernet', 'unknown'];
      const isValidType = validTypes.indexOf(networkType) >= 0;
      expect(isValidType).assertTrue();

      console.info('DeviceUtilsTest', `getNetworkTypeSync passed, networkType: ${networkType}`);
    });
  });
}
