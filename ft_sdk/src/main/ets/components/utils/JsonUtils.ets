export class JsonUtils {
  /**
   * Check if JSON is valid
   * @param json
   * @returns
   */
  static isJSONValid(json: string): boolean {
    try {
      JSON.parse(json);
      return true;
    } catch {
      return false;
    }
  }
}