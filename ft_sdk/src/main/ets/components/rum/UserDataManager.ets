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
  private static readonly KEY_RANDOM_USER_ID = 'ft.user.session.id';
  private static readonly KEY_USER_ID = 'ft.user.userid';
  private static readonly KEY_USER_NAME = 'ft.user.username';
  private static readonly KEY_USER_EMAIL = 'ft.user.email';
  private static readonly KEY_USER_EXT = 'ft.user.extdata';
  private static readonly RANDOM_USER_ID_PREFIX = 'ft.rd_';
  private preferencesStore: preferences.Preferences | null = null;
  private randomUserId: string = '';
  private userData: UserData | null = null;
  private userDataExplicitlyUnbound: boolean = false;
  private preferencesInitPromise: Promise<void> | null = null;
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
    UserDataManager.instance = null;
  }

  /**
   * Initialize preferences store
   */
  public init(context: Context): void {
    if (this.preferencesInitPromise !== null || this.preferencesStore !== null) {
      return;
    }
    const generationAtInit = this.userDataGeneration;
    this.preferencesInitPromise = this.initializePreferences(context, generationAtInit);
  }

  private async initializePreferences(context: Context, generationAtInit: number): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: UserDataManager.PREFERENCES_NAME });
      this.preferencesStore = store;
      await this.restoreRandomUserId(store);
      if (this.userDataGeneration === generationAtInit) {
        await this.restoreUserData(store, generationAtInit);
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
    if (!this.preferencesStore) {
      return;
    }

    const saveTask = async (): Promise<void> => {
      try {
        await this.preferencesStore!.put(UserDataManager.KEY_RANDOM_USER_ID, this.randomUserId);
        await this.preferencesStore!.flush();
      } catch (error) {
        FTInnerLogger.e(TAG, ` Failed to save random user ID: ${error}`);
      }
    };
    saveTask();
  }

  /**
   * Load random user ID from preferences
   */
  private async restoreRandomUserId(store: preferences.Preferences): Promise<void> {
    try {
      const storedValue = await store.get(UserDataManager.KEY_RANDOM_USER_ID, '');
      const storedRandomUserId = typeof storedValue === 'string' ? storedValue : '';
      if (UserDataManager.isValidRandomUserId(storedRandomUserId)) {
        this.randomUserId = storedRandomUserId;
      } else if (!UserDataManager.isValidRandomUserId(this.randomUserId)) {
        this.createNewRandomUserId();
      } else {
        this.saveRandomUserId();
      }
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to load random user ID: ${error}`);
    }
  }

  /**
   * Get random user ID
   */
  public getRandomUserId(): string {
    if (!UserDataManager.isValidRandomUserId(this.randomUserId)) {
      this.createNewRandomUserId();
    }
    return this.randomUserId;
  }

  /**
   * Load user data from preferences
   */
  private async restoreUserData(store: preferences.Preferences, expectedGeneration: number): Promise<void> {
    try {
      const idValue = await store.get(UserDataManager.KEY_USER_ID, '');
      const nameValue = await store.get(UserDataManager.KEY_USER_NAME, '');
      const emailValue = await store.get(UserDataManager.KEY_USER_EMAIL, '');
      const extJsonValue = await store.get(UserDataManager.KEY_USER_EXT, '');
      const id = typeof idValue === 'string' ? idValue : '';
      const name = typeof nameValue === 'string' ? nameValue : '';
      const email = typeof emailValue === 'string' ? emailValue : '';
      const extJson = typeof extJsonValue === 'string' ? extJsonValue : '';

      if (this.userDataGeneration !== expectedGeneration) {
        this.persistUserDataWhenReady();
        return;
      }

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
    const initPromise = this.preferencesInitPromise;
    if (this.preferencesStore) {
      this.enqueueUserDataPersistence();
      return;
    }
    if (initPromise) {
      initPromise.then(() => this.enqueueUserDataPersistence());
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
