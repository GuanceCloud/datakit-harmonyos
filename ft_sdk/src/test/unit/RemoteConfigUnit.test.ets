import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, FTTraceConfig } from '../../main/ets/components/Configs';
import { FTRemoteConfigManager } from '../../main/ets/components/remote/FTRemoteConfigManager';
import { RemoteConfigBean } from '../../main/ets/components/remote/RemoteConfigBean';
import {
  FTRemoteConfigFetchResult,
  RemoteConfigHttpClient,
  RemoteConfigHttpResponse
} from '../../main/ets/components/remote/RemoteConfigTypes';
import { MemoryRemoteConfigStorage } from '../../main/ets/components/remote/RemoteConfigStorage';
import { SyncTaskManager } from '../../main/ets/components/SyncTaskManager';
import { TraceType } from '../../main/ets/components/trace/TraceType';

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
    beforeEach(() => {
      SyncTaskManager.resetStateInternal();
    });

    afterEach(() => {
      SyncTaskManager.resetStateInternal();
    });

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

    it('endpointSwitchShouldBypassIntervalAndUseTheLatestResponse', 0, async () => {
      const client = new FakeRemoteConfigHttpClient({
        code: 200,
        body: JSON.stringify({ content: { serviceName: 'first-endpoint' } })
      });
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        3600,
        new MemoryRemoteConfigStorage(),
        null,
        client,
        () => 100,
        (value: string) => value
      );

      await manager.initFromRemote('rum-app-id');
      client.response = {
        code: 200,
        body: JSON.stringify({ content: { serviceName: 'second-endpoint' } })
      };
      await manager.refreshForEndpointChange(true);

      expect(client.calls).assertEqual(2);
      expect(manager.getCachedConfig()!.getServiceName()).assertEqual('second-endpoint');
    });

    it('managerShouldMergeCachedValuesBeforeComponentInitialization', 0, () => {
      const storage = new MemoryRemoteConfigStorage();
      storage.save(JSON.stringify({
        md5: 'cached-md5',
        content: {
          env: 'gray',
          serviceName: 'cached-service',
          autoSync: false,
          compressIntakeRequests: false,
          syncPageSize: 30,
          syncSleepTime: 120,
          rumSampleRate: 0.4,
          rumSessionOnErrorSampleRate: 0.9,
          rumEnableTraceUserAction: true,
          rumEnableResourceHostIP: true,
          rumEnableTrackAppUIBlock: true,
          rumBlockDurationMs: 700,
          rumAllowWebViewHost: ['example.com'],
          logSampleRate: 0.2,
          logLevelFilters: ['WARN'],
          logEnableCustomLog: false,
          logEnableConsoleLog: true,
          traceSampleRate: 0.3,
          traceEnableAutoTrace: true,
          traceType: 'traceparent'
        }
      }), 1);
      const remoteManager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        0,
        storage,
        null
      );
      remoteManager.initFromLocalCache();
      const sdkConfig = FTSDKConfig.builder('http://datakit.local');
      const rumConfig = new FTRUMConfig();
      const logConfig = new FTLoggerConfig();
      const traceConfig = new FTTraceConfig();

      remoteManager.mergeSDKConfigFromCache(sdkConfig);
      remoteManager.mergeRUMConfigFromCache(rumConfig);
      remoteManager.mergeLogConfigFromCache(logConfig);
      remoteManager.mergeTraceConfigFromCache(traceConfig);

      expect(sdkConfig.getEnv()).assertEqual('gray');
      expect(sdkConfig.getServiceName()).assertEqual('cached-service');
      expect(sdkConfig.isAutoSyncEnabled()).assertFalse();
      expect(sdkConfig.isCompressIntakeRequests()).assertFalse();
      expect(sdkConfig.getPageSize()).assertEqual(30);
      expect(rumConfig.getSamplingRate()).assertEqual(0.4);
      expect(rumConfig.getSessionErrorSampleRate()).assertEqual(0.9);
      expect(rumConfig.isEnableTraceUserAction()).assertTrue();
      expect(rumConfig.isEnableResourceHostIP()).assertTrue();
      expect(rumConfig.getBlockDurationMS()).assertEqual(700);
      expect(rumConfig.getAllowWebViewHost()![0]).assertEqual('example.com');
      expect(logConfig.getSamplingRate()).assertEqual(0.2);
      expect(logConfig.isEnableCustomLog()).assertFalse();
      expect(logConfig.isEnableConsoleLog()).assertTrue();
      expect(logConfig.getLogLevelFilters()[0]).assertEqual('WARN');
      expect(traceConfig.getSamplingRate()).assertEqual(0.3);
      expect(traceConfig.isEnableAutoTrace()).assertTrue();
      expect(traceConfig.getTraceType()).assertEqual(TraceType.TRACEPARENT);
    });

    it('syncTaskShouldHotUpdateSupportedUploadValues', 0, () => {
      const syncTask = SyncTaskManager.getInstance();
      syncTask.init(FTSDKConfig.builder('http://datakit.local').setAutoSync(false));
      const bean = RemoteConfigBean.buildFromConfigJson(JSON.stringify({
        content: {
          autoSync: true,
          syncPageSize: 22,
          syncSleepTime: 300
        }
      }));

      syncTask.hotUpdate(bean);

      expect(syncTask.isAutoSyncEnabled()).assertTrue();
      expect(syncTask.getPageSize()).assertEqual(22);
      expect(syncTask.getSyncSleepTime()).assertEqual(300);
    });
  });
}
