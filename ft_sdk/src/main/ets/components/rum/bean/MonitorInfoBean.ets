/**
 * Monitor information bean
 * Monitor Info Bean for HarmonyOS
 */
export class MonitorInfoBean {
  public maxValue: number = 0;
  public miniValue: number = 0;
  public avgValue: number = 0;
  public count: number = 0;
  public sum: number = 0;

  constructor() {
    this.reset();
  }

  /**
   * Reset values
   */
  public reset(): void {
    this.maxValue = 0;
    this.miniValue = 0;
    this.avgValue = 0;
    this.count = 0;
    this.sum = 0;
  }

  /**
   * Add a value
   * @param value Value to add
   */
  public addValue(value: number): void {
    if (this.count === 0) {
      this.maxValue = value;
      this.miniValue = value;
    } else {
      this.maxValue = Math.max(this.maxValue, value);
      this.miniValue = Math.min(this.miniValue, value);
    }
    this.count++;
    this.sum += value;
    this.avgValue = this.sum / this.count;
  }

  /**
   * Check if the bean is valid
   * @returns true if valid
   */
  public isValid(): boolean {
    return this.count > 0;
  }
}
