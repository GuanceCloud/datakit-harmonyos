import { RemoteConfigBean } from './RemoteConfigBean';

/** Public callback contract for Android-compatible remote configuration. */
export interface FTRemoteConfigFetchResult {
  /**
   * Invoked after a valid changed response is parsed and before it is saved or
   * applied. Return null to keep the server result.
   */
  onConfigSuccessFetched?(configBean: RemoteConfigBean, jsonConfig: string): RemoteConfigBean | null;
  /** true means a successful fetch or an unchanged response. */
  onResult(success: boolean): void;
}

/** Synchronous storage seam used by the manager and unit tests. */
export interface RemoteConfigStorage {
  loadConfig(): string | null;
  loadFetchTime(): number;
  save(config: string, fetchTime: number): void;
  saveFetchTime(fetchTime: number): void;
}

/** HTTP seam used to verify the remote-configuration request without a backend. */
export interface RemoteConfigHttpClient {
  fetch(config: Object, appId: string): Promise<RemoteConfigHttpResponse>;
}

export interface RemoteConfigHttpResponse {
  code: number;
  body: string;
}

export type RemoteConfigClock = () => number;
export type RemoteConfigHash = (value: string) => string;
