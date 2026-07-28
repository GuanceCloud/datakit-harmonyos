import { FTSDKConfig } from '../Configs';

/** HTTP seam used to test remote data-filter refreshes without a backend. */
export interface RemoteDataFilterHttpClient {
  fetch(config: FTSDKConfig): Promise<RemoteDataFilterHttpResponse>;
}

export interface RemoteDataFilterHttpResponse {
  code: number;
  body: string;
}

/** Timer seam that keeps periodic refresh behavior deterministic in unit tests. */
export interface RemoteDataFilterScheduler {
  schedule(delayMs: number, callback: () => void): number;
  cancel(timerId: number): void;
}
