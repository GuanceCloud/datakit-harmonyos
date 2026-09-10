import { Context } from '@kit.AbilityKit';

/** Serializable configuration. Only the owning Host sets it; every TaskPool request carries it. */
export interface FTCacheSettings {
  mode: string;
  limitEnabled: boolean;
  capacity: number;
  discard: string;
  migrate: boolean;
  directUpload: boolean;
}

/**
 * Android-compatible conflict resolution for the two FileStore switches.
 * Shadow intentionally wins when both are enabled: SQLite stays authoritative
 * while FileStore receives a verification mirror.
 */
export function resolveFTCacheMode(useFileDataStore: boolean, fileDataStoreShadow: boolean): string {
  if (fileDataStoreShadow) { return 'shadow'; }
  return useFileDataStore ? 'file' : 'sqlite';
}

/** SQLite remains the primary store while a FileStore shadow is enabled. */
export function isFTCacheSqlitePrimary(mode: string): boolean {
  return mode === 'sqlite' || mode === 'shadow';
}

export class FTCacheContext {
  static context: Context | null = null;
  static filesDir: string = '';
  static databaseDir: string = '';
  static lane: Promise<void> = Promise.resolve();
  static settings: FTCacheSettings = {
    mode: 'sqlite', limitEnabled: false, capacity: 100 * 1024 * 1024,
    discard: 'discard', migrate: false, directUpload: true
  };
}
