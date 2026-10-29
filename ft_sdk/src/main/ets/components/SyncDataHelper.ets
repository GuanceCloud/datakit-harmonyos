import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, LogGlobalContextDictionary, LogGlobalContextValue } from './Configs';
import { DataType } from './enum/Enums';
import { StringUtils } from './utils/StringUtils';
import { Constants } from './Constants';
import { FTInnerLogger } from './log/FTLogger';
import {
  DataModifier,
  DataModifierValue,
  LineDataModifier,
  DefaultDataModifier,
  DefaultLineDataModifier
} from './DataModifier';
import { FTRUMInnerManager } from './rum/FTRUMInnerManager';
import { CollectType } from './rum/enum/RUMEnums';
import { SDKLineProtocolContextDTO } from './thread/SDKWorkerProtocol';

const TAG = "SyncDataHelper";

export interface PreparedLineProtocolContent {
  measurement: string;
  tags: Record<string, string>;
  fields: Record<string, string>;
  time: number;
  integerCompatible: boolean;
}

export class SyncDataHelper {
  private basePublicTags: Map<string, string> = new Map();
  private logTags: Map<string, string> = new Map();
  private rumTags: Map<string, string> = new Map();
  private dynamicBaseTags: Map<string, string> = new Map();
  private dynamicLogTags: Map<string, string> = new Map();
  private dynamicRumTags: Map<string, string> = new Map();
  private rumStaticFields: Map<string, string> = new Map(); // Aligned with Android: rumStaticFields
  private config: FTSDKConfig | null = null;
  private logConfig: FTLoggerConfig | null = null;
  private dataModifier: DataModifier = new DefaultDataModifier();
  private lineDataModifier: LineDataModifier = new DefaultLineDataModifier();
  private enableDataIntegerCompatible: boolean = false; // Aligned with Android: integerCompatible

  initBaseConfig(config: FTSDKConfig): void {
    this.config = config;
    this.dataModifier = config.getDataModifier() || new DefaultDataModifier();
    this.lineDataModifier = config.getLineDataModifier() || new DefaultLineDataModifier();
    this.enableDataIntegerCompatible = config.isDataIntegerCompatible(); // Aligned with Android
    this.basePublicTags.clear();
    const globalContext = config.getGlobalContext();

    // Iterate through global context directly
    globalContext.forEach((value: object, key: string) => {
      // Use string value directly for tags (no JSON.stringify for simple strings)
      // Convert object to string: String objects should use String(value), not JSON.stringify
      // JSON.stringify would escape quotes in String objects, which is not desired
      const stringValue = typeof value === 'string' ? value as string : String(value);
      this.basePublicTags.set(key, this.applyDataModifier(key, stringValue));
    });
  }

  initLogConfig(config: FTLoggerConfig): void {
    this.logConfig = config;
    this.logTags.clear();
    // Copy base public tags
    this.basePublicTags.forEach((value, key) => {
      this.logTags.set(key, value);
    });
    // Copy log configuration global context
    const globalContext = config.getGlobalContext();

    // Iterate through global context directly
    globalContext.forEach((value: LogGlobalContextValue, key: string) => {
      this.putLogContextTag(this.logTags, key, value);
    });
  }

  initRUMConfig(config: FTRUMConfig): void {
    this.rumTags.clear();
    // Copy base public tags
    this.basePublicTags.forEach((value, key) => {
      this.rumTags.set(key, value);
    });
    // Copy RUM configuration global context
    const globalContext = config.getGlobalContext();

    // Iterate through global context directly
    globalContext.forEach((value: object, key: string) => {
      // Use string value directly for tags (no JSON.stringify for simple strings)
      // Convert object to string: String objects should use String(value), not JSON.stringify
      // JSON.stringify would escape quotes in String objects, which is not desired
      const stringValue = typeof value === 'string' ? value as string : String(value);
      this.rumTags.set(key, this.applyDataModifier(key, stringValue));
    });

    // Aligned with Android: add session sampling rate fields to rumStaticFields
    // Android: rumStaticFields.put(Constants.KEY_SESSION_SAMPLE_RATE, applyModifier(...))
    this.rumStaticFields.clear();
    this.rumStaticFields.set(
      Constants.KEY_SESSION_SAMPLE_RATE,
      this.applyDataModifier(Constants.KEY_SESSION_SAMPLE_RATE, String(config.getSamplingRate()))
    );
    this.rumStaticFields.set(
      Constants.KEY_SESSION_ON_ERROR_SAMPLE_RATE,
      this.applyDataModifier(Constants.KEY_SESSION_ON_ERROR_SAMPLE_RATE, String(config.getSessionErrorSampleRate()))
    );
  }

  appendGlobalContext(globalContext: Map<string, string>): void {
    if (globalContext) {
      globalContext.forEach((value, key) => {
        this.dynamicBaseTags.set(key, this.applyDataModifier(key, value));
      });
    }
  }

  appendGlobalContextByKeyValue(key: string, value: string): void {
    if (key && value) {
      const normalizedValue = this.applyDataModifier(key, value);
      this.dynamicBaseTags.set(key, normalizedValue);
      if (key === Constants.KEY_SDK_PACKAGE_INFO) {
        // Log and RUM tags copied this SDK-owned value during initialization.
        // Keep those copies in sync when the Hvigor plugin version changes.
        this.basePublicTags.set(key, normalizedValue);
        this.logTags.set(key, normalizedValue);
        this.rumTags.set(key, normalizedValue);
      }
    }
  }

  /** Remove SDK-owned tags when a runtime identity is unavailable. */
  removeGlobalContextKeyInternal(key: string): void {
    this.basePublicTags.delete(key);
    this.logTags.delete(key);
    this.rumTags.delete(key);
    this.dynamicBaseTags.delete(key);
    this.dynamicLogTags.delete(key);
    this.dynamicRumTags.delete(key);
  }

