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
