import { Context } from '@kit.AbilityKit';
import { PreferencesRandomIdentityStorage, RandomIdentityStorage } from './RandomIdentityStorage';

export interface DeviceUUIDStorage extends RandomIdentityStorage {}

export type DeviceUUIDStorageFactory = (context: Context) => DeviceUUIDStorage;

function isRandomUUID(value: string): boolean {
  // Accept the older dashed representation without changing its identity.
  return /^ft\.rd_(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.test(value);
}

/**
 * A synchronous application-private copy closes the first-install flush window
 * on API 12, where Preferences.flushSync() is unavailable. Existing Preferences
 * UUIDs are migrated unchanged. Both copies are removed with application data.
 */
export class PreferencesDeviceUUIDStorage extends PreferencesRandomIdentityStorage implements DeviceUUIDStorage {
  constructor(context: Context, preferencesName: string = 'ftSDKDeviceFile',
    fileName: string = 'ft_sdk_device_uuid') {
    super(context, preferencesName, fileName, isRandomUUID);
  }
}
