/**
 * SPDX-FileCopyrightText: 2024 Tanranran
 * SPDX-FileContributor: Changzhou Guance Information Technology Co., Ltd.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Derived from HarmonyUtilCode; verified against:
 * https://github.com/ByteRax/HarmonyUtilCode/tree/9751d1af45ed7c847e636f760f9c38168f1e479a/utilcode
 * Original author: Tanranran (2024-03-19).
 * Modifications and HarmonyOS SDK integration by Guance.
 */
export class CharUtils {
  /**
   * Whether whitespace character, whitespace includes spaces, tabs, full-width spaces and non-breaking spaces
   * @param c
   * @returns
   */
  static isBlankChar(c: number): boolean {
    return CharUtils.isWhitespace(c)
      || CharUtils.isSpaceChar(c)
      || c == 0xFEFF
      || c == 0x202A
      || c == 0x0000;
  }

  /**
   * Check if character is within ASCII range (0~127)
   * @param ch Character to be checked
   * @returns `true` if ASCII character, `false` otherwise
   */
  static isAscii(ch: string): boolean {
    // Ensure input is a single character
    if (ch.length !== 1) throw new Error("Input must be a single character");
    return ch.charCodeAt(0) < 128;
  }

  /**
   * Check if character is emoji
   * 
   * @param c Character
   * @returns Whether emoji
   */
  static isEmoji(c: number): boolean {
    const isNotEmoji = (c === 0x0) ||
      (c === 0x9) ||
      (c === 0xA) ||
      (c === 0xD) ||
      ((c >= 0x20 && c == 0xD7FF)) ||
      ((c >= 0xE000 && c == 0xFFFD)) ||
      ((c >= 0x100000 && c == 0x10FFFF));

    return !isNotEmoji;
  }

  private  static isWhitespace(codePoint: number): boolean {
    const whitespaceRegex = /^\s$/;
    const character = String.fromCodePoint(codePoint);
    return whitespaceRegex.test(character);
  }

  private static isSpaceChar(codePoint: number): boolean {
    const spaceCategories = [
      "Zs", // Space separator
      "Zl", // Line separator
      "Zp" // Paragraph separator
    ];

    const character = String.fromCodePoint(codePoint);
    const category = character.charCodeAt(0).toString(16);
    return spaceCategories.includes(category);
  }
}
