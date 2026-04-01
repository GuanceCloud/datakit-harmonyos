/**
 * @author Tanranran
 * @date 2024/5/13 22:58
 * @description https://github.com/tanranran/HarmonyUtilCode
 */
// import { CommonAllType } from './const/CommonConst'
import { ArrayList, List, HashMap } from '@kit.ArkTS';
import { CommonAllType } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';

export class ObjectUtils {
  /**
   * Determine whether a property is of type string
   * @param property
   * @returns
   */
  static isString(property: string | Object | ArrayBuffer | undefined | null): Boolean {
    return typeof property === 'string' || property instanceof String
  }

  /**
   * Determine whether a property is null or undefined
   * @param property
   * @returns
   */
  static isNull(property: CommonAllType): Boolean {
    return property === null || property === undefined
  }

  /**
   * Determine whether a property's content is empty
   * @param property
   * @returns
   */
  static isEmpty(property:CommonAllType): Boolean {
    if (ObjectUtils.isNull(property)) {
      return true
    } else if (Array.isArray(property) || property instanceof Array) {
      return property.length == 0
    } else if (property instanceof List) {
      return property.isEmpty()
    } else if (property instanceof ArrayList) {
      return property.isEmpty()
    } else if (property instanceof HashMap) {
      return property.isEmpty()
    }
    return property == '';
  }

  /**
   * Determine whether two input numbers or strings are equal
   * @param source
   * @param target
   * @returns
   */
  static equal(source: string | number, target: string | number): boolean {
    return source === target;
  }

  /**
   * Determine whether two input numbers or strings are not equal
   * @param source
   * @param target
   * @returns
   */
  static notEqual(source: string | number, target: string | number): boolean {
    return false == ObjectUtils.equal(source, target);
  }


  /**
   * Set the value of the specified property in an object
   * @param obj
   * @param key
   * @param defaultValue
   * @returns
   */
  static setValue(obj: object, key: string, value: CommonAllType) {
    try {
      if (obj) {
        obj[key] = value;
      }
    } catch (e) {
      FTInnerLogger.e("ObjectUtils", `${ObjectUtils.name}_setValue failed: ${e}`);
    }
  }


}
