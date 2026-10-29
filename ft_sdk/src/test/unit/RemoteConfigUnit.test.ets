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
import { Status as LogLevel } from '../../main/ets/components/bean/Status';
import { resolveAllowedWebViewHosts } from '../../main/ets/components/web/FTWebViewHostPolicy';

interface RemoteConfigTestContent {
  env?: string;
  serviceName?: string;
  autoSync?: boolean;
  compressIntakeRequests?: boolean;
  syncPageSize?: number;
  syncSleepTime?: number;
  rumSampleRate?: number;
  rumSessionOnErrorSampleRate?: number;
  sessionSamplingRate?: number;
  sessionOnErrorSamplingRate?: number;
  rumEnableTraceUserAction?: boolean;
  rumEnableResourceHostIP?: boolean;
  rumEnableTrackAppUIBlock?: boolean;
  rumBlockDurationMs?: number;
  rumAllowWebViewHost?: string[] | null;
  logSampleRate?: number;
  logSamplingRate?: number;
  logLevelFilters?: string[];
  logEnableCustomLog?: boolean;
  logEnableConsoleLog?: boolean;
  traceSampleRate?: number;
  traceSamplingRate?: number;
  traceEnableAutoTrace?: boolean;
  traceType?: string;
  unsupportedServerKey?: string;
}

interface RemoteConfigTestPayload {
  md5?: string;
  content: RemoteConfigTestContent;
}

