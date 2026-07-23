import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { Constants } from '../Constants';
import { RemoteConfigStorage } from './RemoteConfigTypes';
import { FTInnerLogger } from '../log/FTLogger';

const TAG = 'RemoteConfigStorage';
const PREFERENCES_NAME = 'ft_remote_config';

interface SyncPreferences {
  getSync(key: string, defValue: string | number): string | number;
  putSync(key: string, value: string | number): void;
  flush(): Promise<void>;
}

/** Persistent synchronous storage so cached configuration is available before SDK setup. */
export class PreferencesRemoteConfigStorage implements RemoteConfigStorage {
  private readonly preferences: SyncPreferences;

  public constructor(context: Context) {
    this.preferences = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME }) as SyncPreferences;
  }

  loadConfig(): string | null {
    const value = this.preferences.getSync(Constants.FT_REMOTE_CONFIG, '');
    return typeof value === 'string' && value.length > 0 ? value : null;
  }

  loadFetchTime(): number {
    const value = this.preferences.getSync(Constants.FT_REMOTE_CONFIG_FETCH_TIME, 0);
    return typeof value === 'number' && isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
  }

  save(config: string, fetchTime: number): void {
    this.preferences.putSync(Constants.FT_REMOTE_CONFIG, config);
    this.saveFetchTime(fetchTime);
  }

  saveFetchTime(fetchTime: number): void {
    this.preferences.putSync(Constants.FT_REMOTE_CONFIG_FETCH_TIME, Math.max(0, Math.floor(fetchTime)));
    void this.preferences.flush().catch((error: Error) => {
      FTInnerLogger.w(TAG, `Failed to flush remote config preferences: ${error.message}`);
    });
  }
}

/** Fallback used only when a Context is not available, such as isolated unit tests. */
export class MemoryRemoteConfigStorage implements RemoteConfigStorage {
  private config: string | null = null;
  private fetchTime: number = 0;

  loadConfig(): string | null { return this.config; }
  loadFetchTime(): number { return this.fetchTime; }
  save(config: string, fetchTime: number): void {
    this.config = config;
    this.fetchTime = fetchTime;
  }

  saveFetchTime(fetchTime: number): void {
    this.fetchTime = fetchTime;
  }
}

export function createRemoteConfigStorage(context: Context | null): RemoteConfigStorage {
  if (context === null) {
    return new MemoryRemoteConfigStorage();
  }
  try {
    return new PreferencesRemoteConfigStorage(context);
  } catch (error) {
    FTInnerLogger.w(TAG, `Failed to open remote config preferences: ${String(error)}`);
    return new MemoryRemoteConfigStorage();
  }
}
