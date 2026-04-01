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

import { FTInnerLogger } from '../../log/FTLogger';

const TAG = "UserData";

/**
 * User binding storage data
 * User data management for HarmonyOS
 * 
 * @author HarmonyOS SDK Team
 * @since 2024-01-01
 */
export class UserData {
  private static readonly TAG = "UserData";
  
  /**
   * User ID
   */
  private id: string = "";
  
  /**
   * User name
   */
  private name: string = "";
  
  /**
   * User email
   */
  private email: string = "";
  
  /**
   * Set data extension key-value pairs
   */
  private exts: Record<string, string> = {};
  
  /**
   * Constructor
   * @param id User ID
   * @param name User name
   * @param email User email
   * @param exts Extension properties
   */
  constructor(id?: string, name?: string, email?: string, exts?: Record<string, string>) {
    if (id) this.id = id;
    if (name) this.name = name;
    if (email) this.email = email;
    if (exts) this.exts = exts;
  }
  
  /**
   * Get user ID
   */
  public getId(): string {
    return this.id;
  }
  
  /**
   * Set user ID
   * @param id User ID
   */
  public setId(id: string): void {
    this.id = id;
  }
  
  /**
   * Get user name
   */
  public getName(): string {
    return this.name;
  }
  
  /**
   * Set user name
   * @param name User name
   */
  public setName(name: string): void {
    this.name = name;
  }
  
  /**
   * Get user email
   */
  public getEmail(): string {
    return this.email;
  }
  
  /**
   * Set user email
   * @param email User email
   */
  public setEmail(email: string): void {
    this.email = email;
  }
  
  /**
   * Get extension properties
   */
  public getExts(): Record<string, string> {
    return this.exts;
  }
  
  /**
   * Set extension properties
   * @param exts Extension properties
   */
  public setExts(exts: Record<string, string>): void {
    this.exts = exts;
  }
  
  /**
   * Add extension property
   * @param key Property key
   * @param value Property value
   */
  public addExt(key: string, value: string): void {
    this.exts[key] = value;
  }
  
  /**
   * Remove extension property
   * @param key Property key
   */
  public removeExt(key: string): void {
    if (this.exts[key] !== undefined) {
      const newExts: Record<string, string> = {};
      const keys = Object.keys(this.exts);
      for (let i = 0; i < keys.length; i++) {
        const extKey = keys[i];
        if (extKey !== key) {
          newExts[extKey] = this.exts[extKey];
        }
      }
      this.exts = newExts;
    }
  }
  
  /**
   * Get extension property value
   * @param key Property key
   * @returns Property value or empty string
   */
  public getExt(key: string): string {
    return this.exts[key] || "";
  }
  
  
  
  /**
   * Check if user data is valid
   * @returns true if at least one property is set
   */
  public isValid(): boolean {
    return this.id.length > 0 || this.name.length > 0 || this.email.length > 0;
  }
  
  /**
   * Check if user is signed in
   * @returns true if user has valid data
   */
  public isSignedIn(): boolean {
    return this.isValid();
  }
  
  /**
   * Clear all user data
   */
  public clear(): void {
    this.id = "";
    this.name = "";
    this.email = "";
    this.exts = {};
    FTInnerLogger.d(TAG, "User data cleared");
  }
  
  /**
   * Clone user data
   * @returns New UserData instance with same data
   */
  public clone(): UserData {
    const cloned = new UserData();
    cloned.id = this.id;
    cloned.name = this.name;
    cloned.email = this.email;
    cloned.exts = {};
    const keys = Object.keys(this.exts);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      cloned.exts[key] = this.exts[key];
    }
    return cloned;
  }
  
  /**
   * Check equality with another UserData
   * @param other Other UserData instance
   * @returns true if equal
   */
  public equals(other: UserData | null): boolean {
    if (!other) return false;
    
    if (this.id !== other.id) return false;
    if (this.name !== other.name) return false;
    if (this.email !== other.email) return false;
    
    // Check extension properties
    const thisKeys = Object.keys(this.exts).sort();
    const otherKeys = Object.keys(other.exts).sort();
    
    if (thisKeys.length !== otherKeys.length) return false;
    
    for (let i = 0; i < thisKeys.length; i++) {
      if (thisKeys[i] !== otherKeys[i]) return false;
      if (this.exts[thisKeys[i]] !== other.exts[thisKeys[i]]) return false;
    }
    
    return true;
  }

  /**
   * Convert extension data to JSON string
   * @returns JSON string of extension data
   */
  public getExtsJsonString(): string {
    try {
      return JSON.stringify(this.exts);
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to convert exts to JSON: ${error}`);
      return '{}';
    }
  }

  /**
   * Set extension data from JSON string
   * @param jsonString JSON string of extension data
   */
  public setExtsWithJsonString(jsonString: string): void {
    try {
      if (jsonString && jsonString !== '') {
        this.exts = JSON.parse(jsonString);
      } else {
        this.exts = {};
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to parse exts JSON: ${error}`);
      this.exts = {};
    }
  }
  
  /**
   * Get string representation
   * @returns String representation
   */
  public toString(): string {
    return `UserData{id='${this.id}', name='${this.name}', email='${this.email}', exts=${JSON.stringify(this.exts)}}`;
  }
  
  /**
   * Get summary for logging
   * @returns Summary string
   */
  public getSummary(): string {
    const parts: string[] = [];
    
    if (this.id.length > 0) {
      parts.push(`id=${this.id}`);
    }
    
    if (this.name.length > 0) {
      parts.push(`name=${this.name}`);
    }
    
    if (this.email.length > 0) {
      parts.push(`email=${this.email}`);
    }
    
    const extCount = Object.keys(this.exts).length;
    if (extCount > 0) {
      parts.push(`exts=${extCount} items`);
    }
    
    return parts.join(', ');
  }
}
