/**
 * SPDX-FileCopyrightText: 2024 Tanranran
 * SPDX-FileContributor: Changzhou Guance Information Technology Co., Ltd.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Derived from HarmonyUtilCode; verified against:
 * https://github.com/ByteRax/HarmonyUtilCode/tree/9751d1af45ed7c847e636f760f9c38168f1e479a/utilcode
 * Original author: Tanranran (2024-05-15).
 * Modifications and HarmonyOS SDK integration by Guance.
 */
import { bundleManager } from '@kit.AbilityKit';

export class AppUtils {
  private static mBundleInfo?: bundleManager.BundleInfo
  private static mAppName: string = ""

  private static getAppBundleInfo() {
    if (AppUtils.mBundleInfo != null) {
      return AppUtils.mBundleInfo
    }
    let bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    AppUtils.mBundleInfo = bundleManager.getBundleInfoForSelfSync(bundleFlags)
    return AppUtils.mBundleInfo
  }

  static isAppDebug(): Boolean {
    //https://developer.huawei.com/consumer/cn/forum/topic/0201147109742425145?fid=0109140870620153026
    return AppUtils.getAppBundleInfo().appInfo.debug
  }

  static isAppSystem() {
    return AppUtils.getAppBundleInfo().appInfo.systemApp
  }


  static getPackageName(): string {
    return AppUtils.getAppBundleInfo().name
  }

  static getAppName(): string {
    if (AppUtils.mAppName.length == 0) {
      AppUtils.mAppName = getContext().resourceManager.getStringSync(AppUtils.getAppBundleInfo().appInfo.labelId)
    }
    return AppUtils.mAppName
  }

  // getAppPath()

  static getAppVersionName(): string {
    return AppUtils.getAppBundleInfo().versionName
  }

  static getAppVersionCode(): number {
    return AppUtils.getAppBundleInfo().versionCode
  }

  /**
   * Minimum SDK version required to run the application package.
   * @returns 1000000
   */
  static getAppMinSdkVersion(): number {
    return AppUtils.getAppBundleInfo().minCompatibleVersionCode
  }

  /**
   * Maximum SDK version required to run the application package.
   * @returns 40100011
   */
  static getAppTargetSdkVersion(): number {
    return AppUtils.getAppBundleInfo().targetVersion
  }


  static getAppUid(): number {
    return AppUtils.getAppBundleInfo().appInfo.uid
  }

  static getAppInfo() {
    return AppUtils.getAppBundleInfo().appInfo
  }
}
