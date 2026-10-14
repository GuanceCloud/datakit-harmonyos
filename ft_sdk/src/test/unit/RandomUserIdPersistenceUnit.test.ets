import { afterEach, describe, expect, it } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { UserDataManager } from '../../main/ets/components/rum/UserDataManager';
import { UserData } from '../../main/ets/components/rum/bean/UserData';
import { RandomIdentityStorage } from '../../main/ets/components/utils/RandomIdentityStorage';
import { FTRUMConfigManager } from '../../main/ets/components/rum/FTRUMConfigManager';
import { Constants } from '../../main/ets/components/Constants';

const STORED_USER_ID = 'ft.rd_legacy-anonymous-user';

class TestRandomUserIdStorage implements RandomIdentityStorage {
  public value: string = '';
  public readFailures: number = 0;
  public fileFailures: number = 0;
  public preferenceFailures: number = 0;
  public reads: number = 0;
  public savedIds: string[] = [];
  public preferenceIds: string[] = [];

  load(): string {
    this.reads++;
    if (this.readFailures-- > 0) {
      throw new Error('Temporary anonymous user ID read failure');
    }
    return this.value;
  }

  save(value: string): void {
    this.savedIds.push(value);
    if (this.fileFailures-- > 0) {
      throw new Error('Temporary anonymous user ID file write failure');
    }
    this.value = value;
  }

  async flushPreferences(value: string): Promise<void> {
    this.preferenceIds.push(value);
    if (this.preferenceFailures-- > 0) {
      throw new Error('Temporary anonymous user ID Preferences failure');
    }
  }
}

