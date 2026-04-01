/**
 * @author Tanranran
 * @date 2024/5/13 17:57
 * @description https://github.com/tanranran/HarmonyUtilCode
 */
import { CommonAllType } from '../Constants';
import { CharUtils } from './CharUtils';
import { ObjectUtils } from './ObjectUtils'
import { buffer, util } from '@kit.ArkTS';


export class StringUtils {
  /**
   * Check if string is whitespace (whitespace includes spaces, tabs, full-width spaces and non-breaking spaces) true if empty, false otherwise
   * @param str
   * @returns
   */
  static isBlank(str?: string | String | null | undefined): Boolean {
    let length: number;
    if ((str == null) || ((length = str.length) == 0)) {
      return true;
    }
    for (let i = 0; i < length; i++) {
      // As long as there is one non-empty character, it is a non-empty string
      if (false == CharUtils.isBlankChar(str.charCodeAt(i))) {
        return false;
      }
    }

    return true;
  }

  /**
   * Check if string is non-whitespace (whitespace includes spaces, tabs, full-width spaces and non-breaking spaces) true if non-empty, false otherwise
   * @param str
   * @returns
   */
  static isNotBlank(str: string | String | null | undefined): Boolean {
    return false == StringUtils.isBlank(str);
  }

  static startsWith(string: string = '', target: string, position: number = 0): boolean {
    return string.startsWith(target, position);
  }

  /**
   * Check if string is empty
   * @param str String to be checked
   * @return Whether empty
   */
  static isEmpty(property?: CommonAllType, isCheckUndefinedStr?: boolean): Boolean {
    if (ObjectUtils.isNull(property) || property == '') {
      return true
    }
    if (isCheckUndefinedStr && property == 'undefined') {
      return true
    }
    return ObjectUtils.isEmpty(property)
  }

  /**
   * Check if string is non-empty. true if non-empty, false otherwise
   * @param str
   * @returns
   */
  static isNotEmpty(str: string | undefined | null) {
    return false == StringUtils.isEmpty(str);
  }

  /**
   * Convert string to string, mainly for null safety
   * @param any
   * @param defaultValue
   * @returns
   */
  static toString(any: object | null | undefined, defaultValue: string = ""): string {
    if (any == null || any == undefined) {
      return defaultValue
    }
    return String(any);
  }

  /**
   * Replace all strings with specified string
   * @param source source string to replace in
   * @param s1 text to be replaced
   * @param s2 replacement text
   * @returns
   */
  static replaceAll(source: string, s1: string, s2: string) {
    return source.replace(new RegExp(s1, "gm"), s2);
  }

  /**
   * Convert a Uint8Array to a string
   * @param src Uint8Array
   * @returns string
   */
  static unit8ArrayToStr(src: Uint8Array, encoding: buffer.BufferEncoding = 'utf-8'): string {
    let textDecoder = util.TextDecoder.create(encoding, { ignoreBOM: true })
    let result = textDecoder.decodeWithStream(src, { stream: true });
    return result;
  }
}
