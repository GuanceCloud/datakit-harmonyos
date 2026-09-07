import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { UserData } from '../../../main/ets/components/rum/bean/UserData';
import { FTRUMConfigManager } from '../../../main/ets/components/rum/FTRUMConfigManager';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { DBAssert } from './helpers/DBAssert';
import { RumAttributeAssert, RumAttributeExpectation } from './helpers/RumAttributeAssert';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

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

async function startViewAndWaitForStore(viewName: string): Promise<void> {
  await FTRUMGlobalManager.getInstance().startView(viewName);
  const view = await DBAssert.waitForViewNamed(viewName, 5000);
  expect(view !== null).assertTrue();
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
      await runTestCleanup([
        async () => { await collector.stop(); },
        () => { FTSDK.unbindRumUserData(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await DBAssert.cleanupAll(); },
        async () => { await clearUserDataPreferences(context); }
      ]);
    });

    it('bindUserShouldPersistFields', 0, async () => {
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

    it('boundUserShouldAppearInRum', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'cn';

      FTSDK.bindRumUserData(new UserData('line-user-id', 'line-user-name', 'line@example.com', exts));
      await startViewAndWaitForStore('user_data_view');
      FTRUMGlobalManager.getInstance().addAction('user_data_action', 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action,',
        'action_name=user_data_action',
        `${Constants.KEY_RUM_USER_ID}=line-user-id`,
        `${Constants.KEY_RUM_USER_NAME}=line-user-name`,
        `${Constants.KEY_RUM_USER_EMAIL}=line@example.com`,
        'region=cn'
      ], 8000);

      expect(record !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(record, attributes);

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
      RumAttributeAssert.uploaded(uploaded, record, attributes);
      expect(consumed).assertTrue();
    });

    it('boundUserShouldSurviveReset', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'restart-region';

      FTSDK.bindRumUserData(new UserData(
        'restart-user-id',
        'restart-user-name',
        'restart@example.com',
        exts
      ));
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const persisted = await WaitUtils.waitUntil(async () => {
        const storedId = String(await store.get(KEY_USER_ID, ''));
        const storedName = String(await store.get(KEY_USER_NAME, ''));
        const storedEmail = String(await store.get(KEY_USER_EMAIL, ''));
        const storedExt = String(await store.get(KEY_USER_EXT, ''));
        return storedId === 'restart-user-id' &&
          storedName === 'restart-user-name' &&
          storedEmail === 'restart@example.com' &&
          storedExt.includes('"region":"restart-region"');
      }, 5000);
      expect(persisted).assertTrue();

      collector.clearRequests();
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
      const restored = await WaitUtils.waitUntil(async () => {
        const tags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
        return tags[Constants.KEY_RUM_USER_ID] === 'restart-user-id' &&
          tags[Constants.KEY_RUM_USER_NAME] === 'restart-user-name' &&
          tags[Constants.KEY_RUM_USER_EMAIL] === 'restart@example.com' &&
          tags['region'] === 'restart-region';
      }, 5000);
      expect(restored).assertTrue();

      await startViewAndWaitForStore('restart_user_data_view');
      FTRUMGlobalManager.getInstance().addAction('restart_user_data_action', 'click');

      const fragments = [
        'action,',
        'action_name=restart_user_data_action',
        `${Constants.KEY_RUM_USER_ID}=restart-user-id`,
        `${Constants.KEY_RUM_USER_NAME}=restart-user-name`,
        `${Constants.KEY_RUM_USER_EMAIL}=restart@example.com`,
        'region=restart-region'
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 8000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('unbindUserShouldClearFields', 0, async () => {
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

    it('unbindUserShouldRemoveRumFields', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'unbind-region';

      FTSDK.bindRumUserData(new UserData(
        'unbind-user-id',
        'unbind-user-name',
        'unbind@example.com',
        exts
      ));
      await delay(200);
      FTSDK.unbindRumUserData();
      await delay(200);

      await startViewAndWaitForStore('unbind_user_data_view');
      FTRUMGlobalManager.getInstance().addAction('unbind_user_data_action', 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action',
        'action_name=unbind_user_data_action'
      ], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(record, attributes);
      expect(line.includes('unbind-user-id')).assertFalse();
      expect(line.includes('unbind-user-name')).assertFalse();
      expect(line.includes('unbind@example.com')).assertFalse();
      expect(line.includes('unbind-region')).assertFalse();
      expect(line.includes(`${Constants.KEY_RUM_USER_NAME}=`)).assertFalse();
      expect(line.includes(`${Constants.KEY_RUM_USER_EMAIL}=`)).assertFalse();
      expect(line.includes('region=')).assertFalse();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(['action_name=unbind_user_data_action'], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, record, attributes);
      expect(uploaded.includes('unbind-user-id')).assertFalse();
      expect(uploaded.includes('unbind-user-name')).assertFalse();
      expect(uploaded.includes('unbind@example.com')).assertFalse();
      expect(uploaded.includes('unbind-region')).assertFalse();
      expect(consumed).assertTrue();
    });

    it('randomUserShouldPersistAfterInstall', 0, async () => {
      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const storedRandomUserId = String(await store.get(KEY_RANDOM_USER_ID, ''));

      expect(storedRandomUserId.startsWith('ft.rd_')).assertTrue();
      expect(storedRandomUserId.length > 'ft.rd_'.length).assertTrue();
    });
  });
}