function installStorage(storage: TestRandomUserIdStorage): UserDataManager {
  UserDataManager.setRandomIdentityStorageFactoryInternal((_context: Context): RandomIdentityStorage => storage);
  const manager = UserDataManager.getInstance();
  manager.init({} as Context);
  return manager;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

export default function randomUserIdPersistenceUnitTest() {
  describe('RandomUserIdPersistenceUnitTest', (): void => {
    afterEach((): void => { UserDataManager.resetStateInternal(); });

    it('preservesTheExistingAnonymousIDWithoutChangingItsFormat', 0, async (): Promise<void> => {
      const storage = new TestRandomUserIdStorage();
      storage.value = STORED_USER_ID;
      const manager = installStorage(storage);
      expect(manager.getRandomUserId()).assertEqual(STORED_USER_ID);
      await manager.waitForRandomIdentityPersistenceInternal();
      expect(manager.getRandomUserId()).assertEqual(STORED_USER_ID);
      expect(storage.reads).assertEqual(1);
    });

    it('readFailureCannotWriteATemporaryIDOverTheSavedValue', 0, (): void => {
      const storage = new TestRandomUserIdStorage();
      storage.value = STORED_USER_ID;
      storage.readFailures = 2;
      const manager = installStorage(storage);
      expect(manager.getRandomUserId()).assertEqual('');
      expect(storage.value).assertEqual(STORED_USER_ID);
      expect(storage.savedIds.length).assertEqual(0);
      expect(storage.preferenceIds.length).assertEqual(0);
      expect(manager.getRandomUserId()).assertEqual(STORED_USER_ID);
      expect(storage.reads).assertEqual(3);
    });

    it('failedReadsRecoverAutomaticallyWithTheOriginalID', 0, async (): Promise<void> => {
      const storage = new TestRandomUserIdStorage();
      storage.value = STORED_USER_ID;
      storage.readFailures = 2;
      const manager = installStorage(storage);
      expect(manager.getRandomUserId()).assertEqual('');
      expect(storage.savedIds.length).assertEqual(0);
      await delay(350);
      expect(manager.getRandomUserId()).assertEqual(STORED_USER_ID);
    });

    it('rumContinuesWithoutAnAnonymousTagUntilTheOriginalIDIsReadable', 0, (): void => {
      const storage = new TestRandomUserIdStorage();
      storage.value = STORED_USER_ID;
      storage.readFailures = 2;
      installStorage(storage);
      const beforeRecovery = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      expect(beforeRecovery[Constants.KEY_RUM_USER_ID] === undefined).assertTrue();
      expect(beforeRecovery[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('F');
      expect(beforeRecovery[Constants.KEY_RUM_NETWORK_TYPE] !== undefined).assertTrue();
      expect(storage.savedIds.length).assertEqual(0);
      const afterRecovery = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      expect(afterRecovery[Constants.KEY_RUM_USER_ID]).assertEqual(STORED_USER_ID);
      expect(beforeRecovery[Constants.KEY_RUM_USER_ID] === undefined).assertTrue();
    });

    it('boundUserTagsRemainAvailableWhenAnonymousStorageCannotBeRead', 0, (): void => {
      const storage = new TestRandomUserIdStorage();
      storage.readFailures = 100;
      const manager = installStorage(storage);
      manager.bindUserData(new UserData('signed-in-user'));
      const signedIn = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      expect(signedIn[Constants.KEY_RUM_USER_ID]).assertEqual('signed-in-user');
      manager.unbindUserData();
      const signedOut = FTRUMConfigManager.getInstance().getRUMPublicDynamicTags();
      expect(signedOut[Constants.KEY_RUM_USER_ID] === undefined).assertTrue();
      expect(signedOut[Constants.KEY_RUM_IS_SIGN_IN]).assertEqual('F');
      expect(storage.savedIds.length).assertEqual(0);
    });

    it('doesNotGenerateBeforeStorageInitialization', 0, (): void => {
      expect(UserDataManager.getInstance().getRandomUserId()).assertEqual('');
    });

    it('firstIDIsDurableAndSurvivesResetWhenPreferencesFlushFails', 0, async (): Promise<void> => {
      const storage = new TestRandomUserIdStorage();
      storage.preferenceFailures = 1;
      const first = installStorage(storage);
      const userId = first.getRandomUserId();
      expect(/^ft\.rd_[0-9a-f]{32}$/.test(userId)).assertTrue();
      expect(storage.value).assertEqual(userId);
      await first.waitForRandomIdentityPersistenceInternal();
      const restarted = installStorage(storage);
      expect(restarted.getRandomUserId()).assertEqual(userId);
    });

    it('failedFileAndPreferencesWritesRetryTheSameID', 0, async (): Promise<void> => {
      const storage = new TestRandomUserIdStorage();
      storage.fileFailures = 1;
      storage.preferenceFailures = 1;
      const manager = installStorage(storage);
      const userId = manager.getRandomUserId();
      await manager.waitForRandomIdentityPersistenceInternal();
      await delay(350);
      await manager.waitForRandomIdentityPersistenceInternal();
      expect(storage.value).assertEqual(userId);
      expect(storage.savedIds.length).assertEqual(2);
      expect(storage.savedIds[0]).assertEqual(storage.savedIds[1]);
      expect(storage.preferenceIds.length).assertEqual(2);
      expect(storage.preferenceIds[0]).assertEqual(storage.preferenceIds[1]);
    });

    it('bindingAndUnbindingKeepTheOriginalAnonymousID', 0, (): void => {
      const storage = new TestRandomUserIdStorage();
      storage.value = STORED_USER_ID;
      const manager = installStorage(storage);
      manager.bindUserData(new UserData('signed-in-user'));
      expect(manager.getUserData()?.getId()).assertEqual('signed-in-user');
      manager.unbindUserData();
      expect(manager.getUserData() === null).assertTrue();
      expect(manager.getRandomUserId()).assertEqual(STORED_USER_ID);
    });

    it('resetCancelsReadAndWriteRetriesFromThePreviousInstance', 0, async (): Promise<void> => {
      const readStorage = new TestRandomUserIdStorage();
      readStorage.readFailures = 10;
      installStorage(readStorage);
      UserDataManager.resetStateInternal();
      const writeStorage = new TestRandomUserIdStorage();
      writeStorage.preferenceFailures = 10;
      const manager = installStorage(writeStorage);
      manager.getRandomUserId();
      await manager.waitForRandomIdentityPersistenceInternal();
      UserDataManager.resetStateInternal();
      await delay(350);
      expect(readStorage.reads).assertEqual(1);
      expect(writeStorage.preferenceIds.length).assertEqual(1);
    });

    it('automaticWriteRetriesAreBoundedAndNeverRegenerateTheID', 0, async (): Promise<void> => {
      const storage = new TestRandomUserIdStorage();
      storage.preferenceFailures = 100;
      const manager = installStorage(storage);
      const userId = manager.getRandomUserId();
      await delay(2100);
      await manager.waitForRandomIdentityPersistenceInternal();
      expect(storage.preferenceIds.length).assertEqual(4);
      for (const attemptedId of storage.preferenceIds) {
        expect(attemptedId).assertEqual(userId);
      }
      expect(storage.value).assertEqual(userId);
    });
  });
}
