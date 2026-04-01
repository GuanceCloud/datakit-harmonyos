/**
 * String wrapper class used to wrap a string as an object
 * Solves the issue that a string cannot be used directly as an object in ArkTS
 */
export class StringWrapper {
  value: string;
  
  constructor(value: string) {
    this.value = value;
  }
  
  /**
   * Get the wrapped string value
   */
  getValue(): string {
    return this.value;
  }
  
  /**
   * Set the string value
   */
  setValue(value: string): void {
    this.value = value;
  }
  
  /**
   * Convert to a string
   */
  toString(): string {
    return this.value;
  }
  
  /**
   * Static factory method that creates a StringWrapper instance
   */
  static wrap(value: string): StringWrapper {
    return new StringWrapper(value);
  }
  
  /**
   * Wrap an array of strings in batch
   */
  static wrapArray(values: string[]): StringWrapper[] {
    return values.map(value => new StringWrapper(value));
  }
}
