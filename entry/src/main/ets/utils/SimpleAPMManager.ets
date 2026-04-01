/**
 * Simplified APM Manager for HarmonyOS
 * Focuses on core functionality without complex API dependencies
 */

import { DemoLogger } from './DemoLogger';

const TAG = "SimpleAPMManager";

/**
 * APM Statistics Interface
 */
interface APMStats {
  crashCount: number;
  anrCount: number;
  errorCount: number;
  performanceScore: number;
  uptime: number;
  memoryUsage: number;
  cpuUsage: number;
}

/**
 * Crash Report Interface
 */
interface CrashReport {
  message: string;
  error?: Error;
  additionalInfo?: Record<string, string>;
  timestamp: number;
  stackTrace?: string;
}

/**
 * APM Report Interface
 */
interface APMReport {
  timestamp: string;
  stats: APMStatsString;
  crashReports: number;
  summary: string;
}

/**
 * APM Stats String Interface
 */
interface APMStatsString {
  crashCount: string;
  anrCount: string;
  errorCount: string;
  performanceScore: string;
  uptime: string;
  memoryUsage: string;
  cpuUsage: string;
  isInitialized: string;
}

/**
 * Simplified APM Manager
 */
export class SimpleAPMManager {
  private static instance: SimpleAPMManager;
  private stats: APMStats;
  private crashReports: CrashReport[];
  private isInitialized: boolean = false;

  private constructor() {
    this.stats = {
      crashCount: 0,
      anrCount: 0,
      errorCount: 0,
      performanceScore: 100,
      uptime: 0,
      memoryUsage: 0,
      cpuUsage: 0
    };
    this.crashReports = [];
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): SimpleAPMManager {
    if (!SimpleAPMManager.instance) {
      SimpleAPMManager.instance = new SimpleAPMManager();
    }
    return SimpleAPMManager.instance;
  }

  /**
   * Initialize APM manager
   */
  public initialize(): void {
    if (this.isInitialized) {
      return;
    }

    DemoLogger.i(TAG, "Initializing Simple APM Manager");
    
    // Initialize basic monitoring
    this.startUptimeTracking();
    this.isInitialized = true;
    
    DemoLogger.i(TAG, "Simple APM Manager initialized successfully");
  }

  /**
   * Start uptime tracking
   */
  private startUptimeTracking(): void {
    const startTime = Date.now();
    
    setInterval(() => {
      this.stats.uptime = Date.now() - startTime;
    }, 1000);
  }

  /**
   * Report crash
   */
  public reportCrash(message: string, error?: Error, additionalInfo?: Record<string, string>): void {
    DemoLogger.i(TAG, `Reporting crash: ${message}`);
    
    const crashReport: CrashReport = {
      message: message,
      error: error,
      additionalInfo: additionalInfo,
      timestamp: Date.now(),
      stackTrace: error ? error.stack : undefined
    };
    
    this.crashReports.push(crashReport);
    this.stats.crashCount++;
    
    DemoLogger.i(TAG, `Crash reported successfully. Total crashes: ${this.stats.crashCount}`);
  }

  /**
   * Report ANR
   */
  public reportANR(duration: number): void {
    DemoLogger.i(TAG, `Reporting ANR: ${duration}ms`);
    
    this.stats.anrCount++;
    this.stats.performanceScore = Math.max(0, this.stats.performanceScore - 10);
    
    DemoLogger.i(TAG, `ANR reported successfully. Total ANRs: ${this.stats.anrCount}`);
  }

  /**
   * Report error
   */
  public reportError(message: string, error?: Error): void {
    DemoLogger.i(TAG, `Reporting error: ${message}`);
    
    this.stats.errorCount++;
    
    DemoLogger.i(TAG, `Error reported successfully. Total errors: ${this.stats.errorCount}`);
  }

  /**
   * Get APM statistics
   */
  public getAPMStats(): APMStatsString {
    const statsString: APMStatsString = {
      crashCount: this.stats.crashCount.toString(),
      anrCount: this.stats.anrCount.toString(),
      errorCount: this.stats.errorCount.toString(),
      performanceScore: this.stats.performanceScore.toString(),
      uptime: this.stats.uptime.toString(),
      memoryUsage: this.stats.memoryUsage.toString(),
      cpuUsage: this.stats.cpuUsage.toString(),
      isInitialized: this.isInitialized.toString()
    };
    
    return statsString;
  }

  /**
   * Generate APM report
   */
  public generateAPMReport(): string {
    const stats = this.getAPMStats();
    const report: APMReport = {
      timestamp: new Date().toISOString(),
      stats: stats,
      crashReports: this.crashReports.length,
      summary: `APM Report: ${stats.crashCount} crashes, ${stats.anrCount} ANRs, ${stats.errorCount} errors`
    };
    
    return JSON.stringify(report, null, 2);
  }

  /**
   * Trigger crash test
   */
  public triggerCrashTest(type: string): void {
    DemoLogger.i(TAG, `Triggering crash test: ${type}`);
    
    switch (type) {
      case 'javascript':
        // Simulate JavaScript error
        setTimeout(() => {
          throw new Error(`Simulated JavaScript crash test - ${type}`);
          //try {
          //  throw new Error(`Simulated JavaScript crash test - ${type}`);
          //} catch (error) {
          //  this.reportCrash(`JavaScript crash test`, error as Error);
          //}
        }, 100);
        break;
        
      case 'promise':
        // Simulate Promise rejection
        setTimeout(() => {
          Promise.reject(new Error(`Simulated Promise rejection test - ${type}`))
            .catch((error: Error) => {
              this.reportCrash(`Promise rejection test`, error);
            });
        }, 100);
        break;
        
      default:
        DemoLogger.w(TAG, `Unknown crash test type: ${type}`);
    }
  }

  /**
   * Trigger ANR test
   */
  public triggerANRTest(duration: number): void {
    DemoLogger.i(TAG, `Triggering ANR test: ${duration}ms`);
    
    // Simulate ANR by blocking the main thread
    setTimeout(() => {
      const startTime = Date.now();
      while (Date.now() - startTime < duration) {
        // Block main thread
      }
      this.reportANR(duration);
    }, 100);
  }

  /**
   * Update performance metrics
   */
  public updatePerformanceMetrics(memoryUsage: number, cpuUsage: number): void {
    this.stats.memoryUsage = memoryUsage;
    this.stats.cpuUsage = cpuUsage;
    
    // Calculate performance score based on metrics
    const memoryScore = Math.max(0, 100 - (memoryUsage / 100));
    const cpuScore = Math.max(0, 100 - (cpuUsage * 10));
    this.stats.performanceScore = Math.round((memoryScore + cpuScore) / 2);
  }

  /**
   * Get crash reports
   */
  public getCrashReports(): CrashReport[] {
    return this.crashReports;
  }

  /**
   * Clear crash reports
   */
  public clearCrashReports(): void {
    this.crashReports = [];
    DemoLogger.i(TAG, "Crash reports cleared");
  }

  /**
   * Reset statistics
   */
  public resetStats(): void {
    this.stats = {
      crashCount: 0,
      anrCount: 0,
      errorCount: 0,
      performanceScore: 100,
      uptime: 0,
      memoryUsage: 0,
      cpuUsage: 0
    };
    this.crashReports = [];
    DemoLogger.i(TAG, "APM statistics reset");
  }
}
