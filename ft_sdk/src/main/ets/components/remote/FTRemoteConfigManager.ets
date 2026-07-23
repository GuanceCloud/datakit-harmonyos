import { http } from '@kit.NetworkKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';
import { FTSDKConfig } from '../Configs';
import { Constants } from '../Constants';
import { HttpBuilder } from '../http/HttpBuilder';
import { FTInnerLogger } from '../log/FTLogger';
import { RemoteConfigBean } from './RemoteConfigBean';
import {
  FTRemoteConfigFetchResult,
  RemoteConfigClock,
  RemoteConfigHash,
  RemoteConfigHttpClient,
  RemoteConfigHttpResponse,
  RemoteConfigStorage
} from './RemoteConfigTypes';

export { FTRemoteConfigFetchResult } from './RemoteConfigTypes';

const TAG = 'FTRemoteConfigManager';

class DefaultRemoteConfigHttpClient implements RemoteConfigHttpClient {
  async fetch(config: Object, appId: string): Promise<RemoteConfigHttpResponse> {
    const headers: Map<string, string> = new Map();
    headers.set(Constants.SYNC_DATA_CONTENT_TYPE_HEADER, 'application/json');
    const response = await HttpBuilder.Builder(config as FTSDKConfig)
      .setModel(Constants.URL_ENV_VARIABLE)
      .addQueryParam(Constants.KEY_RUM_APP_ID, appId)
      .setHeadParams(headers)
      .setMethod(http.RequestMethod.GET)
      .executeSync();
    return {
      code: response.getCode(),
      body: response.getMessage()
    };
  }
}

function defaultClock(): number {
  return Math.floor(Date.now() / 1000);
}

function defaultMd5(value: string): string {
  const md = cryptoFramework.createMd('MD5');
  const encoder = util.TextEncoder.create('utf-8');
  md.updateSync({ data: encoder.encodeInto(value) });
  const digest = md.digestSync().data;
  let result = '';
  for (let index = 0; index < digest.length; index++) {
    result += digest[index].toString(16).padStart(2, '0');
  }
  return result;
}

/**
 * Fetches, persists and de-duplicates Android-compatible SDK remote
 * configuration. Configuration-specific merge and hot-update work is kept in
 * FTSDK so this manager remains transport and persistence focused.
 */
export class FTRemoteConfigManager {
  private readonly sdkConfig: FTSDKConfig;
  private readonly remoteConfigMiniUpdateInterval: number;
  private readonly storage: RemoteConfigStorage;
  private readonly httpClient: RemoteConfigHttpClient;
  private readonly clock: RemoteConfigClock;
  private readonly hash: RemoteConfigHash;
  private readonly fetchResult: FTRemoteConfigFetchResult | null;
  private appId: string = '';
  private lastUpdateTime: number = 0;
  private remoteConfig: RemoteConfigBean | null = null;
  private running: boolean = false;
  private closed: boolean = false;
  private onConfigApplied: ((bean: RemoteConfigBean) => void) | null = null;

  public constructor(
    sdkConfig: FTSDKConfig,
    remoteConfigMiniUpdateInterval: number,
    storage: RemoteConfigStorage,
    fetchResult: FTRemoteConfigFetchResult | null,
    httpClient: RemoteConfigHttpClient = new DefaultRemoteConfigHttpClient(),
    clock: RemoteConfigClock = defaultClock,
    hash: RemoteConfigHash = defaultMd5
  ) {
    this.sdkConfig = sdkConfig;
    this.remoteConfigMiniUpdateInterval = Math.max(0, Math.floor(remoteConfigMiniUpdateInterval));
    this.storage = storage;
    this.fetchResult = fetchResult;
    this.httpClient = httpClient;
    this.clock = clock;
    this.hash = hash;
  }

  public initFromLocalCache(): void {
    const cached = this.storage.loadConfig();
    if (cached !== null) {
      const bean = RemoteConfigBean.buildFromConfigJson(cached);
      if (bean.isValid()) {
        this.remoteConfig = bean;
      }
    }
    this.lastUpdateTime = this.storage.loadFetchTime();
  }

