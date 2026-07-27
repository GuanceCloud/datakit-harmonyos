/**
 * A value supported by data modification callbacks.
 *
 * The SDK serializes data into Line Protocol, so an object value is converted
 * to its string representation before it is written to the local cache.
 */
export type DataModifierValue = string | number | boolean | object;

/**
 * Data modifier interface for modifying tag and field values.
 *
 * Return null when the original value should be retained. This matches the
 * Android SDK contract and avoids requiring callers to return untouched values.
 */
export interface DataModifier {
  /**
   * Modify a single key-value pair
   * @param key The key to modify
   * @param value The original value
   * @returns The modified value, or null if no modification is needed
   */
  modify(key: string, value: DataModifierValue): DataModifierValue | null;
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
  modify(_key: string, _value: DataModifierValue): DataModifierValue | null {
    return null;
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
