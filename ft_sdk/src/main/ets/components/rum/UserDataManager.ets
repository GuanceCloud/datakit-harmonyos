/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import preferences from '@ohos.data.preferences';
import { Context } from '@kit.AbilityKit';
import { FTInnerLogger } from '../log/FTLogger';
import { UserData } from './bean/UserData';
import { Utils } from '../utils/Utils';
import {
  PreferencesRandomIdentityStorage,
  RandomIdentityStorage,
  RandomIdentityStorageFactory
} from '../utils/RandomIdentityStorage';

const TAG = "UserDataManager";

interface UserDataPreferenceSnapshot {
  explicitlyUnbound: boolean;
  id: string;
  name: string;
  email: string;
  extJson: string;
}

/**
 * User data persistence manager for HarmonyOS
 * Manages user ID persistence using preferences
 */
export class UserDataManager {
  private static instance: UserDataManager | null = null;
  private static readonly PREFERENCES_NAME = 'ft_sdk_user_data';
  private static readonly KEY_USER_ID = 'ft.user.userid';
  private static readonly KEY_USER_NAME = 'ft.user.username';
  private static readonly KEY_USER_EMAIL = 'ft.user.email';
  private static readonly KEY_USER_EXT = 'ft.user.extdata';
  private static readonly RANDOM_USER_ID_PREFIX = 'ft.rd_';
  private static randomIdentityStorageFactory: RandomIdentityStorageFactory =
    (context: Context): RandomIdentityStorage => new PreferencesRandomIdentityStorage(
      context, UserDataManager.PREFERENCES_NAME, 'ft_sdk_random_user_id', UserDataManager.isValidRandomUserId);
  private preferencesStore: preferences.Preferences | null = null;
  private context: Context | null = null;
  private randomIdentityStorage: RandomIdentityStorage | null = null;
  private randomIdentityReady: boolean = false;
  private randomUserId: string = '';
  private persistedRandomUserId: string = '';
  private randomPersistenceInFlight: boolean = false;
  private randomPersistencePromise: Promise<void> = Promise.resolve();
  private randomPersistenceRetryTimer: number | null = null;
  private randomPersistenceRetries: number = 0;
  private randomRestoreRetryTimer: number | null = null;
  private randomRestoreRetries: number = 0;
  private released: boolean = false;
  private static readonly MAX_RANDOM_ID_RETRIES: number = 3;
  private userData: UserData | null = null;
  private userDataExplicitlyUnbound: boolean = false;
  private userDataGeneration: number = 0;
  private userDataPersistChain: Promise<void> = Promise.resolve();

  private constructor() {
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): UserDataManager {
    if (!UserDataManager.instance) {
      UserDataManager.instance = new UserDataManager();
    }
    return UserDataManager.instance;
  }

  public static resetStateInternal(): void {
    const instance = UserDataManager.instance;
    if (instance !== null) {
      instance.released = true;
      if (instance.randomPersistenceRetryTimer !== null) {
        clearTimeout(instance.randomPersistenceRetryTimer);
      }
      if (instance.randomRestoreRetryTimer !== null) {
        clearTimeout(instance.randomRestoreRetryTimer);
      }
    }
    UserDataManager.instance = null;
    UserDataManager.randomIdentityStorageFactory =
      (context: Context): RandomIdentityStorage => new PreferencesRandomIdentityStorage(
        context, UserDataManager.PREFERENCES_NAME, 'ft_sdk_random_user_id', UserDataManager.isValidRandomUserId);
  }

  /** Internal test seams, not exported from the public SDK entry point. */
  public static setRandomIdentityStorageFactoryInternal(factory: RandomIdentityStorageFactory): void {
    UserDataManager.resetStateInternal();
    UserDataManager.randomIdentityStorageFactory = factory;
  }

  public waitForRandomIdentityPersistenceInternal(): Promise<void> {
    return this.randomPersistencePromise;
  }

