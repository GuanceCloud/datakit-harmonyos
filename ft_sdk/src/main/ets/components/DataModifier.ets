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
 * Line data modifier interface for modifying one complete data record.
 *
 * It follows Android's patch contract: the callback receives the merged tags
 * and fields, then returns only values that should be replaced. Returning null
 * or an empty map leaves the record unchanged.
 */
export interface LineDataModifier {
  /**
   * Modify a complete data record.
   * @param measurement The measurement name
   * @param data The merged tags and fields of the original record
   * @returns A patch containing values to replace, or null for no modification
   */
  modify(measurement: string, data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null;
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
 * Default line data modifier that leaves data unchanged.
 */
export class DefaultLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    return null;
  }
}
