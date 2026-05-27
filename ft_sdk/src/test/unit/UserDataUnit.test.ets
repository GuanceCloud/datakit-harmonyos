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

    it('userDataValidityShouldFollowIdentityFieldsOnly', 0, () => {
      expect(new UserData('id-1').isValid()).assertTrue();
      expect(new UserData('', 'name-1').isValid()).assertTrue();
      expect(new UserData('', '', 'user@example.com').isValid()).assertTrue();

      const extOnly = new UserData();
      extOnly.addExt('role', 'admin');

      expect(extOnly.isValid()).assertFalse();
      expect(extOnly.isSignedIn()).assertFalse();
    });

    it('userDataExtsShouldOverwriteRemoveAndDefaultMissingValues', 0, () => {
      const user = new UserData('id-1');

      user.addExt('role', 'admin');
      user.addExt('role', 'owner');
      user.addExt('region', 'cn');
      user.removeExt('missing');

      expect(user.getExt('role')).assertEqual('owner');
      expect(user.getExt('missing')).assertEqual('');
      expect(Object.keys(user.getExts()).length).assertEqual(2);

      user.removeExt('role');
      expect(user.getExt('role')).assertEqual('');
      expect(Object.keys(user.getExts()).length).assertEqual(1);
      expect(user.getExt('region')).assertEqual('cn');
    });

    it('userDataShouldTreatExtOnlyAsInvalidAndClearAllFields', 0, () => {
      const user = new UserData();
      user.addExt('role', 'admin');

      expect(user.isValid()).assertFalse();
      expect(user.isSignedIn()).assertFalse();
      expect(user.getExt('role')).assertEqual('admin');

      user.setId('id-1');
      user.setName('name-1');
      user.setEmail('user@example.com');
      expect(user.isValid()).assertTrue();

      user.clear();
      expect(user.getId()).assertEqual('');
      expect(user.getName()).assertEqual('');
      expect(user.getEmail()).assertEqual('');
      expect(Object.keys(user.getExts()).length).assertEqual(0);
      expect(user.isValid()).assertFalse();
    });

    it('userDataShouldHandleInvalidAndEmptyExtsJson', 0, () => {
      const user = new UserData('id-1');

      user.setExtsWithJsonString('{"region":"cn","empty":""}');
      expect(Object.keys(user.getExts()).length).assertEqual(2);
      expect(user.getExt('region')).assertEqual('cn');
      expect(user.getExt('empty')).assertEqual('');

      user.setExtsWithJsonString('{bad json');
      expect(Object.keys(user.getExts()).length).assertEqual(0);
      expect(user.getExtsJsonString()).assertEqual('{}');

      user.addExt('region', 'cn');
      user.setExtsWithJsonString('');
      expect(Object.keys(user.getExts()).length).assertEqual(0);
    });

    it('userDataShouldCompareNullAndMissingExtRemovalSafely', 0, () => {
      const user = new UserData('id-1', 'name-1', 'user@example.com', createRegionExts());
      const clone = user.clone();

      user.removeExt('missing');
      expect(user.equals(null)).assertFalse();
      expect(user.equals(clone)).assertTrue();

      clone.removeExt('region');
      expect(user.equals(clone)).assertFalse();
    });

    it('userDataShouldCloneDeeplyAndCompareExtsWithoutOrderSensitivity', 0, () => {
      const firstExts: Record<string, string> = {};
      firstExts['role'] = 'admin';
      firstExts['region'] = 'cn';
      const secondExts: Record<string, string> = {};
      secondExts['region'] = 'cn';
      secondExts['role'] = 'admin';
      const user = new UserData('id-1', 'name-1', 'user@example.com', firstExts);
      const sameUser = new UserData('id-1', 'name-1', 'user@example.com', secondExts);
      const clone = user.clone();

      expect(user.equals(sameUser)).assertTrue();
      expect(user.equals(clone)).assertTrue();

      clone.addExt('role', 'viewer');
      clone.addExt('plan', 'pro');

      expect(user.getExt('role')).assertEqual('admin');
      expect(user.getExt('plan')).assertEqual('');
      expect(user.equals(clone)).assertFalse();
    });

    it('userDataShouldBuildSummaryAndString', 0, () => {
      const user = new UserData('id-1', 'name-1', 'user@example.com', createRegionExts());
      const summary = user.getSummary();
      const value = user.toString();

      expect(summary.includes('id=id-1')).assertTrue();
      expect(summary.includes('name=name-1')).assertTrue();
      expect(summary.includes('email=user@example.com')).assertTrue();
      expect(summary.includes('exts=1 items')).assertTrue();
      expect(value.includes("UserData{id='id-1'")).assertTrue();
      expect(value.includes('"region":"cn"')).assertTrue();
    });

    it('userDataManagerShouldKeepMemoryStateWithoutPreferences', 0, () => {
      const manager = UserDataManager.getInstance();
      const user = new UserData('id-1', 'name-1', 'user@example.com', createFullExts());

      manager.bindUserData(user);

      const current = manager.getUserData();
      expect(current !== null).assertTrue();
      if (current !== null) {
        expect(current.getId()).assertEqual('id-1');
        expect(current.getName()).assertEqual('name-1');
        expect(current.getEmail()).assertEqual('user@example.com');
        expect(current.getExt('role')).assertEqual('admin');
      }
      expect(manager.isUserDataBound()).assertTrue();

      manager.bindUserData(new UserData('', 'name-only'));
      const nameOnly = manager.getUserData();
      expect(nameOnly !== null).assertTrue();
      if (nameOnly !== null) {
        expect(nameOnly.getName()).assertEqual('name-only');
      }
      expect(manager.isUserDataBound()).assertFalse();

      manager.unbindUserData();
      expect(manager.getUserData() === null).assertTrue();
      expect(manager.isUserDataBound()).assertFalse();
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
