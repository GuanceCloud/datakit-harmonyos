import { FTSDKConfig } from '../Configs';

/** HTTP seam used to test remote data-filter refreshes without a backend. */
export interface RemoteDataFilterHttpClient {
  fetch(config: FTSDKConfig): Promise<RemoteDataFilterHttpResponse>;
}

export interface RemoteDataFilterHttpResponse {
  code: number;
  body: string;
}

/** Digest seam used to avoid re-parsing an unchanged remote filter payload. */
export type RemoteDataFilterHash = (value: string) => string;

/** Clock seam used to test pull_interval checks deterministically. */
export type RemoteDataFilterClock = () => number;