  /**
   * Dynamically set RUM global tag
   * @param globalContext RUM global context map
   */
  appendRUMGlobalContext(globalContext: Map<string, string>): void {
    if (!globalContext) {
      return;
    }

    globalContext.forEach((value, key) => {
      this.dynamicRumTags.set(key, this.applyDataModifier(key, value));
    });

    // Add all hashmap keys as a JSON string array (append to existing if KEY_RUM_CUSTOM_KEYS exists)
    const keys = Array.from(globalContext.keys());
    const existingCustomKeys = this.rumTags.get(Constants.KEY_RUM_CUSTOM_KEYS);
    let customKeysArray: string[] = [];

    if (existingCustomKeys) {
      try {
        customKeysArray = JSON.parse(existingCustomKeys);
      } catch (e) {
        // If parsing fails, start fresh
        customKeysArray = [];
      }
    }

    // Add new keys (avoid duplicates)
    keys.forEach(key => {
      if (!customKeysArray.includes(key)) {
        customKeysArray.push(key);
      }
    });

    this.rumTags.set(Constants.KEY_RUM_CUSTOM_KEYS, JSON.stringify(customKeysArray));
  }

  /**
   * Dynamically set RUM global tag
   * @param key Tag key
   * @param value Tag value
   */
  appendRUMGlobalContextByKeyValue(key: string, value: string): void {
    if (!key || !value) {
      return;
    }

    this.dynamicRumTags.set(key, this.applyDataModifier(key, value));

    // Add key to custom_keys array (append to existing if KEY_RUM_CUSTOM_KEYS exists)
    const newKey = key;
    const existingCustomKeys = this.rumTags.get(Constants.KEY_RUM_CUSTOM_KEYS);
    let customKeysArray: string[] = [];

    if (existingCustomKeys) {
      try {
        customKeysArray = JSON.parse(existingCustomKeys);
      } catch (e) {
        // If parsing fails, start fresh
        customKeysArray = [];
      }
    }

    // Add new key (avoid duplicates)
    if (!customKeysArray.includes(newKey)) {
      customKeysArray.push(newKey);
    }

    this.rumTags.set(Constants.KEY_RUM_CUSTOM_KEYS, JSON.stringify(customKeysArray));
  }

