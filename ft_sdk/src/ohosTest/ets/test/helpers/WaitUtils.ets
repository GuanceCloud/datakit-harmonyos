export class WaitUtils {
  static async delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: Function) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  static async waitUntil(predicate: () => Promise<boolean>, timeoutMs: number = 5000, intervalMs: number = 120): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await predicate()) {
        return true;
      }
      await WaitUtils.delay(intervalMs);
    }
    return await predicate();
  }
}
