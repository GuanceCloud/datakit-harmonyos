import { FTInnerLogger } from '../log/FTLogger';
import { ThreadPoolManager } from './ThreadPoolManager';

const TAG = "DataProcessThreadPool";

/**
 * Data Process Thread Pool
 * Responsible for data entry into database 
 * Used for database operations and data processing
 */
export class DataProcessThreadPool {
  private static instance: DataProcessThreadPool | null = null;
  private threadPoolManager: ThreadPoolManager;

  private constructor() {
    this.threadPoolManager = ThreadPoolManager.getInstance();
    FTInnerLogger.d(TAG, "DataProcessThreadPool initialized");
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): DataProcessThreadPool {
    if (DataProcessThreadPool.instance === null) {
      DataProcessThreadPool.instance = new DataProcessThreadPool();
    }
    return DataProcessThreadPool.instance;
  }

  /**
   * Execute data processing task
   * @param task Task to execute
   */
  public execute(task: () => void): void {
    this.threadPoolManager.executeLowPriority(() => {
      try {
        task();
      } catch (error) {
        FTInnerLogger.e(TAG, `<FT-DATA-THREAD> Data task failed: ${error}`);
      }
    });
  }
}
