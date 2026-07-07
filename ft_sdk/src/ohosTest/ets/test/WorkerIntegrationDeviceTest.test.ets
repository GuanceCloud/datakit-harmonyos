import { describe, it, expect } from '@ohos/hypium';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { SDKDedicatedPoolType, SDKWorkerResponse } from '../../../main/ets/components/thread/SDKWorkerProtocol';

function getPayloadString(response: SDKWorkerResponse, key: string): string {
  const payload = response.payload as Record<string, object>;
  const value = payload ? payload[key] : undefined;
  return value === undefined || value === null ? '' : String(value);
}

export default function workerIntegrationDeviceTest() {
  describe('WorkerIntegrationDeviceTest', () => {
    it('shouldLoadDedicatedWorkersFromHarPaths', 0, async () => {
      const responses = await SdkInternalTestAccess.probeDedicatedWorkers();
      expect(responses.length).assertEqual(4);

      const expectedPools: string[] = [
        SDKDedicatedPoolType.EVENT_CONSUMER,
        SDKDedicatedPoolType.LOG_CONSUMER,
        SDKDedicatedPoolType.DATA_PROCESS,
        SDKDedicatedPoolType.DATA_UPLOAD
      ];
      const seen: Record<string, boolean> = {};
      for (let i = 0; i < responses.length; i++) {
        const response = responses[i];
        expect(response.ok).assertTrue();
        const pool = getPayloadString(response, 'pool');
        const backend = getPayloadString(response, 'backend');
        const workerName = getPayloadString(response, 'workerName');
        seen[pool] = true;
        expect(backend).assertEqual('thread-worker');
        expect(workerName.length > 0).assertTrue();
      }

      for (let i = 0; i < expectedPools.length; i++) {
        expect(seen[expectedPools[i]] === true).assertTrue();
      }

      const status = SdkInternalTestAccess.getDedicatedPoolStatus();
      for (let i = 0; i < expectedPools.length; i++) {
        const poolStatus = status.pools[expectedPools[i]];
        expect(poolStatus.backend).assertEqual('thread-worker');
        expect(poolStatus.workerPath.length > 0).assertTrue();
      }
    });
  });
}
