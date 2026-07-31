import { describe, it, expect } from '@ohos/hypium';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { FTRemoteDataFilterManager } from '../../main/ets/components/remote/FTRemoteDataFilterManager';
import {
  RemoteDataFilterHttpClient,
  RemoteDataFilterHttpResponse,
  RemoteDataFilterHash,
  RemoteDataFilterScheduler
} from '../../main/ets/components/remote/RemoteDataFilterTypes';

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

class FakeRemoteDataFilterScheduler implements RemoteDataFilterScheduler {
  public delays: Array<number> = [];
  public cancelled: Array<number> = [];
  private nextTimerId: number = 1;

  schedule(delayMs: number, _callback: () => void): number {
    this.delays.push(delayMs);
    return this.nextTimerId++;
  }

  cancel(timerId: number): void {
    this.cancelled.push(timerId);
  }
}

export default function remoteDataFilterUnitTest() {
  describe('RemoteDataFilterUnit', () => {
    it('shouldApplyLoggingAndRumRulesAtTheServerInterval', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: JSON.stringify({
          filters: {
            logging: ["{ message match ['password'] }"],
            rum: ["{ source = 'resource' }"]
          },
          pull_interval: '1m20s'
        })
      });
      const scheduler = new FakeRemoteDataFilterScheduler();
      const applied: Array<Map<string, Array<string>>> = [];
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (filters: Map<string, Array<string>>) => applied.push(filters),
        client,
        scheduler
      );

      await manager.start();

      expect(client.calls).assertEqual(1);
      expect(applied.length).assertEqual(1);
      expect(applied[0].get('logging')![0]).assertEqual("{ message match ['password'] }");
      expect(applied[0].get('rum')![0]).assertEqual("{ source = 'resource' }");
      expect(scheduler.delays.length).assertEqual(1);
      expect(scheduler.delays[0]).assertEqual(80_000);
      manager.close();
      expect(scheduler.cancelled.length).assertEqual(1);
    });

    it('shouldFallbackToTenSecondsForInvalidPayloadOrInterval', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: JSON.stringify({ filters: { logging: [] }, pull_interval: 'bad-value' })
      });
      const scheduler = new FakeRemoteDataFilterScheduler();
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (_filters: Map<string, Array<string>>) => {},
        client,
        scheduler
      );

      await manager.start();
      expect(scheduler.delays[0]).assertEqual(10_000);

      client.response = { code: 200, body: '{}' };
      await manager.refreshForEndpointChange();
      expect(scheduler.delays[1]).assertEqual(10_000);
      manager.close();
    });

    it('shouldKeepPullingAtTheServerIntervalAndSkipUnchangedPayloads', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: JSON.stringify({
          filters: { logging: ["{ message = 'blocked' }"] },
          pull_interval: '45s'
        })
      });
      const scheduler = new FakeRemoteDataFilterScheduler();
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
        scheduler,
        hash
      );

      await manager.start();
      await manager.start();

      expect(client.calls).assertEqual(2);
      expect(hashCalls).assertEqual(2);
      expect(applied.length).assertEqual(1);
      expect(scheduler.delays.length).assertEqual(2);
      expect(scheduler.delays[0]).assertEqual(45_000);
      expect(scheduler.delays[1]).assertEqual(45_000);
      manager.close();
    });

    it('shouldClearOldRulesBeforeRefreshingAfterEndpointSwitch', 0, async () => {
      const client = new FakeRemoteDataFilterHttpClient({
        code: 200,
        body: JSON.stringify({
          filters: { logging: ["{ message in ['old'] }"] },
          pull_interval: 30
        })
      });
      const scheduler = new FakeRemoteDataFilterScheduler();
      const applied: Array<Map<string, Array<string>>> = [];
      const manager = new FTRemoteDataFilterManager(
        FTSDKConfig.builder('http://datakit.local'),
        () => true,
        (filters: Map<string, Array<string>>) => applied.push(filters),
        client,
        scheduler
      );
      await manager.start();

      client.response = {
        code: 200,
        body: JSON.stringify({
          filters: { rum: ["{ source in ['resource'] }"] },
          pull_interval: '2m'
        })
      };
      await manager.refreshForEndpointChange();

      expect(applied.length).assertEqual(3);
      expect(applied[1].size).assertEqual(0);
      expect(applied[2].get('logging') === undefined).assertTrue();
      expect(applied[2].get('rum')![0]).assertEqual("{ source in ['resource'] }");
      expect(scheduler.delays[1]).assertEqual(120_000);
      manager.close();
    });
  });
}