  /**
   * Dynamically set log global tag
   * @param globalContext Log global context map
   */
  appendLogGlobalContext(globalContext: LogGlobalContextDictionary): void {
    if (!globalContext) {
      return;
    }

    if (globalContext instanceof Map) {
      globalContext.forEach((value: LogGlobalContextValue, key: string) => {
        this.putLogContextTag(this.dynamicLogTags, key, value);
      });
      return;
    }

    const contextRecord = globalContext as Record<string, LogGlobalContextValue>;
    const keys = Object.keys(contextRecord);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      this.putLogContextTag(this.dynamicLogTags, key, contextRecord[key]);
    }
  }

  /**
   * Dynamically set log global tag
   * @param key Tag key
   * @param value Tag value
   */
  appendLogGlobalContextByKeyValue(key: string, value: LogGlobalContextValue): void {
    this.putLogContextTag(this.dynamicLogTags, key, value);
  }

  private putLogContextTag(targetTags: Map<string, string>, key: string, value: LogGlobalContextValue): void {
    if (!key) {
      return;
    }
    const stringValue = SyncDataHelper.contextValueToString(value);
    if (stringValue === null || StringUtils.isEmpty(stringValue)) {
      return;
    }
    targetTags.set(key, this.applyDataModifier(key, stringValue));
  }

  private static contextValueToString(value: LogGlobalContextValue): string | null {
    if (value === null || value === undefined) {
      return null;
    }

    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }

    if (value instanceof String || value instanceof Number || value instanceof Boolean) {
      return String(value);
    }

    const valueRecord = value as Record<string, object>;
    if (valueRecord && valueRecord['value'] !== undefined) {
      return String(valueRecord['value']);
    }

    const jsonValue = JSON.stringify(value);
    return jsonValue !== undefined ? jsonValue : String(value);
  }

  /**
   * Apply the field-level modifier while preserving Android's null-as-no-change
   * contract. All HarmonyOS Line Protocol values are normalized to strings
   * before they cross a worker boundary.
   */
  private applyDataModifier(key: string, value: string): string {
    const modifiedValue = this.dataModifier.modify(key, value);
    if (modifiedValue === null || modifiedValue === undefined) {
      return value;
    }
    return SyncDataHelper.dataModifierValueToString(modifiedValue);
  }

  /**
   * Apply the field modifier to raw event data without mutating caller-owned
   * maps. The non-mutating behavior prevents a modifier from running twice if
   * a worker formatting request falls back to the in-process formatter.
   */
  private applyDataModifierToMap(source: Map<string, string>): Map<string, string> {
    const result = new Map<string, string>();
    if (!source) {
      return result;
    }
    source.forEach((value, key) => {
      result.set(key, this.applyDataModifier(key, value));
    });
    return result;
  }

  private static dataModifierValueToString(value: DataModifierValue): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    const jsonValue = JSON.stringify(value);
    return jsonValue === undefined ? String(value) : jsonValue;
  }


  /**
   * Check if session should be collected
   * Aligned with Android: checks sampling rate via FTRUMInnerManager
   */
  checkSessionWillCollect(sessionId: string): boolean {
    if (!sessionId) {
      return true; // If no session ID, collect by default
    }

    // Check session collection based on sampling rate (aligned with Android)
    try {
      const collectType = FTRUMInnerManager.getInstance().checkSessionWillCollect(sessionId);
      // Return true only if CollectType is ALL (not DROP or SAMPLING)
      const willCollect = collectType === CollectType.ALL;

      return willCollect;
    } catch (error) {
      FTInnerLogger.e(TAG, `Error checking session collection: ${error}`);
      // Default to collect if error occurs
      return true;
    }
  }

  getBodyContent(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    dataType: DataType,
    uuid: string
  ): string {
    // Match Android's getBodyContent(): redact every raw tag and field before
    // SDK context is merged and before the row-level modifier runs.
    tags = this.applyDataModifierToMap(tags);
    fields = this.applyDataModifierToMap(fields);
    let mergeTags: Map<string, string> = new Map();
    mergeTags.set(Constants.KEY_SDK_DATA_FLAG, uuid);
    if (tags) {
      tags.forEach((value, key) => mergeTags.set(key, value));
    }

    let bodyContent = "";

    switch (dataType) {
      case DataType.LOG:
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicLogTags, this.logTags);
        // Aligned with Android: if logConfig.isEnableLinkRumData(), merge rumTags
        if (this.logConfig !== null) {
          if (this.logConfig.isEnableLinkRumData()) {
            // Merge RUM tags (static RUM tags from SyncDataHelper)
            this.rumTags.forEach((value, key) => {
              mergeTags.set(key, value);
            });
          }
        }
        this.applyLineDataModifier(measurement, mergeTags, fields);
        bodyContent = SyncDataHelper.convertToLineProtocolLine(
          measurement,
          mergeTags,
          fields,
          timeStamp,
          this.enableDataIntegerCompatible
        );
        break;
      case DataType.RUM_APP:
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, this.rumTags);
        // Aligned with Android: add rumStaticFields to fields (fields.putAll(rumStaticFields))
        this.rumStaticFields.forEach((value, key) => {
          if (measurement !== Constants.FT_MEASUREMENT_RUM_RESOURCE || !Constants.RESOURCE_RESERVED_FIELDS.includes(key)) {
            fields.set(key, value);
          }
        });
        this.removeReservedResourceTags(measurement, mergeTags);
        this.applyLineDataModifier(measurement, mergeTags, fields);
        bodyContent = SyncDataHelper.convertToLineProtocolLine(
          measurement,
          mergeTags,
          fields,
          timeStamp,
          this.enableDataIntegerCompatible
        );
        break;
      case DataType.RUM_WEBVIEW:
        // Aligned with Android: SyncDataHelper.getBodyContent() for RUM_WEBVIEW
        // Browser tags are overlaid by dynamic tags before static native RUM
        // tags are applied. The Web SDK version at this point is recorded in
        // sdk_pkg_info; static rumTags then replace sdk_version.
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, new Map());
        const webSDKVersion = mergeTags.get(Constants.KEY_SDK_VERSION) || "";

        // Aligned with Android: service remains Browser-SDK-owned, while
        // sdk_version is replaced by the native RUM tag after its Web value
        // has been recorded in sdk_pkg_info.
        // Debug: Log app_id in rumTags and mergeTags before replacement
        // const rumTagsAppId = this.rumTags.get(Constants.KEY_RUM_APP_ID);
        // const mergeTagsAppIdBefore = mergeTags.get(Constants.KEY_RUM_APP_ID);
        // FTInnerLogger.d(TAG,
        //   `[RUM-WEBVIEW] app_id in rumTags: "${rumTagsAppId}", in mergeTags before replacement: "${mergeTagsAppIdBefore}"`);

        this.rumTags.forEach((value, key) => {
          if (key !== Constants.KEY_SERVICE) {
            if (key === Constants.KEY_SDK_PACKAGE_INFO) {
              // Append Web SDK version to sdk_pkg_info (aligned with Android appendPackageVersion behavior)
              // Android SDK always calls appendPackageVersion even if webSDKVersion is null (converts to empty string)
              if (value && typeof value === 'string' && value.trim().startsWith('{')) {
                // Check if web version already exists in the JSON
                const hasWebVersion = value.includes(`"${Constants.KEY_RUM_SDK_PACKAGE_WEB}"`);
                if (!hasWebVersion) {
                  // Aligned with Android: always append web version, even if webSDKVersion is empty/null
                  // Android SDK appends KEY_RUM_SDK_PACKAGE_WEB with webSDKVersion + ""
                  const webVersionStr = webSDKVersion || ""; // Convert null/undefined to empty string
                  // Use helper function to parse and append web version
                  const updatedPkgInfo = this.parseAndAppendWebVersion(value, webVersionStr);
                  if (updatedPkgInfo) {
                    mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                      this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, updatedPkgInfo));
                  } else {
                    // Fallback: use string manipulation if JSON parsing fails (aligned with Android's appendPackageVersion)
                    const appendPkgInfo = value.substring(0, 1) +
                      `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}":"${webVersionStr}", ` +
                    value.substring(1);
                    mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                      this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, appendPkgInfo));
                  }
                } else {
                  // Already has web version, use original value
                  mergeTags.set(key, value);
                }
              } else {
                // If not JSON format, use original value
                mergeTags.set(key, value);
              }
            } else {
              mergeTags.set(key, value);
            }
          }
          // service remains WebView-owned.
        });

        this.applyLineDataModifier(measurement, mergeTags, fields);

        // After line data modifier, ensure sdk_pkg_info has web SDK version
        // The line data modifier might have modified sdk_pkg_info, so we need to check again
        // Aligned with Android: always append web version, even if webSDKVersion is empty/null
        if (this.lineDataModifier instanceof DefaultLineDataModifier &&
          mergeTags.has(Constants.KEY_SDK_PACKAGE_INFO)) {
          let finalPkgInfo = mergeTags.get(Constants.KEY_SDK_PACKAGE_INFO);

          // Remove surrounding quotes if present (line data modifier may add quotes)
          if (finalPkgInfo && typeof finalPkgInfo === 'string') {
            const trimmed = finalPkgInfo.trim();
            if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
                (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
              finalPkgInfo = trimmed.substring(1, trimmed.length - 1);
            }
          }

          if (finalPkgInfo && typeof finalPkgInfo === 'string') {
            try {
              // Check if web version already exists by searching for the key in the string
              const webKeyPattern = `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}"`;
              const hasWebVersion = finalPkgInfo.includes(webKeyPattern);
              const webVersionStr =
                webSDKVersion || ""; // Convert null/undefined to empty string (aligned with Android)
              // FTInnerLogger.d(TAG,
              //   `[RUM-WEBVIEW] Has web version in sdk_pkg_info: ${hasWebVersion}, webSDKVersion: "${webVersionStr}"`);

              if (!hasWebVersion) {
                // Aligned with Android: always append web version, even if webSDKVersion is empty/null
                // Use helper function to parse and append web version
                const updatedPkgInfo = this.parseAndAppendWebVersion(finalPkgInfo, webVersionStr);
                if (updatedPkgInfo) {
                  mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                    this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, updatedPkgInfo));
                } else {
                  // Fallback: use string manipulation if JSON parsing fails (aligned with Android's appendPackageVersion)
                  const jsonStr = finalPkgInfo.trim();
                  if (jsonStr.startsWith('{') && jsonStr.endsWith('}')) {
                    // Insert "web":"version" after the first {
                    const appendPkgInfo = jsonStr.substring(0, 1) +
                      `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}":"${webVersionStr}", ` +
                    jsonStr.substring(1);
                    mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                      this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, appendPkgInfo));
                  }
                }
              }
            } catch (error) {
              FTInnerLogger.e(TAG, `Error processing sdk_pkg_info: ${error}`);
            }
          }
        }
        bodyContent = SyncDataHelper.convertToLineProtocolLine(
          measurement,
          mergeTags,
          fields,
          timeStamp,
          this.enableDataIntegerCompatible
        );
        break;
      default:
        // Use base tags by default
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, this.basePublicTags);
        this.applyLineDataModifier(measurement, mergeTags, fields);
        bodyContent = SyncDataHelper.convertToLineProtocolLine(
          measurement,
          mergeTags,
          fields,
          timeStamp,
          this.enableDataIntegerCompatible
        );
        break;
    }
    return bodyContent;
  }

  prepareLineProtocolContent(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    dataType: DataType,
    uuid: string
  ): PreparedLineProtocolContent {
    // This is the normal worker-backed production path. Apply the same raw
    // field transformation as getBodyContent() before creating a serializable
    // worker payload.
    tags = this.applyDataModifierToMap(tags);
    fields = this.applyDataModifierToMap(fields);
    let mergeTags: Map<string, string> = new Map();
    mergeTags.set(Constants.KEY_SDK_DATA_FLAG, uuid);
    if (tags) {
      tags.forEach((value, key) => mergeTags.set(key, value));
    }

    switch (dataType) {
      case DataType.LOG:
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicLogTags, this.logTags);
        if (this.logConfig !== null && this.logConfig.isEnableLinkRumData()) {
          this.rumTags.forEach((value, key) => {
            mergeTags.set(key, value);
          });
        }
        this.applyLineDataModifier(measurement, mergeTags, fields);
        break;
      case DataType.RUM_APP:
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, this.rumTags);
        this.rumStaticFields.forEach((value, key) => {
          if (measurement !== Constants.FT_MEASUREMENT_RUM_RESOURCE || !Constants.RESOURCE_RESERVED_FIELDS.includes(key)) {
            fields.set(key, value);
          }
        });
        this.removeReservedResourceTags(measurement, mergeTags);
        this.applyLineDataModifier(measurement, mergeTags, fields);
        break;
      case DataType.RUM_WEBVIEW:
        this.prepareWebViewLineProtocolContent(measurement, mergeTags, fields);
        break;
      default:
        this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, this.basePublicTags);
        this.applyLineDataModifier(measurement, mergeTags, fields);
        break;
    }

    return {
      measurement,
      tags: SyncDataHelper.mapToStringRecord(mergeTags),
      fields: SyncDataHelper.mapToStringRecord(fields),
      time: timeStamp,
      integerCompatible: this.enableDataIntegerCompatible
    };
  }

  createWorkerLineProtocolContextSnapshot(): SDKLineProtocolContextDTO | null {
    if (!(this.lineDataModifier instanceof DefaultLineDataModifier)) {
      return null;
    }

    return {
      basePublicTags: SyncDataHelper.mapToStringRecord(this.basePublicTags),
      logTags: SyncDataHelper.mapToStringRecord(this.logTags),
      rumTags: SyncDataHelper.mapToStringRecord(this.rumTags),
      dynamicBaseTags: SyncDataHelper.mapToStringRecord(this.dynamicBaseTags),
      dynamicLogTags: SyncDataHelper.mapToStringRecord(this.dynamicLogTags),
      dynamicRumTags: SyncDataHelper.mapToStringRecord(this.dynamicRumTags),
      rumStaticFields: SyncDataHelper.mapToStringRecord(this.rumStaticFields),
      logLinkRumData: this.logConfig !== null && this.logConfig.isEnableLinkRumData(),
      integerCompatible: this.enableDataIntegerCompatible
    };
  }

  private applyLineDataModifier(
    measurement: string,
    mergeTags: Map<string, string>,
    fields: Map<string, string>
  ): void {
    const mergedData = new Map<string, DataModifierValue>();
    mergeTags.forEach((value, key) => mergedData.set(key, value));
    fields.forEach((value, key) => mergedData.set(key, value));

    const patch = this.lineDataModifier.modify(measurement, mergedData);
    if (patch === null || patch === undefined || patch.size === 0) {
      return;
    }

    // Android only applies values for keys already present in the record. This
    // prevents a callback patch from moving a field into tags, adding a new
    // key, or deleting data by omitting it from the returned map.
    patch.forEach((value, key) => {
      if (value === null || value === undefined) {
        return;
      }
      const lineValue = SyncDataHelper.dataModifierValueToString(value);
      if (mergeTags.has(key)) {
        mergeTags.set(key, lineValue);
      } else if (fields.has(key)) {
        fields.set(key, lineValue);
      }
    });
  }

  private removeReservedResourceTags(measurement: string, tags: Map<string, string>): void {
    if (measurement === Constants.FT_MEASUREMENT_RUM_RESOURCE) {
      for (const key of Constants.RESOURCE_RESERVED_FIELDS) {
        tags.delete(key);
      }
    }
  }

  private prepareWebViewLineProtocolContent(
    measurement: string,
    mergeTags: Map<string, string>,
    fields: Map<string, string>
  ): void {
    this.mergeDynamicTags(mergeTags, this.dynamicBaseTags, this.dynamicRumTags, new Map());
    const webSDKVersion = mergeTags.get(Constants.KEY_SDK_VERSION) || "";

    this.rumTags.forEach((value, key) => {
      if (key !== Constants.KEY_SERVICE) {
        if (key === Constants.KEY_SDK_PACKAGE_INFO) {
          if (value && typeof value === 'string' && value.trim().startsWith('{')) {
            const hasWebVersion = value.includes(`"${Constants.KEY_RUM_SDK_PACKAGE_WEB}"`);
            if (!hasWebVersion) {
              const webVersionStr = webSDKVersion || "";
              const updatedPkgInfo = this.parseAndAppendWebVersion(value, webVersionStr);
              if (updatedPkgInfo) {
                mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                  this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, updatedPkgInfo));
              } else {
                const appendPkgInfo = value.substring(0, 1) +
                  `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}":"${webVersionStr}", ` +
                value.substring(1);
                mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                  this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, appendPkgInfo));
              }
            } else {
              mergeTags.set(key, value);
            }
          } else {
            mergeTags.set(key, value);
          }
        } else {
          mergeTags.set(key, value);
        }
      }
    });

    this.applyLineDataModifier(measurement, mergeTags, fields);

    if (this.lineDataModifier instanceof DefaultLineDataModifier &&
      mergeTags.has(Constants.KEY_SDK_PACKAGE_INFO)) {
      let finalPkgInfo = mergeTags.get(Constants.KEY_SDK_PACKAGE_INFO);
      if (finalPkgInfo && typeof finalPkgInfo === 'string') {
        const trimmed = finalPkgInfo.trim();
        if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
            (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
          finalPkgInfo = trimmed.substring(1, trimmed.length - 1);
        }
      }

      if (finalPkgInfo && typeof finalPkgInfo === 'string') {
        try {
          const webKeyPattern = `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}"`;
          const hasWebVersion = finalPkgInfo.includes(webKeyPattern);
          const webVersionStr = webSDKVersion || "";
          if (!hasWebVersion) {
            const updatedPkgInfo = this.parseAndAppendWebVersion(finalPkgInfo, webVersionStr);
            if (updatedPkgInfo) {
              mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, updatedPkgInfo));
            } else {
              const jsonStr = finalPkgInfo.trim();
              if (jsonStr.startsWith('{') && jsonStr.endsWith('}')) {
                const appendPkgInfo = jsonStr.substring(0, 1) +
                  `"${Constants.KEY_RUM_SDK_PACKAGE_WEB}":"${webVersionStr}", ` +
                jsonStr.substring(1);
                mergeTags.set(Constants.KEY_SDK_PACKAGE_INFO,
                  this.applyDataModifier(Constants.KEY_SDK_PACKAGE_INFO, appendPkgInfo));
              }
            }
          }
        } catch (error) {
          FTInnerLogger.e(TAG, `Error processing sdk_pkg_info: ${error}`);
        }
      }
    }
  }

  private static mapToStringRecord(map: Map<string, string>): Record<string, string> {
    const record: Record<string, string> = {};
    map.forEach((value, key) => {
      if (value !== null && value !== undefined) {
        record[key] = String(value);
      }
    });
    return record;
  }

  public static recordToStringMap(record: Record<string, string>): Map<string, string> {
    const map = new Map<string, string>();
    if (!record) {
      return map;
    }
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      map.set(key, record[key]);
    }
    return map;
  }

  private mergeDynamicTags(
    mergeTags: Map<string, string>,
    baseTags: Map<string, string>,
    dynamicTags: Map<string, string>,
    staticTags: Map<string, string>
  ): void {
    // Merge all tags with priority: dynamic tags > static tags > base tags
    const allTags = new Map<string, string>();

    // Add base tags
    baseTags.forEach((value, key) => allTags.set(key, value));

    // Add static tags (override base tags)
    staticTags.forEach((value, key) => allTags.set(key, value));

    // Add dynamic tags (override static tags)
    dynamicTags.forEach((value, key) => allTags.set(key, value));

    // Add passed tags (highest priority)
    mergeTags.forEach((value, key) => allTags.set(key, value));

    // Update mergeTags
    mergeTags.clear();
    allTags.forEach((value, key) => mergeTags.set(key, value));
  }

  /**
   * Generate Line Protocol string from measurement, tags, fields and timestamp
   * @param measurement - The measurement name
   * @param tags - Map of tag key-value pairs
   * @param fields - Map of field key-value pairs
   * @param timeStamp - Timestamp in nanoseconds
   * @param integerCompatible - Whether to use integer format for numbers (default: false)
   * @returns Line Protocol formatted string
   */
  static convertToLineProtocolLine(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    integerCompatible: boolean = false
  ): string {

    if (!measurement) {
      throw new Error("Measurement cannot be null");
    }
    if (!fields) {
      throw new Error("Fields cannot be null");
    }

    const sb = SyncDataHelper.buildLineProtocol(measurement, tags, fields, timeStamp, integerCompatible);

    return sb;
  }

  /**
   * Build Line Protocol string
   * @param measurement - The measurement name
   * @param tags - Map of tag key-value pairs
   * @param fields - Map of field key-value pairs
   * @param timeStamp - Timestamp in nanoseconds
   * @param integerCompatible - Whether to use integer format for numbers
   * @returns Line Protocol formatted string
   */
  private static buildLineProtocol(
    measurement: string,
    tags: Map<string, string>,
    fields: Map<string, string>,
    timeStamp: number,
    integerCompatible: boolean
  ): string {
    let sb = "";

    // Escape measurement
    const escapedMeasurement = SyncDataHelper.translateMeasurements(measurement);
    sb += escapedMeasurement;

    // Add tags
    const tagsStr = SyncDataHelper.getCustomHash(tags, true, integerCompatible);
    if (tagsStr && tagsStr.length > 0) {
      sb += "," + tagsStr;
    }

    // Add fields
    const fieldsStr = SyncDataHelper.getCustomHash(fields, false, integerCompatible);
    if (fieldsStr && fieldsStr.length > 0) {
      sb += " " + fieldsStr;
    }

    // Add timestamp
    if (timeStamp) {
      sb += " " + timeStamp;
    }

    return sb;
  }

  /**
   * Get custom hash - 
   * @param obj - Map of key-value pairs
   * @param isTag - true for tags, false for fields
   * @param integerCompatible - Whether to use integer format for numbers
   */
  static getCustomHash(obj: Map<string, string>, isTag: boolean, integerCompatible: boolean): string {
    let sb = "";
    let first = true;

    obj.forEach((value, key) => {

      // Check if value is null or undefined
      if (value === null || value === undefined) {
        return; // Skip null and undefined values
      }

      // Check if string value is empty
      if (typeof value === 'string' && StringUtils.isEmpty(value)) {
        return; // Skip empty string values
      }

      if (!first) {
        sb += ",";
      }
      first = false;

      // Escape key
      const escapedKey = SyncDataHelper.translateTagKeyValue(key);

      if (typeof value === 'number') {
        // Aligned with Android: if integerCompatible=true, output as integer (no "i" suffix)
        // if integerCompatible=false, output as integer with "i" suffix
        if (integerCompatible && Number.isInteger(value)) {
          sb += `${escapedKey}=${value}`;
        } else if (Number.isInteger(value)) {
          sb += `${escapedKey}=${value}i`;
        } else {
          sb += `${escapedKey}=${value}`;
        }
      } else if (typeof value === 'boolean') {
        sb += `${escapedKey}=${value}`;
      } else if (typeof value === 'string') {
        // Try to parse string as number for integerCompatible mode (aligned with Android)
        // Android outputs Long/Integer as numbers, not strings
        if (integerCompatible && !isTag) {
          // Try to parse as integer first
          const intValue = Number.parseInt(value, 10);
          if (!Number.isNaN(intValue) && String(intValue) === value.trim()) {
            // It's a valid integer string, output as number (aligned with Android)
            sb += `${escapedKey}=${intValue}`;
            return; // Skip to next iteration in forEach
          }
          // Try to parse as float
          const floatValue = Number.parseFloat(value);
          if (!Number.isNaN(floatValue) && String(floatValue) === value.trim()) {
            // It's a valid float string, output as number
            sb += `${escapedKey}=${floatValue}`;
            return; // Skip to next iteration in forEach
          }
        }

        let cleanValue = value;

        // Check if it's a JSON object string like {"value":"harmonyos"}
        if (value.startsWith('{') && value.endsWith('}')) {
          try {
            const parsed = JSON.parse(value) as Record<string, object>;
            if (parsed && typeof parsed === 'object' && parsed.value !== undefined) {
              let extractedValue = String(parsed.value);
              // Remove quotes if present
              if (extractedValue.startsWith('"') && extractedValue.endsWith('"')) {
                extractedValue = extractedValue.slice(1, -1);
              }
              cleanValue = extractedValue;
            }
          } catch (parseError) {
            // JSON parsing failed, keep original value
          }
        } else if (value.startsWith('"') && value.endsWith('"')) {
          // Remove leading and trailing quotes if present
          cleanValue = value.slice(1, -1);
        }

        // Check if it's a numeric or boolean string - if so, don't add quotes in line protocol
        // This handles values like "123", "-436", "true", "false" which should not have quotes
        if (!isTag) {
          // For fields, check if the string represents a number or boolean.
          // ArkTS data maps commonly carry numeric fields as strings, so integerCompatible
          // must still control the Line Protocol integer suffix for integer strings.
          const integerPattern = /^-?\d+$/;
          const numericPattern = /^-?\d+(\.\d+)?$/;
          if (cleanValue && integerPattern.test(cleanValue)) {
            sb += integerCompatible ? `${escapedKey}=${cleanValue}` : `${escapedKey}=${cleanValue}i`;
          } else if (cleanValue && (numericPattern.test(cleanValue) || cleanValue === 'true' || cleanValue === 'false' || cleanValue === 'T' || cleanValue === 'F')) {
            // It's a float or boolean string, output without quotes
            sb += `${escapedKey}=${cleanValue}`;
          } else {
            // It's a real string, add quotes
            const fieldValue = SyncDataHelper.translateFieldValue(cleanValue);
            sb += `${escapedKey}=${fieldValue}`;
          }
        } else {
          // For tags, use translateTagKeyValue
          // Special handling for JSON strings like sdk_pkg_info: don't escape commas inside JSON
          let tagValue: string;
          if (key === Constants.KEY_SDK_PACKAGE_INFO && cleanValue.startsWith('{') && cleanValue.endsWith('}')) {
            // For JSON strings in sdk_pkg_info, only escape special characters outside JSON structure
            // Don't escape commas inside the JSON string
            tagValue = SyncDataHelper.translateTagKeyValueForJson(cleanValue);
          } else {
            tagValue = SyncDataHelper.translateTagKeyValue(cleanValue);
          }
          sb += `${escapedKey}=${tagValue}`;
        }
      } else {
        // Object type, check if it's a StringWrapper or simple string value
        if (typeof value === 'object' && value !== null) {
          const valueObj = value as Record<string, object>;

          // Check if it's a StringWrapper instance

          // Simplified approach: Check for 'value' property first
          if (valueObj['value'] !== undefined && typeof valueObj['value'] === 'string') {
            // It's an object with 'value' property containing string, extract the string value
            let stringValue = valueObj['value'] as string;
            // Remove quotes if present
            if (stringValue.startsWith('"') && stringValue.endsWith('"')) {
              stringValue = stringValue.slice(1, -1);
            }
            const fieldValue = isTag ?
              SyncDataHelper.translateTagKeyValue(stringValue) :
              SyncDataHelper.translateFieldValue(stringValue);
            sb += `${escapedKey}=${fieldValue}`;
          } else if (typeof valueObj['getValue'] === 'function') {
            // It has getValue method, try calling it
            try {
              const getValue = valueObj['getValue'] as Function;
              const stringValue = getValue() as string;
              const fieldValue = isTag ?
                SyncDataHelper.translateTagKeyValue(stringValue) :
                SyncDataHelper.translateFieldValue(stringValue);
              sb += `${escapedKey}=${fieldValue}`;
            } catch (error) {
              // Fallback to toString() for String objects
              try {
                const stringValue = String(value);
                const fieldValue = isTag ?
                  SyncDataHelper.translateTagKeyValue(stringValue) :
                  SyncDataHelper.translateFieldValue(stringValue);
                sb += `${escapedKey}=${fieldValue}`;
              } catch (error2) {
                FTInnerLogger.e(TAG, `Failed to convert object to string for key ${key}`);
              }
            }
          } else {
            // Try to convert object to string (handles String wrapper objects)
            try {
              const stringValue = String(value);
              if (stringValue.startsWith('{"') && stringValue.endsWith('}')) {
                // Try to parse as JSON and extract value if possible
                try {
                  const parsed = JSON.parse(stringValue) as Record<string, object>;
                  if (parsed && typeof parsed === 'object' && parsed.value !== undefined) {
                    let extractedValue = String(parsed.value);
                    // Remove quotes if present
                    if (extractedValue.startsWith('"') && extractedValue.endsWith('"')) {
                      extractedValue = extractedValue.slice(1, -1);
                    }
                    const fieldValue = isTag ?
                      SyncDataHelper.translateTagKeyValue(extractedValue) :
                      SyncDataHelper.translateFieldValue(extractedValue);
                    sb += `${escapedKey}=${fieldValue}`;
                  } else {
                    // Not a value wrapper, use as is
                    const fieldValue = isTag ?
                      SyncDataHelper.translateTagKeyValue(stringValue) :
                      SyncDataHelper.translateFieldValue(stringValue);
                    sb += `${escapedKey}=${fieldValue}`;
                  }
                } catch (parseError) {
                  // JSON parsing failed, use as regular string
                  const fieldValue = isTag ?
                    SyncDataHelper.translateTagKeyValue(stringValue) :
                    SyncDataHelper.translateFieldValue(stringValue);
                  sb += `${escapedKey}=${fieldValue}`;
                }
              } else {
                const fieldValue = isTag ?
                  SyncDataHelper.translateTagKeyValue(stringValue) :
                  SyncDataHelper.translateFieldValue(stringValue);
                sb += `${escapedKey}=${fieldValue}`;
              }
            } catch (error) {
              const jsonValue = JSON.stringify(value);
              const fieldValue = isTag ?
                SyncDataHelper.translateTagKeyValue(jsonValue) :
                SyncDataHelper.translateFieldValue(jsonValue);
              sb += `${escapedKey}=${fieldValue}`;
            }
          }
        }
      }
    });

    return sb;
  }

  /**
   * Convert Tag Key, Tag Value or Field Key
   * Aligned with Android: Utils.translateTagKeyValue()
   */
  static translateTagKeyValue(oldStr: string): string {
    if (!oldStr) return "";

    // Aligned with Android: oldStr = oldStr.replace("\n", " ");
    oldStr = oldStr.replace(/\n/g, " "); // Replace newline with space
    // Aligned with Android: oldStr = oldStr.replace("\\", "");
    oldStr = oldStr.replace(/\\/g, ""); // Remove backslashes (Android SDK behavior)
    oldStr = SyncDataHelper.translateSpecialCharacters(",", oldStr);
    oldStr = SyncDataHelper.translateSpecialCharacters("=", oldStr);
    return SyncDataHelper.translateSpecialCharacters(" ", oldStr);
  }

  /**
   * Convert Tag Value for JSON strings (like sdk_pkg_info)
   * In line protocol, tag values with commas must be escaped, even inside JSON strings
   * This method ensures proper escaping while preserving JSON structure
   */
  static translateTagKeyValueForJson(jsonStr: string): string {
    if (!jsonStr) return "";

    // For JSON strings in line protocol tags, we need to escape special characters
    // Aligned with Android SDK's translateTagKeyValue: escape comma, equals, and space
    // Android format: {"agent":"1.6.15-alpha02"\,\ "native":"1.1.2"\,\ "track":"1.3.5"}
    // The comma and space are both escaped: \, and \ (resulting in \,\ )

    // Replace newlines, carriage returns, and tabs with spaces (aligned with Android)
    let result = jsonStr.replace(/\n/g, " ");
    result = result.replace(/\r/g, " ");
    result = result.replace(/\t/g, " ");

    // Escape commas, equals signs, and spaces (aligned with Android SDK's translateTagKeyValue)
    // Android SDK: oldStr = translateSpecialCharacters(",", oldStr);
    //              oldStr = translateSpecialCharacters("=", oldStr);
    //              return translateSpecialCharacters(" ", oldStr);
    result = SyncDataHelper.translateSpecialCharacters(",", result);
    result = SyncDataHelper.translateSpecialCharacters("=", result);
    result = SyncDataHelper.translateSpecialCharacters(" ", result); // Space escaping is enabled

    return result;
  }

  /**
   * Convert Measurement
   * Aligned with Android: Utils.translateMeasurements()
   */
  static translateMeasurements(oldStr: string): string {
    if (!oldStr) return "";

    // Aligned with Android: oldStr = oldStr.replace("\\", "");
    oldStr = oldStr.replace(/\\/g, ""); // Remove backslashes (Android SDK behavior)
    oldStr = SyncDataHelper.translateSpecialCharacters(",", oldStr);
    return SyncDataHelper.translateSpecialCharacters(" ", oldStr);
  }

  /**
   * Convert Field Value - Always adds quotes (Android SDK logic)
   */
  static translateFieldValue(oldStr: string): string {
    if (!oldStr) return '""';

    // Escape special characters and wrap in quotes (Android SDK logic)
    // Note: Android's JSONObject.quote() always adds quotes, even for valid JSON
    oldStr = oldStr.replace(/\\/g, "\\\\"); // Escape backslash
    oldStr = SyncDataHelper.translateSpecialCharacters("\"", oldStr); // Escape quotes
    return `"${oldStr}"`; // Wrap in quotes
  }

  /**
   * Escape special characters
   */
  static translateSpecialCharacters(special: string, oldStr: string): string {
    if (!oldStr || !special) return oldStr;

    const specialRegex = new RegExp(special.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "g");
    return oldStr.replace(specialRegex, `\\${special}`);
  }

  /**
   * Helper to unescape JSON string (e.g., {\"agent\":\"0.1.0\"} -> {"agent":"0.1.0"})
   * @param jsonStr JSON string that may be escaped
   * @returns Unescaped JSON string
   */
  private unescapeJsonString(jsonStr: string): string {
    // Replace escaped quotes and backslashes
    // \" -> "
    // \\ -> \
    let unescaped = jsonStr;
    // Replace \\" with " (escaped quote)
    unescaped = unescaped.replace(/\\"/g, '"');
    // Replace \\\\ with \\ (escaped backslash)
    unescaped = unescaped.replace(/\\\\/g, '\\');
    return unescaped;
  }

  /**
   * Format JSON string to match Android SDK format (spaces after commas)
   * Android SDK appendPackageVersion behavior adds ", " (comma + space)
   * @param jsonStr JSON string
   * @returns Formatted JSON string with spaces after commas
   */
  private formatJsonStringWithSpaces(jsonStr: string): string {
    // Replace "," with ", " (comma followed by space) to match Android format
    // This only replaces commas between key-value pairs, not commas inside string values
    // Pattern: "key":"value","key2" -> "key":"value", "key2"
    return jsonStr.replace(/","/g, '", "');
  }

  /**
   * Helper to parse JSON string that may be escaped, and add web SDK version
   * @param jsonStr JSON string (may be escaped)
   * @param webSDKVersion Web SDK version to add
   * @returns Updated JSON string with web SDK version, or null if parsing fails
   */
  private parseAndAppendWebVersion(jsonStr: string, webSDKVersion: string): string | null {
    if (!jsonStr || !webSDKVersion) {
      return null;
    }

    let pkgInfoObj: object | null = null;

    // Try to parse as-is first
    try {
      pkgInfoObj = JSON.parse(jsonStr.trim());
    } catch (parseError) {
      // If parsing fails, try unescaping first
      try {
        const unescaped = this.unescapeJsonString(jsonStr.trim());
        pkgInfoObj = JSON.parse(unescaped);
      } catch (parseError2) {
        return null;
      }
    }

    if (!pkgInfoObj || typeof pkgInfoObj !== 'object') {
      return null;
    }

    // Check if web version already exists
    const pkgInfoRecord = pkgInfoObj as Record<string, string>;
    if (pkgInfoRecord[Constants.KEY_RUM_SDK_PACKAGE_WEB]) {
      // Already has web version, return as-is with spaces after commas
      return this.formatJsonStringWithSpaces(JSON.stringify(pkgInfoObj));
    }

    // Add web version to the object
    const updatedPkgInfo: Record<string, string> = {};
    updatedPkgInfo[Constants.KEY_RUM_SDK_PACKAGE_WEB] = webSDKVersion;

    // Copy existing properties
    const existingKeys = Object.keys(pkgInfoRecord);
    for (let i = 0; i < existingKeys.length; i++) {
      const key = existingKeys[i];
      updatedPkgInfo[key] = pkgInfoRecord[key];
    }

    // Return as JSON string with spaces after commas (to match Android SDK format)
    return this.formatJsonStringWithSpaces(JSON.stringify(updatedPkgInfo));
  }
}
