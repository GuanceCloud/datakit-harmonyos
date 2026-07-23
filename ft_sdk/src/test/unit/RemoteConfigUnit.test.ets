import { describe, it, expect } from '@ohos/hypium';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { FTRemoteConfigManager } from '../../main/ets/components/remote/FTRemoteConfigManager';
import { RemoteConfigBean } from '../../main/ets/components/remote/RemoteConfigBean';
import {
  FTRemoteConfigFetchResult,
  RemoteConfigHttpClient,
  RemoteConfigHttpResponse
} from '../../main/ets/components/remote/RemoteConfigTypes';
import { MemoryRemoteConfigStorage } from '../../main/ets/components/remote/RemoteConfigStorage';

class FakeRemoteConfigHttpClient implements RemoteConfigHttpClient {
  public calls: number = 0;
  public appId: string = '';
  public response: RemoteConfigHttpResponse;

  public constructor(response: RemoteConfigHttpResponse) {
    this.response = response;
  }

  async fetch(_config: Object, appId: string): Promise<RemoteConfigHttpResponse> {
    this.calls++;
    this.appId = appId;
    return this.response;
  }
}

class RecordingFetchResult implements FTRemoteConfigFetchResult {
  public fetchCalls: number = 0;
  public resultCalls: Array<boolean> = [];
  public overrideServiceName: string | null = null;

  onConfigSuccessFetched(configBean: RemoteConfigBean, _jsonConfig: string): RemoteConfigBean | null {
    this.fetchCalls++;
    if (this.overrideServiceName !== null) {
      configBean.setServiceName(this.overrideServiceName);
    }
    return null;
  }

  onResult(success: boolean): void {
    this.resultCalls.push(success);
  }
}

export default function remoteConfigUnitTest() {
  describe('RemoteConfigUnit', () => {
    it('beanShouldParseAndRetainUnknownContent', 0, () => {
      const bean = RemoteConfigBean.buildFromConfigJson(JSON.stringify({
        md5: 'cached-md5',
        content: {
          env: 'gray',
          serviceName: 'remote-service',
          rumSampleRate: 0.5,
          rumAllowWebViewHost: ['example.com'],
          unsupportedServerKey: 'retained'
        }
      }));

      expect(bean.isValid()).assertTrue();
      expect(bean.getMd5()).assertEqual('cached-md5');
      expect(bean.getRumSampleRate()).assertEqual(0.5);
      expect(bean.getRumAllowWebViewHost()![0]).assertEqual('example.com');
      bean.setServiceName('callback-service');
      const serialized = bean.toJsonString();
      expect(serialized.indexOf('callback-service') >= 0).assertTrue();
      expect(serialized.indexOf('unsupportedServerKey') >= 0).assertTrue();
    });

    it('managerShouldFetchOverridePersistAndDeduplicate', 0, async () => {
      const body = JSON.stringify({
        content: {
          serviceName: 'server-service',
          autoSync: false,
          syncPageSize: 30
        }
      });
      const client = new FakeRemoteConfigHttpClient({ code: 200, body: body });
      const storage = new MemoryRemoteConfigStorage();
      const callback = new RecordingFetchResult();
      callback.overrideServiceName = 'callback-service';
      let now = 100;
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        30,
        storage,
        callback,
        client,
        () => now,
        (_value: string) => 'body-md5'
      );

      await manager.initFromRemote('rum-app-id');

      expect(client.appId).assertEqual('rum-app-id');
      expect(callback.fetchCalls).assertEqual(1);
      expect(callback.resultCalls.length).assertEqual(1);
      expect(callback.resultCalls[0]).assertTrue();
      expect(storage.loadFetchTime()).assertEqual(100);
      expect(storage.loadConfig() !== null).assertTrue();
      expect(manager.getCachedConfig()!.getServiceName()).assertEqual('callback-service');

      now = 101;
      await manager.updateRemoteConfig(0);
      expect(client.calls).assertEqual(2);
      expect(callback.fetchCalls).assertEqual(1);
      expect(callback.resultCalls[1]).assertTrue();
      expect(storage.loadFetchTime()).assertEqual(101);
    });

    it('managerShouldRejectIntervalSkipAndRememberAValidEmptyChange', 0, async () => {
      const client = new FakeRemoteConfigHttpClient({
        code: 200,
        body: JSON.stringify({ content: { env: 'prod' } })
      });
      const storage = new MemoryRemoteConfigStorage();
      const callback = new RecordingFetchResult();
      let now = 50;
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        10,
        storage,
        callback,
        client,
        () => now,
        (_value: string) => 'md5'
      );

      await manager.initFromRemote('rum-app-id');
      await manager.updateRemoteConfig();

      expect(client.calls).assertEqual(1);
      expect(callback.resultCalls.length).assertEqual(2);
      expect(callback.resultCalls[0]).assertTrue();
      expect(callback.resultCalls[1]).assertFalse();
      now = 61;
      await manager.updateRemoteConfig();
      expect(client.calls).assertEqual(2);
      expect(storage.loadFetchTime()).assertEqual(61);
    });
  });
}
