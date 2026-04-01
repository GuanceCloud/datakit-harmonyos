/**
 * Data modifier interface for modifying tag and field values
 */
export interface DataModifier {
  /**
   * Modify a single key-value pair
   * @param key The key to modify
   * @param value The original value
   * @returns The modified value, or the original value if no modification needed
   */
  modify(key: string, value: string): string;
}

/**
 * Line data modifier interface for modifying entire line protocol data
 */
export interface LineDataModifier {
  /**
   * Modify line protocol data
   * @param measurement The measurement name
   * @param tags The tags map
   * @param fields The fields map
   * @returns The modified data as a map of key-value pairs
   */
  modify(measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string>;
}

/**
 * Default data modifier that returns values unchanged
 */
export class DefaultDataModifier implements DataModifier {
  modify(key: string, value: string): string {
    return value;
  }
}

/**
 * Default line data modifier that returns data unchanged
 */
export class DefaultLineDataModifier implements LineDataModifier {
  modify(measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result = new Map<string, string>();
    tags.forEach((value, key) => result.set(key, value));
    fields.forEach((value, key) => result.set(key, value));
    return result;
  }
}
