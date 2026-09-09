import { describe, it, expect } from '@ohos/hypium';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { FTRemoteDataFilterManager } from '../../main/ets/components/remote/FTRemoteDataFilterManager';
import {
  RemoteDataFilterHttpClient,
  RemoteDataFilterHttpResponse,
  RemoteDataFilterHash,
  RemoteDataFilterClock
} from '../../main/ets/components/remote/RemoteDataFilterTypes';

interface RemoteDataFilterTestRules {
  logging?: string[];
  rum?: string[];
}

interface RemoteDataFilterTestPayload {
  filters: RemoteDataFilterTestRules;
  pull_interval: string | number;
}

function stringifyRemoteDataFilter(payload: RemoteDataFilterTestPayload): string {
  return JSON.stringify(payload);
}

class FakeRemoteDataFilterHttpClient implements RemoteDataFilterHttpClient {
  public calls: number = 0;
  public response: RemoteDataFilterHttpResponse;

  public constructor(response: RemoteDataFilterHttpResponse) {
    this.response = response;
  }

  async fetch(_config: FTSDKConfig): Promise<RemoteDataFilterHttpResponse> {
    this.calls++;
    return this.response;
  }
}

export default function remoteDataFilterUnitTest() {
  describe('RemoteDataFilterUnit', () => {
    it('serverIntervalAppliesLogAndRumRules', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: stringifyRemoteDataFilter({
          filters: {
            logging: ["{ message match ['password'] }"],
            rum: ["{ source = 'resource' }"]
          },
          pull_interval: '1m20s'
        })
      });
      let currentTimeMs = 1_000;
      const clock: RemoteDataFilterClock = (): number => currentTimeMs;
      const applied: Array<Map<string, Array<string>>> = [];
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (filters: Map<string, Array<string>>) => applied.push(filters),
        client,
        undefined,
        clock
      );

      await manager.start();

      expect(client.calls).assertEqual(1);
      expect(applied.length).assertEqual(1);
      expect(applied[0].get('logging')![0]).assertEqual("{ message match ['password'] }");
      expect(applied[0].get('rum')![0]).assertEqual("{ source = 'resource' }");
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(1);
      currentTimeMs += 80_000;
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(2);
      manager.close();
    });

    it('invalidFilterConfigUsesTenSeconds', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: stringifyRemoteDataFilter({ filters: { logging: [] }, pull_interval: 'bad-value' })
      });
      let currentTimeMs = 1_000;
      const clock: RemoteDataFilterClock = (): number => currentTimeMs;
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (_filters: Map<string, Array<string>>) => {},
        client,
        undefined,
        clock
      );

      await manager.start();
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(1);
      currentTimeMs += 10_000;
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(2);

      client.response = { code: 200, body: '{}' };
      await manager.refreshForEndpointChange();
      expect(client.calls).assertEqual(3);
      manager.close();
    });

    it('filterPollsOnScheduleAndSkipsUnchanged', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: stringifyRemoteDataFilter({
          filters: { logging: ["{ message = 'blocked' }"] },
          pull_interval: '45s'
        })
      });
      let currentTimeMs = 1_000;
      const clock: RemoteDataFilterClock = (): number => currentTimeMs;
      const applied: Array<Map<string, Array<string>>> = [];
      let hashCalls = 0;
      const hash: RemoteDataFilterHash = (_value: string): string => {
        hashCalls++;
        return 'unchanged-payload-md5';
      };
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (filters: Map<string, Array<string>>) => applied.push(filters),
        client,
        hash,
        clock
      );

      await manager.start();
      currentTimeMs += 45_000;
      await manager.syncRemoteIfNeeded();

      expect(client.calls).assertEqual(2);
      expect(hashCalls).assertEqual(2);
      expect(applied.length).assertEqual(1);
      manager.close();
    });

    it('endpointSwitchClearsOldRules', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: stringifyRemoteDataFilter({
          filters: { logging: ["{ message in ['old'] }"] },
          pull_interval: 30_000_000_000
        })
      });
      const applied: Array<Map<string, Array<string>>> = [];
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (filters: Map<string, Array<string>>) => applied.push(filters),
        client
      );
      await manager.start();

      client.response = {
        code: 200,
        body: stringifyRemoteDataFilter({
          filters: { rum: ["{ source in ['resource'] }"] },
          pull_interval: '2m'
        })
      };
      await manager.refreshForEndpointChange();

      expect(applied.length).assertEqual(3);
      expect(applied[1].size).assertEqual(0);
      expect(applied[2].get('logging') === undefined).assertTrue();
      expect(applied[2].get('rum')![0]).assertEqual("{ source in ['resource'] }");
      manager.close();
    });

    it('shouldTreatNumericPullIntervalAsNanoseconds', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: JSON.stringify({
          filters: { logging: [] },
          pull_interval: 10_000_000_000
        })
      });
      let currentTimeMs = 1_000;
      const clock: RemoteDataFilterClock = (): number => currentTimeMs;
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (_filters: Map<string, Array<string>>) => {},
        client,
        undefined,
        clock
      );

      await manager.start();

      currentTimeMs += 9_999;
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(1);
      currentTimeMs += 1;
      await manager.syncRemoteIfNeeded();
      expect(client.calls).assertEqual(2);
      manager.close();
    });
  });
}
