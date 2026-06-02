import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { UserData } from '../../../main/ets/components/rum/bean/UserData';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { DBAssert } from './helpers/DBAssert';
import { MockCollector } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';

const PREFERENCES_NAME = 'ft_sdk_user_data';
const KEY_RANDOM_USER_ID = 'ft.user.session.id';
const KEY_USER_ID = 'ft.user.userid';
const KEY_USER_NAME = 'ft.user.username';
const KEY_USER_EMAIL = 'ft.user.email';
const KEY_USER_EXT = 'ft.user.extdata';
const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: Function) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

async function clearUserDataPreferences(context: Context): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
  await store.delete(KEY_RANDOM_USER_ID);
  await store.delete(KEY_USER_ID);
  await store.delete(KEY_USER_NAME);
  await store.delete(KEY_USER_EMAIL);
  await store.delete(KEY_USER_EXT);
  await store.flush();
}

export default function userDataManagerPersistenceTest() {
  describe('UserDataManagerPersistenceTest', () => {
    let context: Context;
    let collector: MockCollector;

    beforeEach(async () => {
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      await clearUserDataPreferences(context);
      collector = new MockCollector(200, '');
      collector.start();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      await DBAssert.resetAll();
      collector.clearRequests();
      await delay(120);
    });

    afterEach(async () => {
      collector.stop();
      FTSDK.unbindRumUserData();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
      await clearUserDataPreferences(context);
    });

    it('bindRumUserDataShouldPersistAllIdentityAndExtFieldsToPreferences', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'cn';
      exts['role'] = 'qa';

      FTSDK.bindRumUserData(new UserData('device-user-id', 'device-user-name', 'device@example.com', exts));
      await delay(200);

      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const storedExt = String(await store.get(KEY_USER_EXT, ''));

      expect(await store.get(KEY_USER_ID, '')).assertEqual('device-user-id');
      expect(await store.get(KEY_USER_NAME, '')).assertEqual('device-user-name');
      expect(await store.get(KEY_USER_EMAIL, '')).assertEqual('device@example.com');
      expect(storedExt.includes('"region":"cn"')).assertTrue();
      expect(storedExt.includes('"role":"qa"')).assertTrue();
    });

    it('boundUserDataShouldAppearInRumLineProtocolFromPublicApi', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'cn';

      FTSDK.bindRumUserData(new UserData('line-user-id', 'line-user-name', 'line@example.com', exts));
      await FTRUMGlobalManager.getInstance().startView('user_data_view');
      FTRUMGlobalManager.getInstance().addAction('user_data_action', 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        `${Constants.KEY_RUM_USER_ID}=line-user-id`,
        `${Constants.KEY_RUM_USER_NAME}=line-user-name`,
        `${Constants.KEY_RUM_USER_EMAIL}=line@example.com`,
        'region=cn'
      ], 5000);

      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        `${Constants.KEY_RUM_USER_ID}=line-user-id`,
        `${Constants.KEY_RUM_USER_NAME}=line-user-name`,
        `${Constants.KEY_RUM_USER_EMAIL}=line@example.com`,
        'region=cn'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('unbindRumUserDataShouldClearPersistedIdentityFields', 0, async () => {
      FTSDK.bindRumUserDataById('clear-id');
      await delay(200);

      FTSDK.unbindRumUserData();
      await delay(200);

      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      expect(await store.get(KEY_USER_ID, '')).assertEqual('');
      expect(await store.get(KEY_USER_NAME, '')).assertEqual('');
      expect(await store.get(KEY_USER_EMAIL, '')).assertEqual('');
      expect(await store.get(KEY_USER_EXT, '')).assertEqual('');
    });

    it('randomUserIdShouldBePersistedInPreferencesAfterInstall', 0, async () => {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const storedRandomUserId = String(await store.get(KEY_RANDOM_USER_ID, ''));

      expect(storedRandomUserId.startsWith('ft.rd_')).assertTrue();
      expect(storedRandomUserId.length > 'ft.rd_'.length).assertTrue();
    });
  });
}