  public initFromRemote(appId: string): Promise<void> {
    this.appId = appId;
    return this.updateRemoteConfig();
  }

  public setConfigAppliedListener(listener: ((bean: RemoteConfigBean) => void) | null): void {
    this.onConfigApplied = listener;
  }

  public getCachedConfig(): RemoteConfigBean | null {
    return this.remoteConfig;
  }

  /** Apply persisted base-SDK values before dependent managers are initialized. */
  public mergeSDKConfigFromCache(config: FTSDKConfig): void {
    const bean = this.remoteConfig;
    if (bean === null) {
      return;
    }
    if (bean.getAutoSync() !== null) {
      config.setAutoSync(bean.getAutoSync()!);
    }
    if (bean.getEnv() !== null) {
      config.setEnv(bean.getEnv()!);
    }
    if (bean.getServiceName() !== null) {
      config.setServiceName(bean.getServiceName()!);
    }
    if (bean.getCompressIntakeRequests() !== null) {
      config.setCompressIntakeRequests(bean.getCompressIntakeRequests()!);
    }
    if (bean.getSyncPageSize() !== null) {
      config.setCustomSyncPageSize(bean.getSyncPageSize()!);
    }
    if (bean.getSyncSleepTime() !== null) {
      config.setSyncSleepTime(bean.getSyncSleepTime()!);
    }
  }

  public async updateRemoteConfig(
    intervalSeconds: number = this.remoteConfigMiniUpdateInterval,
    result: FTRemoteConfigFetchResult | null = null
  ): Promise<void> {
    if (this.closed || this.running) {
      return;
    }
    if (this.appId.length === 0) {
      this.notifyResult(result, false);
      return;
    }
    const minimumInterval = Math.max(0, Math.floor(intervalSeconds));
    const now = this.clock();
    if (now - this.lastUpdateTime < minimumInterval) {
      this.notifyResult(result, false);
      return;
    }
    this.running = true;
    try {
      const response = await this.httpClient.fetch(this.sdkConfig, this.appId);
      if (response.code !== http.ResponseCode.OK || response.body.length === 0) {
        this.notifyResult(result, false);
        return;
      }
      const responseHash = this.hash(response.body);
      if (this.remoteConfig !== null && this.remoteConfig.getMd5() === responseHash) {
        this.saveFetchTime(now);
        this.notifyResult(result, true);
        return;
      }
      // Android removes resource-expression prefixes before parsing the cached payload.
      const normalized = response.body.replace(/R\.[^.]+\./g, '');
      let bean = RemoteConfigBean.buildFromConfigJson(normalized, responseHash);
      if (!bean.isValid()) {
        this.saveFetchTime(now);
        this.notifyResult(result, false);
        return;
      }
      const callback = result === null ? this.fetchResult : result;
      if (callback !== null && callback.onConfigSuccessFetched !== undefined) {
        const overridden = callback.onConfigSuccessFetched(bean, bean.getContentJsonString());
        if (overridden !== null) {
          bean = overridden;
        }
      }
      const serialized = bean.toJsonString();
      if (serialized.length === 0) {
        this.saveFetchTime(now);
        this.notifyResult(result, false);
        return;
      }
      this.storage.save(serialized, now);
      this.lastUpdateTime = now;
      this.remoteConfig = bean;
      if (this.onConfigApplied !== null) {
        this.onConfigApplied(bean);
      }
      this.notifyResult(result, true);
    } catch (error) {
      FTInnerLogger.e(TAG, `Remote config load error: ${String(error)}`);
      this.notifyResult(result, false);
    } finally {
      this.running = false;
    }
  }

  public close(): void {
    this.closed = true;
    this.onConfigApplied = null;
  }

  private saveFetchTime(fetchTime: number): void {
    this.storage.saveFetchTime(fetchTime);
    this.lastUpdateTime = fetchTime;
  }

  private notifyResult(result: FTRemoteConfigFetchResult | null, success: boolean): void {
    const callback = result === null ? this.fetchResult : result;
    if (callback !== null) {
      callback.onResult(success);
    }
  }
}
