import { afterEach, describe, expect, it } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { DeviceUUIDManager } from '../../main/ets/components/utils/DeviceUUIDManager';
import { DeviceUUIDStorage } from '../../main/ets/components/utils/DeviceUUIDStorage';

const STORED_UUID = 'ft.rd_0123456789abcdef0123456789abcdef';

class TestDeviceUUIDStorage implements DeviceUUIDStorage {
  public storedUUID: string = '';
  public loadFailures: number = 0;
  public fileFailures: number = 0;
  public preferenceFailures: number = 0;
  public loads: number = 0;
  public saves: string[] = [];
  public preferenceAttempts: string[] = [];

  load(): string {
    this.loads++;
    if (this.loadFailures-- > 0) {
      throw new Error('Temporary UUID read failure');
    }
    return this.storedUUID;
  }

  save(uuid: string): void {
    this.saves.push(uuid);
    if (this.fileFailures-- > 0) {
      throw new Error('Temporary UUID file write failure');
    }
    this.storedUUID = uuid;
  }

  async flushPreferences(uuid: string): Promise<void> {
    this.preferenceAttempts.push(uuid);
    if (this.preferenceFailures-- > 0) {
      throw new Error('Temporary UUID flush failure');
    }
  }
}

function installStorage(storage: TestDeviceUUIDStorage): DeviceUUIDManager {
  DeviceUUIDManager.setStorageFactoryInternal((_context: Context): DeviceUUIDStorage => storage);
  const manager = DeviceUUIDManager.getInstance();
  manager.init({} as Context);
  return manager;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

export default function deviceUUIDManagerUnitTest() {
  describe('DeviceUUIDManagerUnitTest', (): void => {
    afterEach((): void => { DeviceUUIDManager.resetStateInternal(); });

    it('restoresBeforeTheFirstReadWithoutGeneratingATemporaryUUID', 0, async (): Promise<void> => {
      const storage = new TestDeviceUUIDStorage();
      storage.storedUUID = STORED_UUID;
      const manager = installStorage(storage);
      expect(manager.getDeviceUUID(false)).assertEqual(STORED_UUID);
      await manager.waitForPersistenceInternal();
      expect(manager.getDeviceUUID(false)).assertEqual(STORED_UUID);
      expect(storage.loads).assertEqual(1);
    });

    it('persistsBeforeReturningAndRestoresAfterSingletonReset', 0, (): void => {
      const storage = new TestDeviceUUIDStorage();
      const first = installStorage(storage).getDeviceUUID(false);
      expect(/^ft\.rd_[0-9a-f]{32}$/.test(first)).assertTrue();
      expect(storage.storedUUID).assertEqual(first);
      const restarted = installStorage(storage);
      expect(restarted.getDeviceUUID(false)).assertEqual(first);
      expect(restarted.getDeviceUUID(false)).assertEqual(first);
    });

    it('retriesReadsInsteadOfOverwritingTheStoredUUID', 0, (): void => {
      const storage = new TestDeviceUUIDStorage();
      storage.storedUUID = STORED_UUID;
      storage.loadFailures = 2;
      const manager = installStorage(storage);
      expect(manager.getDeviceUUID(false)).assertEqual('');
      expect(storage.saves.length).assertEqual(0);
      expect(manager.getDeviceUUID(false)).assertEqual(STORED_UUID);
      expect(storage.loads).assertEqual(3);
    });

    it('retriesFileAndPreferencesFailuresUsingTheSameUUID', 0, async (): Promise<void> => {
      const storage = new TestDeviceUUIDStorage();
      storage.fileFailures = 1;
      storage.preferenceFailures = 1;
      const manager = installStorage(storage);
      const uuid = manager.getDeviceUUID(false);
      await manager.waitForPersistenceInternal();
      await delay(350);
      await manager.waitForPersistenceInternal();
      expect(storage.storedUUID).assertEqual(uuid);
      expect(storage.preferenceAttempts.length).assertEqual(2);
      expect(storage.preferenceAttempts[0]).assertEqual(uuid);
      expect(storage.preferenceAttempts[1]).assertEqual(uuid);
      expect(storage.saves[0]).assertEqual(storage.saves[1]);
    });

    it('failedStartupReadRecoversWithoutAnotherCallerAndNotifiesRestoration', 0,
      async (): Promise<void> => {
        const storage = new TestDeviceUUIDStorage();
        storage.storedUUID = STORED_UUID;
        storage.loadFailures = 2;
        const manager = installStorage(storage);
        let restored = '';
        manager.setRestoreListenerInternal((): void => { restored = manager.getDeviceUUID(false); });
        expect(manager.getDeviceUUID(false)).assertEqual('');
        expect(storage.saves.length).assertEqual(0);
        await delay(350);
        expect(restored).assertEqual(STORED_UUID);
        expect(manager.getDeviceUUID(false)).assertEqual(STORED_UUID);
      });

    it('readRecoveryWithNoSavedUUIDGeneratesAndNotifiesOnlyAfterASuccessfulRead', 0,
      async (): Promise<void> => {
        const storage = new TestDeviceUUIDStorage();
        storage.loadFailures = 2;
        const manager = installStorage(storage);
        let restored = '';
        manager.setRestoreListenerInternal((): void => { restored = manager.getDeviceUUID(false); });
        expect(manager.getDeviceUUID(false)).assertEqual('');
        expect(storage.saves.length).assertEqual(0);
        await delay(350);
        expect(/^ft\.rd_[0-9a-f]{32}$/.test(restored)).assertTrue();
        expect(storage.storedUUID).assertEqual(restored);
      });

    it('doesNotGenerateBeforeStorageInitialization', 0, (): void => {
      expect(DeviceUUIDManager.getInstance().getDeviceUUID(false)).assertEqual('');
    });

    it('persistentReadFailureKeepsRetriesBoundedWithoutGeneratingAnIdentity', 0,
      async (): Promise<void> => {
        const storage = new TestDeviceUUIDStorage();
        storage.loadFailures = 100;
        const manager = installStorage(storage);
        await delay(2100);
        expect(storage.loads).assertEqual(4);
        expect(manager.getDeviceUUID(false)).assertEqual('');
        expect(storage.saves.length).assertEqual(0);
        expect(storage.preferenceAttempts.length).assertEqual(0);
      });

    it('resetCancelsRetriesFromThePreviousManager', 0, async (): Promise<void> => {
      const storage = new TestDeviceUUIDStorage();
      storage.preferenceFailures = 10;
      const manager = installStorage(storage);
      manager.getDeviceUUID(false);
      await manager.waitForPersistenceInternal();
      DeviceUUIDManager.resetStateInternal();
      await delay(350);
      expect(storage.preferenceAttempts.length).assertEqual(1);
    });
  });
}
