export class EntryWaitUtils {
  static async delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: Function) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  static async waitUntil(predicate: () => Promise<boolean>, timeoutMs: number = 5000, intervalMs: number = 150): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await predicate()) {
        return true;
      }
      await EntryWaitUtils.delay(intervalMs);
    }
    return await predicate();
  }
}
