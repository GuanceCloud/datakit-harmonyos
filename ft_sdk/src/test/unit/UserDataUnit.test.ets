import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { UserData } from '../../main/ets/components/rum/bean/UserData';
import { UserDataManager } from '../../main/ets/components/rum/UserDataManager';

function createRegionExts(): Record<string, string> {
  const exts: Record<string, string> = {};
  exts['region'] = 'cn';
  return exts;
}

function createFullExts(): Record<string, string> {
  const exts: Record<string, string> = {};
  exts['region'] = 'cn';
  exts['role'] = 'admin';
  return exts;
}

function resetUserDataState(): void {
  UserDataManager.getInstance().unbindUserData();
}

function expectRandomUserId(userId: string): void {
  expect(userId.startsWith('ft.rd_')).assertTrue();
  expect(userId.length > 'ft.rd_'.length).assertTrue();
}

export default function userDataUnitTest() {
  describe('UserDataUnit', () => {
    beforeEach(() => {
      resetUserDataState();
    });

    afterEach(() => {
      resetUserDataState();
    });

    it('rumDynamicTagsShouldUseRandomUserForUnsignedState', 0, () => {
      const tags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();

      expect(tags[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('F');
      expectRandomUserId(tags[Constants.KEY_RUM_USER_ID]);
      expect(tags[Constants.KEY_RUM_NETWORK_TYPE] !== undefined).assertTrue();
      expect(tags[Constants.KEY_RUM_NETWORK_TYPE].length > 0).assertTrue();
    });

    it('rumDynamicTagsShouldIncludeBoundUserDataAndExts', 0, () => {
      UserDataManager.getInstance().bindUserData(
        new UserData('id-1', 'name-1', 'user@example.com', createFullExts())
      );

      const tags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();

      expect(tags[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('T');
      expect(tags[Constants.KEY_RUM_USER_ID]).assertEqual('id-1');
      expect(tags[Constants.KEY_RUM_USER_NAME]).assertEqual('name-1');
      expect(tags[Constants.KEY_RUM_USER_EMAIL]).assertEqual('user@example.com');
      expect(tags['region']).assertEqual('cn');
      expect(tags['role']).assertEqual('admin');
    });

    it('rumDynamicTagsShouldFallbackToRandomIdWhenBoundUserHasNoId', 0, () => {
      UserDataManager.getInstance().bindUserData(
        new UserData('', 'name-1', 'user@example.com', createRegionExts())
      );

      const tags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();

      expect(tags[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('T');
      expectRandomUserId(tags[Constants.KEY_RUM_USER_ID]);
      expect(tags[Constants.KEY_RUM_USER_NAME]).assertEqual('name-1');
      expect(tags[Constants.KEY_RUM_USER_EMAIL]).assertEqual('user@example.com');
      expect(tags['region']).assertEqual('cn');
    });

    it('rumDynamicTagsShouldNotAllowExtsToOverrideReservedUserKeys', 0, () => {
      const exts: Record<string, string> = {};
      exts[Constants.KEY_RUM_USER_ID] = 'ext-id';
      exts[Constants.KEY_RUM_USER_NAME] = 'ext-name';
      exts[Constants.KEY_RUM_USER_EMAIL] = 'ext@example.com';
      exts['plan'] = 'pro';

      UserDataManager.getInstance().bindUserData(
        new UserData('id-1', 'name-1', 'user@example.com', exts)
      );

      const tags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();

      expect(tags[Constants.KEY_RUM_USER_ID]).assertEqual('id-1');
      expect(tags[Constants.KEY_RUM_USER_NAME]).assertEqual('name-1');
      expect(tags[Constants.KEY_RUM_USER_EMAIL]).assertEqual('user@example.com');
      expect(tags['plan']).assertEqual('pro');
    });

    it('rumDynamicTagsShouldRecoverUnsignedStateAfterUnbind', 0, () => {
      const manager = UserDataManager.getInstance();
      manager.bindUserData(new UserData('id-1', 'name-1', 'user@example.com', createRegionExts()));

      const signedTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      expect(signedTags[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('T');

      manager.unbindUserData();
      const unsignedTags = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();

      expect(unsignedTags[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('F');
      expectRandomUserId(unsignedTags[Constants.KEY_RUM_USER_ID]);
      expect(unsignedTags[Constants.KEY_RUM_USER_NAME] === undefined).assertTrue();
      expect(unsignedTags['region'] === undefined).assertTrue();
    });
  });
}
