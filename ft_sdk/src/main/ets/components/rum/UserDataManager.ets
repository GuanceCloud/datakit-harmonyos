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
import { FTInnerLogger } from '../log/FTLogger';
import { UserData } from './bean/UserData';
import { Utils } from '../utils/Utils';

const TAG = "UserDataManager";

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
  private preferencesStore: preferences.Preferences | null = null;
  private randomUserId: string = '';
  private userData: UserData | null = null;

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

  /**
   * Initialize preferences store
   */
  public init(context: Context) {
    try {
      //fixme
      this.preferencesStore = preferences.getPreferencesSync(context, { name: UserDataManager.PREFERENCES_NAME });
      this.loadRandomUserId();
      this.loadUserData();
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to initialize UserDataManager: ${error}`);
    }
  }

  /**
   * Generate and save random user ID
   */
  private createNewRandomUserId(): void {
    this.randomUserId = "ft.rd_" + Utils.generateUUID();

    this.saveRandomUserId();
  }

  private saveRandomUserId(): void {
    if (!this.preferencesStore) {
      FTInnerLogger.e(TAG, " Preferences store not available, cannot save random user ID");
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
  private loadRandomUserId(): void {
    if (!this.preferencesStore) {
      FTInnerLogger.e(TAG, " Preferences store not available, cannot load random user ID");
      return;
    }

    try {
      const storedRandomUserId = this.preferencesStore.getSync(UserDataManager.KEY_RANDOM_USER_ID, '') as string;
      if (storedRandomUserId) {
        this.randomUserId = storedRandomUserId;
      } else if (!this.randomUserId) {
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
    if (!this.randomUserId) {
      this.createNewRandomUserId();
    }
    return this.randomUserId;
  }

  /**
   * Load user data from preferences
   */
  private loadUserData(): void {
    if (!this.preferencesStore) {
      FTInnerLogger.e(TAG, " Preferences store not available, cannot load user data");
      return;
    }

    try {
      const id = this.preferencesStore.getSync(UserDataManager.KEY_USER_ID, '') as string;
      if (id) {
        const name = this.preferencesStore.getSync(UserDataManager.KEY_USER_NAME, '') as string;
        const email = this.preferencesStore.getSync(UserDataManager.KEY_USER_EMAIL, '') as string;
        const extJson = this.preferencesStore.getSync(UserDataManager.KEY_USER_EXT, '') as string;

        this.userData = new UserData();
        this.userData.setId(id);
        this.userData.setName(name);
        this.userData.setEmail(email);

        if (extJson) {
          this.userData.setExtsWithJsonString(extJson);
        }
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
    if (!this.preferencesStore) {
      FTInnerLogger.e(TAG, " Preferences store not initialized");
      return;
    }

    try {
      const saveUserData = async () => {
        try {
          await this.preferencesStore!.put(UserDataManager.KEY_USER_ID, userData.getId());
          await this.preferencesStore!.put(UserDataManager.KEY_USER_NAME, userData.getName());
          await this.preferencesStore!.put(UserDataManager.KEY_USER_EMAIL, userData.getEmail());
          const extJson = userData.getExtsJsonString();
          await this.preferencesStore!.put(UserDataManager.KEY_USER_EXT, extJson);
          await this.preferencesStore!.flush();
        } catch (error) {
          FTInnerLogger.e(TAG, ` Failed to bind user data: ${error}`);
        }
      };
      saveUserData();
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to bind user data: ${error}`);
    }
  }

  /**
   * Unbind user data
   */
  public unbindUserData(): void {
    this.userData = null;
    if (!this.preferencesStore) {
      FTInnerLogger.e(TAG, " Preferences store not initialized");
      return;
    }

    try {
      const clearUserData = async () => {
        try {
          await this.preferencesStore!.delete(UserDataManager.KEY_USER_ID);
          await this.preferencesStore!.delete(UserDataManager.KEY_USER_NAME);
          await this.preferencesStore!.delete(UserDataManager.KEY_USER_EMAIL);
          await this.preferencesStore!.delete(UserDataManager.KEY_USER_EXT);
          await this.preferencesStore!.flush();
        } catch (error) {
          FTInnerLogger.e(TAG, ` Failed to unbind user data: ${error}`);
        }
      };
      clearUserData();
    } catch (error) {
      FTInnerLogger.e(TAG, ` Failed to unbind user data: ${error}`);
    }
  }


  /**
   * Check if user data is bound
   */
  public isUserDataBound(): boolean {
    const isBound = this.userData !== null && this.userData.getId() !== '';
    return isBound;
  }
}