  /**
   * Restore identity before RUM can capture its first user snapshot, matching
   * Android's synchronous SharedPreferences read. The anonymous ID is committed
   * synchronously; persistence of bound user fields remains queued.
   */
  public init(context: Context): void {
    this.context = context;
    this.restoreRandomUserId();
    if (this.preferencesStore !== null) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(context, { name: UserDataManager.PREFERENCES_NAME });
      this.preferencesStore = store;
      // Explicit binding/unbinding before SDK installation takes precedence
      // over the identity left by a previous process.
      if (this.userDataGeneration === 0) {
        this.restoreUserData(store);
      } else {
        this.persistUserDataWhenReady();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to initialize UserDataManager: ${error}`);
    }
  }

  /**
   * Generate and save random user ID
   */
  private createNewRandomUserId(): void {
    const uuid = Utils.generateUUID();
    this.randomUserId = UserDataManager.RANDOM_USER_ID_PREFIX +
      (uuid.length > 0 ? uuid : Utils.generateRandomId(32));

    this.saveRandomUserId();
  }

  private static isValidRandomUserId(randomUserId: string): boolean {
    return randomUserId.startsWith(UserDataManager.RANDOM_USER_ID_PREFIX) &&
      randomUserId.length > UserDataManager.RANDOM_USER_ID_PREFIX.length;
  }

  private saveRandomUserId(): void {
    // A failed read is not evidence that the stored ID is absent. Never write
    // a temporary memory ID until the identity store has been read successfully.
    if (!this.randomIdentityReady || this.randomIdentityStorage === null || this.released ||
      !UserDataManager.isValidRandomUserId(this.randomUserId) ||
      this.persistedRandomUserId === this.randomUserId || this.randomPersistenceInFlight ||
      this.randomPersistenceRetryTimer !== null) {
      return;
    }
    const userId = this.randomUserId;
    let fileSaved = false;
    try {
      this.randomIdentityStorage.save(userId);
      fileSaved = true;
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to save random user ID file: ${error}`);
    }
    this.randomPersistenceInFlight = true;
    this.randomPersistencePromise = this.randomIdentityStorage.flushPreferences(userId).then((): void => {
      if (fileSaved) {
        this.persistedRandomUserId = userId;
        this.randomPersistenceRetries = 0;
      } else {
        this.scheduleRandomPersistenceRetry();
      }
    }).catch((error: Error): void => {
      FTInnerLogger.e(TAG, ` Failed to save random user ID Preferences: ${error}`);
      this.scheduleRandomPersistenceRetry();
    }).finally((): void => {
      this.randomPersistenceInFlight = false;
    });
  }

  /**
   * Restore before generation; failed reads remain retryable and cannot write.
   */
  private restoreRandomUserId(): void {
    if (this.randomIdentityReady || this.context === null || this.released) {
      return;
    }
    try {
      if (this.randomIdentityStorage === null) {
        this.randomIdentityStorage = UserDataManager.randomIdentityStorageFactory(this.context);
      }
      const storedRandomUserId = this.randomIdentityStorage.load();
      this.randomIdentityReady = true;
      this.randomRestoreRetries = 0;
      if (this.randomRestoreRetryTimer !== null) {
        clearTimeout(this.randomRestoreRetryTimer);
        this.randomRestoreRetryTimer = null;
      }
      if (UserDataManager.isValidRandomUserId(storedRandomUserId)) {
        this.randomUserId = storedRandomUserId;
        this.saveRandomUserId();
      } else if (!UserDataManager.isValidRandomUserId(this.randomUserId)) {
        this.createNewRandomUserId();
      } else {
        this.saveRandomUserId();
      }
    } catch (error) {
      this.randomIdentityStorage = null;
      FTInnerLogger.e(TAG, ` Failed to load random user ID: ${error}`);
      this.scheduleRandomRestoreRetry();
    }
  }

  private scheduleRandomPersistenceRetry(): void {
    if (this.released || this.randomPersistenceRetryTimer !== null ||
      this.randomPersistenceRetries >= UserDataManager.MAX_RANDOM_ID_RETRIES) {
      return;
    }
    this.randomPersistenceRetryTimer = setTimeout((): void => {
      this.randomPersistenceRetryTimer = null;
      this.saveRandomUserId();
    }, 250 * Math.pow(2, this.randomPersistenceRetries++));
  }

  private scheduleRandomRestoreRetry(): void {
    if (this.released || this.context === null || this.randomRestoreRetryTimer !== null ||
      this.randomRestoreRetries >= UserDataManager.MAX_RANDOM_ID_RETRIES) {
      return;
    }
    this.randomRestoreRetryTimer = setTimeout((): void => {
      this.randomRestoreRetryTimer = null;
      if (!this.released && this.context !== null) {
        this.init(this.context);
      }
    }, 250 * Math.pow(2, this.randomRestoreRetries++));
  }

  /**
   * Get random user ID
   */
  public getRandomUserId(): string {
    this.restoreRandomUserId();
    if (!this.randomIdentityReady) {
      return '';
    }
    if (!UserDataManager.isValidRandomUserId(this.randomUserId)) {
      this.createNewRandomUserId();
    }
    this.saveRandomUserId();
    return this.randomUserId;
  }

  /**
   * Load user data from preferences
   */
  private restoreUserData(store: preferences.Preferences): void {
    try {
      const idValue = store.getSync(UserDataManager.KEY_USER_ID, '');
      const nameValue = store.getSync(UserDataManager.KEY_USER_NAME, '');
      const emailValue = store.getSync(UserDataManager.KEY_USER_EMAIL, '');
      const extJsonValue = store.getSync(UserDataManager.KEY_USER_EXT, '');
      const id = typeof idValue === 'string' ? idValue : '';
      const name = typeof nameValue === 'string' ? nameValue : '';
      const email = typeof emailValue === 'string' ? emailValue : '';
      const extJson = typeof extJsonValue === 'string' ? extJsonValue : '';

      if (id || name || email || extJson) {
        this.userData = new UserData();
        this.userData.setId(id);
        this.userData.setName(name);
        this.userData.setEmail(email);

        if (extJson) {
          this.userData.setExtsWithJsonString(extJson);
        }
        this.userDataExplicitlyUnbound = false;
      } else {
        this.userData = null;
      }
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to load user data: ${error}`);
    }
  }

  /**
   * Get user data
   */
  public getUserData(): UserData | null {
    return this.userData;
  }

  /**
   * Bind user data
   */
  public bindUserData(userData: UserData): void {
    this.userData = userData;
    this.userDataExplicitlyUnbound = false;
    this.userDataGeneration++;
    this.persistUserDataWhenReady();
  }

  /**
   * Unbind user data
   */
  public unbindUserData(): void {
    this.userData = null;
    this.userDataExplicitlyUnbound = true;
    this.userDataGeneration++;
    this.persistUserDataWhenReady();
  }

  private persistUserDataWhenReady(): void {
    if (this.preferencesStore) {
      this.enqueueUserDataPersistence();
    }
  }

  private enqueueUserDataPersistence(): void {
    const store = this.preferencesStore;
    if (!store) {
      return;
    }
    const snapshot = this.createUserDataPreferenceSnapshot();
    this.userDataPersistChain = this.userDataPersistChain.then(async () => {
      await this.persistUserDataSnapshot(store, snapshot);
    }).catch((error: Error) => {
      FTInnerLogger.e(TAG, ` Failed to persist user data: ${error}`);
    });
  }

  private createUserDataPreferenceSnapshot(): UserDataPreferenceSnapshot {
    const userData = this.userData;
    if (this.userDataExplicitlyUnbound || userData === null) {
      return { explicitlyUnbound: true, id: '', name: '', email: '', extJson: '' };
    }
    return {
      explicitlyUnbound: false,
      id: userData.getId(),
      name: userData.getName(),
      email: userData.getEmail(),
      extJson: userData.getExtsJsonString()
    };
  }

  private async persistUserDataSnapshot(
    store: preferences.Preferences,
    snapshot: UserDataPreferenceSnapshot
  ): Promise<void> {
    try {
      if (snapshot.explicitlyUnbound) {
        await store.delete(UserDataManager.KEY_USER_ID);
        await store.delete(UserDataManager.KEY_USER_NAME);
        await store.delete(UserDataManager.KEY_USER_EMAIL);
        await store.delete(UserDataManager.KEY_USER_EXT);
      } else {
        await store.put(UserDataManager.KEY_USER_ID, snapshot.id);
        await store.put(UserDataManager.KEY_USER_NAME, snapshot.name);
        await store.put(UserDataManager.KEY_USER_EMAIL, snapshot.email);
        await store.put(UserDataManager.KEY_USER_EXT, snapshot.extJson);
      }
      await store.flush();
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to persist user data: ${error}`);
    }
  }


  /**
   * Check if user data is bound
   */
  public isUserDataBound(): boolean {
    const isBound = this.getUserData() !== null;
    return isBound;
  }
}
