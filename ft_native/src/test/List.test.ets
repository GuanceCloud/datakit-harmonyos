import { describe, it, expect } from '@ohos/hypium';
import { HAR_VERSION } from '../../Index';

export default function testsuite() {
  describe('Native', () => {
    it('harVersionShouldBeExported', 0, () => {
      expect(HAR_VERSION.length > 0).assertTrue();
    });
  });
}
