import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { UserData } from '../../../main/ets/components/rum/bean/UserData';
import { UserDataManager } from '../../../main/ets/components/rum/UserDataManager';

const PREFERENCES_NAME = 'ft_sdk_user_data';
const KEY_RANDOM_USER_ID = 'ft.user.session.id';
const KEY_USER_ID = 'ft.user.userid';
const KEY_USER_NAME = 'ft.user.username';
const KEY_USER_EMAIL = 'ft.user.email';
const KEY_USER_EXT = 'ft.user.extdata';

function getAppContext(): Context {
  return AbilityDelegatorRegistry.getAbilityDelegator().getAppContext() as Context;
}

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

    beforeEach(async () => {
      context = getAppContext();
      await clearUserDataPreferences(context);
      UserDataManager.getInstance().init(context);
      await delay(120);
    });

    afterEach(async () => {
      UserDataManager.getInstance().unbindUserData();
      await delay(120);
      await clearUserDataPreferences(context);
    });

    it('bindUserDataShouldPersistAllIdentityAndExtFieldsToPreferences', 0, async () => {
      const exts: Record<string, string> = {};
      exts['region'] = 'cn';
      exts['role'] = 'qa';
      const userData = new UserData('device-user-id', 'device-user-name', 'device@example.com', exts);

      UserDataManager.getInstance().bindUserData(userData);
      await delay(200);

      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const storedId = await store.get(KEY_USER_ID, '');
      const storedName = await store.get(KEY_USER_NAME, '');
      const storedEmail = await store.get(KEY_USER_EMAIL, '');
      const storedExt = await store.get(KEY_USER_EXT, '');

      expect(storedId).assertEqual('device-user-id');
      expect(storedName).assertEqual('device-user-name');
      expect(storedEmail).assertEqual('device@example.com');
      expect(String(storedExt).includes('"region":"cn"')).assertTrue();
      expect(String(storedExt).includes('"role":"qa"')).assertTrue();
    });

    it('unbindUserDataShouldClearPersistedIdentityFields', 0, async () => {
      UserDataManager.getInstance().bindUserData(new UserData('clear-id', 'clear-name', 'clear@example.com'));
      await delay(200);

      UserDataManager.getInstance().unbindUserData();
      await delay(200);

      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      expect(await store.get(KEY_USER_ID, '')).assertEqual('');
      expect(await store.get(KEY_USER_NAME, '')).assertEqual('');
      expect(await store.get(KEY_USER_EMAIL, '')).assertEqual('');
      expect(await store.get(KEY_USER_EXT, '')).assertEqual('');
      expect(UserDataManager.getInstance().getUserData() === null).assertTrue();
    });

    it('randomUserIdShouldBePersistedInPreferencesAfterInit', 0, async () => {
      const randomUserId = UserDataManager.getInstance().getRandomUserId();
      await delay(200);

      const store = preferences.getPreferencesSync(context, { name: PREFERENCES_NAME });
      const storedRandomUserId = await store.get(KEY_RANDOM_USER_ID, '');

      expect(randomUserId.startsWith('ft.rd_')).assertTrue();
      expect(storedRandomUserId).assertEqual(randomUserId);
    });
  });
}
