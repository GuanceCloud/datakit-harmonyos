import { describe, it, expect } from '@ohos/hypium';
import { createFTHttpInterceptorChain } from '../../../main/ets/components/network/FTHttpAutoTrackExt';

export default function testsuite() {
  describe('FTSdkExtDeviceSmokeTest', () => {
    it('httpInterceptorChainShouldCreateOnDeviceTarget', 0, () => {
      const chain = createFTHttpInterceptorChain({
        enableTraceInterceptor: false,
        enableResourceInterceptor: false
      });

      expect(chain !== null).assertTrue();
      expect(chain.getChain().length).assertEqual(0);
    });
  });
}
