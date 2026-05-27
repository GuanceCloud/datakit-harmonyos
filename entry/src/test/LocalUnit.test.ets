import { describe, it, expect } from '@ohos/hypium';

export default function localUnitTest() {
  describe('EntryLocalUnit', () => {
    it('entryUnitSuiteShouldLoad', 0, () => {
      const suiteName = 'entry';

      expect(suiteName).assertEqual('entry');
    });
  });
}
