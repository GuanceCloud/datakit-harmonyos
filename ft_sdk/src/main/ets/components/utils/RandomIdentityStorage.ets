import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import preferences from '@ohos.data.preferences';
import { Constants } from '../Constants';

export interface RandomIdentityStorage {
  load(): string;
  save(value: string): void;
  flushPreferences(value: string): Promise<void>;
}

export type RandomIdentityStorageFactory = (context: Context) => RandomIdentityStorage;
export type RandomIdentityValidator = (value: string) => boolean;

/** API 12-compatible durable storage, migrated from each identity's own Preferences. */
export class PreferencesRandomIdentityStorage implements RandomIdentityStorage {
  private readonly context: Context;
  private readonly preferencesName: string;
  private readonly path: string;
  private readonly validate: RandomIdentityValidator;
  private store: preferences.Preferences | null = null;
  private durableValue: string = '';

  constructor(context: Context, preferencesName: string, fileName: string,
    validate: RandomIdentityValidator) {
    this.context = context;
    this.preferencesName = preferencesName;
    this.path = `${context.filesDir}/${fileName}`;
    this.validate = validate;
  }

  load(): string {
    // The file is authoritative even when the previous process stopped before
    // its asynchronous Preferences flush. An I/O fault must not select a stale copy.
    try {
      if (fs.accessSync(this.path)) {
        const value = fs.readTextSync(this.path);
        if (this.validate(value)) {
          this.durableValue = value;
          return value;
        }
      }
    } catch (error) {
      if ((error as BusinessError).code !== 13900002) {
        throw new Error(`Failed to read random identity file: ${error}`);
      }
    }
    const value = this.getStore().getSync(Constants.FT_RANDOM_USER_ID, '');
    return typeof value === 'string' && this.validate(value) ? value : '';
  }

  save(value: string): void {
    if (this.durableValue === value) {
      return;
    }
    const temp = `${this.path}.tmp`;
    const bytes = util.TextEncoder.create('utf-8').encodeInto(value);
    if (bytes.length === 0) {
      throw new Error('Failed to encode random identity');
    }
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < bytes.length) {
        const count = fs.writeSync(file.fd, bytes.slice(written).buffer as ArrayBuffer);
        if (count <= 0) {
          throw new Error('Failed to write complete random identity');
        }
        written += count;
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, this.path);
    const directory = fs.openSync(this.context.filesDir, fs.OpenMode.READ_ONLY);
    try {
      fs.fsyncSync(directory.fd);
    } finally {
      fs.closeSync(directory);
    }
    this.durableValue = value;
  }

  async flushPreferences(value: string): Promise<void> {
    try {
      const store = this.getStore();
      store.putSync(Constants.FT_RANDOM_USER_ID, value);
      await store.flush();
    } catch (error) {
      this.store = null;
      throw new Error(`Failed to flush random identity Preferences: ${error}`);
    }
  }

  private getStore(): preferences.Preferences {
    if (this.store === null) {
      this.store = preferences.getPreferencesSync(this.context, { name: this.preferencesName });
    }
    return this.store;
  }
}