function stringifyRemoteConfig(payload: RemoteConfigTestPayload): string {
  return JSON.stringify(payload);
}

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
    it('Host updates persist all three states and release overrides when absent', 0, async () => {
      const base = FTSDKConfig.builder('http://datakit.local').setAllowWebViewHost(['base.test']);
      const rum = new FTRUMConfig().setAllowWebViewHost(['legacy.test']);
      const client = new FakeRemoteConfigHttpClient({ code: 200,
        body: stringifyRemoteConfig({ content: { rumAllowWebViewHost: [] } }) });
      const storage = new MemoryRemoteConfigStorage();
      const manager = new FTRemoteConfigManager(base, 0, storage, null, client, () => 100,
        (value: string): string => value);
      manager.setConfigAppliedListener(() => manager.mergeSDKConfigFromCache(base));
      await manager.initFromRemote('rum-app');
      expect(resolveAllowedWebViewHosts(base, rum.getAllowWebViewHost())!.length).assertEqual(0);
      // Invalid updates preserve the last accepted list, including after cache restoration.
      client.response = { code: 200, body: '{"content":{"rumAllowWebViewHost":[null]}}' };
      await manager.updateRemoteConfig(0);
      const restored = new FTRemoteConfigManager(base, 0, storage, null, client);
      restored.initFromLocalCache();
      restored.mergeSDKConfigFromCache(base);
      expect(base.hasRemoteAllowWebViewHostInternal()).assertTrue();
      expect(base.getRemoteAllowWebViewHostInternal()!.length).assertEqual(0);
      client.response = { code: 200, body: stringifyRemoteConfig({ content: { rumAllowWebViewHost: null } }) };
      await manager.updateRemoteConfig(0);
      expect(resolveAllowedWebViewHosts(base, rum.getAllowWebViewHost())).assertNull();
      expect(storage.loadConfig()!.includes('"rumAllowWebViewHost":null')).assertTrue();
      client.response = { code: 200, body: stringifyRemoteConfig({ content: {} }) };
      await manager.updateRemoteConfig(0);
      expect(resolveAllowedWebViewHosts(base, rum.getAllowWebViewHost())!.join(',')).assertEqual('base.test');
      expect(rum.getAllowWebViewHost()!.join(',')).assertEqual('legacy.test');
      manager.close();
      restored.close();
    });

    beforeEach(() => {
      SyncTaskManager.resetStateInternal();
    });

    afterEach(() => {
      SyncTaskManager.resetStateInternal();
    });

    it('beanShouldParseAndRetainUnknownContent', 0, () => {
      const bean = RemoteConfigBean.buildFromConfigJson(stringifyRemoteConfig({
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

    it('remoteConfigFetchMergeSaveAndDedup', 0, async () => {
      const body = stringifyRemoteConfig({
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

    it('configTracksIntervalSkipAndEmptyChange', 0, async () => {
      const client = new FakeRemoteConfigHttpClient({
        code: 200,
        body: stringifyRemoteConfig({ content: { env: 'prod' } })
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

    it('endpointSwitchFetchesLatestImmediately', 0, async () => {
      const client = new FakeRemoteConfigHttpClient({
        code: 200,
        body: stringifyRemoteConfig({ content: { serviceName: 'first-endpoint' } })
      });
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        3600,
        new MemoryRemoteConfigStorage(),
        null,
        client,
        () => 10_000,
        (value: string) => value
      );

      await manager.initFromRemote('rum-app-id');
      expect(client.calls).assertEqual(1);
      expect(manager.getCachedConfig()!.getServiceName()).assertEqual('first-endpoint');
      client.response = {
        code: 200,
        body: stringifyRemoteConfig({ content: { serviceName: 'second-endpoint' } })
      };
      await manager.refreshForEndpointChange(true);

      expect(client.calls).assertEqual(2);
      expect(manager.getCachedConfig()!.getServiceName()).assertEqual('second-endpoint');
    });

    it('cachedConfigMergesBeforeComponentInit', 0, () => {
      const storage = new MemoryRemoteConfigStorage();
      storage.save(stringifyRemoteConfig({
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
      expect(rumConfig.getAllowWebViewHost() === null).assertTrue();
      expect(sdkConfig.hasRemoteAllowWebViewHostInternal()).assertTrue();
      expect(sdkConfig.getRemoteAllowWebViewHostInternal()![0]).assertEqual('example.com');
      expect(logConfig.getSamplingRate()).assertEqual(0.2);
      expect(logConfig.isEnableCustomLog()).assertFalse();
      expect(logConfig.isEnableConsoleLog()).assertTrue();
      expect(logConfig.getLogLevelFilters()[0]).assertEqual(LogLevel.WARN.name);
      expect(traceConfig.getSamplingRate()).assertEqual(0.3);
      expect(traceConfig.isEnableAutoTrace()).assertTrue();
      expect(traceConfig.getTraceType()).assertEqual(TraceType.TRACEPARENT);
    });

    it('newRemoteSamplingRatesShouldWinAndKeepExplicitZero', 0, () => {
      const storage = new MemoryRemoteConfigStorage();
      storage.save(stringifyRemoteConfig({
        content: {
          rumSampleRate: 0.2,
          sessionSamplingRate: 0,
          rumSessionOnErrorSampleRate: 0.2,
          sessionOnErrorSamplingRate: 0.1,
          logSampleRate: 0.5,
          logSamplingRate: 1,
          traceSampleRate: 0.1,
          traceSamplingRate: 99.9
        }
      }), 1);
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        0,
        storage,
        null
      );
      manager.initFromLocalCache();

      const rum = new FTRUMConfig()
        .setSessionSamplingRate(20)
        .setSessionOnErrorSamplingRate(20);
      const log = new FTLoggerConfig().setLogSamplingRate(20);
      const trace = new FTTraceConfig().setTraceSamplingRate(20);
      manager.mergeRUMConfigFromCache(rum);
      manager.mergeLogConfigFromCache(log);
      manager.mergeTraceConfigFromCache(trace);

      expect(rum.getSessionSamplingRate()).assertEqual(0);
      expect(rum.getSessionOnErrorSamplingRate()).assertEqual(0.1);
      expect(log.getLogSamplingRate()).assertEqual(1);
      expect(trace.getTraceSamplingRate()).assertEqual(99.9);
      expect(rum.getSamplingRate()).assertEqual(0);
      expect(rum.getSessionErrorSampleRate()).assertEqual(0.001);
      expect(log.getSamplingRate()).assertEqual(0.01);
      expect(Math.abs(trace.getSamplingRate() - 0.999) < 1e-12).assertTrue();
    });

    it('invalidNewRemoteSamplingRateShouldKeepPreviousValueAndCacheIt', 0, async () => {
      const storage = new MemoryRemoteConfigStorage();
      const client = new FakeRemoteConfigHttpClient({
        code: 200,
        body: stringifyRemoteConfig({ content: { sessionSamplingRate: 20 } })
      });
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        0,
        storage,
        null,
        client,
        () => 10,
        (value: string) => value
      );
      const rum = new FTRUMConfig().setSessionSamplingRate(50);

      await manager.initFromRemote('rum-app-id');
      manager.mergeRUMConfigFromCache(rum);
      expect(rum.getSessionSamplingRate()).assertEqual(20);

      client.response = {
        code: 200,
        body: stringifyRemoteConfig({
          content: { sessionSamplingRate: 101, rumSampleRate: 0.1 }
        })
      };
      await manager.updateRemoteConfig(0);
      manager.mergeRUMConfigFromCache(rum);
      expect(rum.getSessionSamplingRate()).assertEqual(20);
      expect(storage.loadConfig()!.indexOf('"sessionSamplingRate":20') >= 0).assertTrue();

      const restored = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        0,
        storage,
        null
      );
      restored.initFromLocalCache();
      const restoredRum = new FTRUMConfig().setSessionSamplingRate(50);
      restored.mergeRUMConfigFromCache(restoredRum);
      expect(restoredRum.getSessionSamplingRate()).assertEqual(20);
    });

    it('invalidNewRemoteSamplingRateShouldNotUseOldKeyWithoutPriorValue', 0, () => {
      const storage = new MemoryRemoteConfigStorage();
      storage.save(stringifyRemoteConfig({
        content: { sessionSamplingRate: 101, rumSampleRate: 0.1 }
      }), 1);
      const manager = new FTRemoteConfigManager(
        FTSDKConfig.builder('http://datakit.local'),
        0,
        storage,
        null
      );
      manager.initFromLocalCache();
      const rum = new FTRUMConfig().setSessionSamplingRate(50);
      manager.mergeRUMConfigFromCache(rum);
      expect(rum.getSessionSamplingRate()).assertEqual(50);
    });

    it('syncTaskHotUpdateSupportedUploadValues', 0, () => {
      const syncTask = SyncTaskManager.getInstance();
      syncTask.init(FTSDKConfig.builder('http://datakit.local').setAutoSync(false));
      const bean = RemoteConfigBean.buildFromConfigJson(stringifyRemoteConfig({
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
