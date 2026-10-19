import { afterEach, beforeEach, describe, expect, it } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import preferences from '@ohos.data.preferences';
import deviceInfo from '@ohos.deviceInfo';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DeviceUUIDManager } from '../../../main/ets/components/utils/DeviceUUIDManager';
import { DeviceUUIDStorage, PreferencesDeviceUUIDStorage } from '../../../main/ets/components/utils/DeviceUUIDStorage';
import { DBAssert } from './helpers/DBAssert';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';

const PREFERENCES_NAME = 'ft_sdk_device_uuid_test';
const FILE_NAME = 'ft_sdk_device_uuid_test';
const STORED_UUID = 'ft.rd_0123456789abcdef0123456789abcdef';

export default function deviceUUIDPersistenceTest() {
  describe('DeviceUUIDPersistenceTest', (): void => {
    let context: Context;

    function configureStorage(): void {
      DeviceUUIDManager.setStorageFactoryInternal((value: Context): DeviceUUIDStorage =>
        new PreferencesDeviceUUIDStorage(value, PREFERENCES_NAME, FILE_NAME));
    }

    async function clearStorage(): Promise<void> {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      await store.delete(Constants.FT_RANDOM_USER_ID);
      await store.flush();
      for (const suffix of ['', '.tmp']) {
        const path = `${context.filesDir}/${FILE_NAME}${suffix}`;
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (error) {
          if ((error as BusinessError).code !== 13900002) {
            throw new Error(`Failed to clean device UUID test file: ${error}`);
          }
        }
      }
    }

    beforeEach(async (): Promise<void> => {
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      await clearStorage();
      configureStorage();
    });

    afterEach(async (): Promise<void> => {
      await DeviceUUIDManager.getInstance().waitForPersistenceInternal();
      await SdkTestLifecycle.resetRuntimeState();
      await clearStorage();
    });

    it('firstSDKTagsUseTheLegacyPreferencesUUIDAndMigrateItUnchanged', 0, async (): Promise<void> => {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      store.putSync(Constants.FT_RANDOM_USER_ID, STORED_UUID);
      await store.flush();
      const config = FTSDKConfig.builder().setAutoSync(false).setEnableAccessDeviceID(false);
      FTSDK.install(config, context);
      expect(String(config.getGlobalContext().get(Constants.KEY_DEVICE_UUID))).assertEqual(STORED_UUID);
      expect(fs.readTextSync(`${context.filesDir}/${FILE_NAME}`)).assertEqual(STORED_UUID);
    });

    it('newUUIDIsDurableBeforePreferencesFlushAndRestoredAfterReset', 0, (): void => {
      const first = FTSDKConfig.builder().setAutoSync(false).setEnableAccessDeviceID(false);
      FTSDK.install(first, context);
      const uuid = String(first.getGlobalContext().get(Constants.KEY_DEVICE_UUID));
      expect(/^ft\.rd_[0-9a-f]{32}$/.test(uuid)).assertTrue();
      expect(fs.readTextSync(`${context.filesDir}/${FILE_NAME}`)).assertEqual(uuid);
      configureStorage();
      const next = FTSDKConfig.builder().setAutoSync(false).setEnableAccessDeviceID(false);
      FTSDK.install(next, context);
      expect(String(next.getGlobalContext().get(Constants.KEY_DEVICE_UUID))).assertEqual(uuid);
    });

    it('runtimeSwitchesKeepTheSamePrivacyUUIDAndDoNotOverwriteTheSystemIDLater', 0,
      async (): Promise<void> => {
        const config = FTSDKConfig.builder().setAutoSync(false).setEnableAccessDeviceID(false);
        FTSDK.install(config, context);
        const privacyUUID = String(config.getGlobalContext().get(Constants.KEY_DEVICE_UUID));
        FTSDK.setEnableAccessDeviceID(true);
        const systemUUID = String(config.getGlobalContext().get(Constants.KEY_DEVICE_UUID));
        let odid = '';
        try {
          odid = deviceInfo.ODID;
        } catch (_error) {
          // Some device-test environments cannot expose system identifiers.
        }
        if (odid.length > 0) {
          expect(systemUUID).assertEqual(odid);
        }
        await DeviceUUIDManager.getInstance().waitForPersistenceInternal();
        expect(String(config.getGlobalContext().get(Constants.KEY_DEVICE_UUID))).assertEqual(systemUUID);
        FTSDK.setEnableAccessDeviceID(false);
        expect(String(config.getGlobalContext().get(Constants.KEY_DEVICE_UUID))).assertEqual(privacyUUID);
      });

    it('invalidPreferenceValuesAreNotUsedAsDeviceUUIDs', 0, (): void => {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      store.putSync(Constants.FT_RANDOM_USER_ID, 123);
      const manager = DeviceUUIDManager.getInstance();
      manager.init(context);
      expect(/^ft\.rd_[0-9a-f]{32}$/.test(manager.getDeviceUUID(false))).assertTrue();
    });

    it('removingApplicationIdentityDataProducesANewUUIDAfterReset', 0, async (): Promise<void> => {
      const manager = DeviceUUIDManager.getInstance();
      manager.init(context);
      const previousUUID = manager.getDeviceUUID(false);
      await manager.waitForPersistenceInternal();
      await clearStorage();
      configureStorage();
      const restarted = DeviceUUIDManager.getInstance();
      restarted.init(context);
      expect(restarted.getDeviceUUID(false) !== previousUUID).assertTrue();
    });
  });
}
