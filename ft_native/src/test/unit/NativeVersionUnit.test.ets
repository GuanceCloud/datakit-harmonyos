import { describe, it, expect } from '@ohos/hypium';
import { HAR_VERSION } from '../../../Index';

export default function nativeVersionUnitTest() {
  describe('NativeVersionUnit', () => {
    it('publicHarExposeVersionForSdkPackageInfo', 0, () => {
      expect(typeof HAR_VERSION).assertEqual('string');
      expect(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(HAR_VERSION)).assertTrue();
    });
  });
}
