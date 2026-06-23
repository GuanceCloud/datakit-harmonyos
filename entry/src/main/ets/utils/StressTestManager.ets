import {
  createFTRCPTrackConfig,
  FTLogger,
  FTRUMGlobalManager,
  NetStatusBean,
  ResourceParams,
  Status,
  StringWrapper
} from '@guancecloud/ft_sdk/Index';
import { LogEntry } from '@guancecloud/ft_sdk/src/main/ets/components/log/FTLogger';
import { rcp } from '@kit.RemoteCommunicationKit';
import { KEY_TRACE_URL } from '../entryability/EntryAbility';
import { DemoLogger } from './DemoLogger';

const TAG = "StressTestManager";
const IO_CACHE_STRESS_TAG = "io_cache_stress";

/**
 * Stress Test Manager - Singleton class for managing stress test threads
 * Provides interfaces: run(), stop(), and getElapsedSeconds()
 */
export class StressTestManager {
  private static instance: StressTestManager | null = null;
  
  // Thread interval IDs for stopping
  private logIntervalIds: number[] = [];
  private actionIntervalIds: number[] = [];
  private resourceIntervalIds: number[] = [];
  
  // Running state
  private isRunning: boolean = false;
  private startTime: number = 0;
  private durationSeconds: number = 0; // Total duration in seconds
  private autoStopTimerId: number | null = null; // Timer ID for auto-stop
  
  // RUM Manager instance
  private rumManager: FTRUMGlobalManager | null = null;
  
  // Counter for unique IDs
  private logCounter: number = 0;
  private actionCounter: number = 0;
  private resourceCounter: number = 0;
  
  // Data source flag
  private useRealData: boolean = true; // Use real HTTP data (true) or fake data (false)

  private constructor() {
    // Private constructor for singleton
  }

  private getTraceTestUrl(): string {
    return ((AppStorage.get(KEY_TRACE_URL) as string | undefined) ?? "").trim();
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): StressTestManager {
    if (StressTestManager.instance === null) {
      StressTestManager.instance = new StressTestManager();
    }
    return StressTestManager.instance;
  }

  /**
   * Initialize RUM Manager
   */
  private initRUM(): void {
    if (this.rumManager === null) {
      this.rumManager = FTRUMGlobalManager.getInstance();
      if (this.rumManager === null) {
        DemoLogger.e(TAG, "Failed to get FTRUMGlobalManager instance");
        return;
      }
      if (!this.rumManager.isInitialized()) {
        DemoLogger.w(TAG, "RUM Manager not initialized, stress test may not work correctly");
      } else {
        DemoLogger.i(TAG, "RUM Manager initialized successfully");
      }
    }
  }

  /**
   * Start stress test - creates 6 threads:
   * - Log: 4 threads, each sends log batch every 20ms (target: 20+ logs per 100ms)
   * - Action: 2 threads, each sends action every 20ms
   * - Resource: 2 threads, each sends resource every 200ms
   * @param durationSeconds Total duration in seconds (0 means run indefinitely until stop() is called)
   * @param useRealData Use real HTTP data (true) or fake data (false)
   */
  public run(durationSeconds: number = 0, useRealData: boolean = true): void {
    if (this.isRunning) {
      DemoLogger.w(TAG, "Stress test is already running");
      return;
    }

    this.initRUM();
    this.isRunning = true;
    this.startTime = Date.now();
    this.durationSeconds = durationSeconds;
    this.useRealData = useRealData;
    this.logCounter = 0;
    this.actionCounter = 0;
    this.resourceCounter = 0;
    
    // Clear previous interval IDs
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];

    const durationMinutes = Math.floor(durationSeconds / 60);
    const durationRemainingSeconds = durationSeconds % 60;
    const durationStr = durationSeconds > 0 
      ? `${durationSeconds} seconds (${durationMinutes} minutes ${durationRemainingSeconds} seconds)`
      : 'indefinite';
    DemoLogger.i(TAG, `Starting stress test with 6 threads... Duration: ${durationStr}, UseRealData: ${useRealData}`);

    // Start 4 Log threads, each sends one log every 20ms
    // This produces roughly 20 logs per 100ms in normal conditions, matching I/O batch window expectation.
    for (let i = 0; i < 4; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        this.sendLog(threadIndex);
      }, 20);
      this.logIntervalIds.push(intervalId);
      DemoLogger.i(TAG, `Log thread ${threadIndex} started`);
    }

    // Start 2 Action threads
    for (let i = 0; i < 2; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        this.sendAction(threadIndex);
      }, 20);
      this.actionIntervalIds.push(intervalId);
      DemoLogger.i(TAG, `Action thread ${threadIndex} started`);
    }

    // Start 2 Resource threads
    for (let i = 0; i < 2; i++) {
      const threadIndex = i;
      const intervalId = setInterval((): void => {
        if (!this.isRunning) {
          clearInterval(intervalId);
          return;
        }
        // Call async sendResource without await (fire and forget)
        this.sendResource(threadIndex).catch((error:Error) => {
          DemoLogger.e(TAG, `Error in sendResource for thread ${threadIndex}: ${error}`);
        });
      }, 200);
      this.resourceIntervalIds.push(intervalId);
      DemoLogger.i(TAG, `Resource thread ${threadIndex} started`);
    }

    DemoLogger.i(TAG, "All stress test threads started");
    
    // Set up auto-stop timer if duration is specified
    // This is the single source of truth for test duration control
    if (durationSeconds > 0) {
      const durationMinutes = Math.floor(durationSeconds / 60);
      const durationRemainingSeconds = durationSeconds % 60;
      DemoLogger.i(TAG, `Setting up auto-stop timer: ${durationSeconds} seconds (${durationMinutes} minutes ${durationRemainingSeconds} seconds)`);
      
      this.autoStopTimerId = setTimeout((): void => {
        const actualElapsed = this.getElapsedSeconds();
        DemoLogger.i(TAG, `Stress test duration (${durationSeconds} seconds = ${durationMinutes} minutes ${durationRemainingSeconds} seconds) reached, auto-stopping... (actual elapsed: ${actualElapsed} seconds)`);
        this.stop();
      }, durationSeconds * 1000);
    } else {
      DemoLogger.i(TAG, "No duration specified, test will run indefinitely until stop() is called");
    }
  }

  /**
   * Start a focused log I/O cache stress test.
   *
   * This uses FTLogger.batchLog() in short peaks so TrackLogManager can verify
   * scheduler coalescing and FTDBManager can exercise cache writes.
   */
  public runLogIoCacheStress(totalLogs: number = 200, peakSize: number = 2, intervalMs: number = 50): void {
    if (this.isRunning) {
      DemoLogger.w(TAG, "Stress test is already running");
      return;
    }

    const normalizedTotalLogs = Math.max(1, Math.floor(totalLogs));
    const normalizedPeakSize = Math.max(1, Math.floor(peakSize));
    const normalizedIntervalMs = Math.max(16, Math.floor(intervalMs));

    this.isRunning = true;
    this.startTime = Date.now();
    this.durationSeconds = 0;
    this.useRealData = false;
    this.logCounter = 0;
    this.actionCounter = 0;
    this.resourceCounter = 0;
    this.logIntervalIds = [];
    this.actionIntervalIds = [];
    this.resourceIntervalIds = [];

    DemoLogger.i(TAG,
      `Starting I/O cache peak stress test: totalLogs=${normalizedTotalLogs}, peakSize=${normalizedPeakSize}, intervalMs=${normalizedIntervalMs}`);

    const emitPeak = (): void => {
      if (!this.isRunning) {
        return;
      }

      const remaining = normalizedTotalLogs - this.logCounter;
      if (remaining <= 0) {
        this.finishLogIoCacheStress(normalizedTotalLogs);
        return;
      }

      const count = Math.min(normalizedPeakSize, remaining);
      this.sendLogBatch(count, IO_CACHE_STRESS_TAG);

      if (this.logCounter >= normalizedTotalLogs) {
        this.finishLogIoCacheStress(normalizedTotalLogs);
      }
    };

    const intervalId = setInterval(emitPeak, normalizedIntervalMs);
    this.logIntervalIds.push(intervalId);
    emitPeak();
  }

  /**
   * Send a single batch of custom logs through FTLogger.batchLog().
   */
  public sendLogBatch(batchSize: number = 2, tag: string = IO_CACHE_STRESS_TAG): void {
    const normalizedBatchSize = Math.max(1, Math.floor(batchSize));
    const batchLogs: LogEntry[] = [];

    for (let i = 0; i < normalizedBatchSize; i++) {
      const logIndex = this.logCounter++;
      batchLogs.push({
        tag,
        message: `I/O cache stress log ${logIndex}`,
        level: 'i'
      });
    }

    FTLogger.batchLog(batchLogs);
    DemoLogger.i(TAG, `Submitted log peak: tag=${tag}, size=${batchLogs.length}, totalGenerated=${this.logCounter}`);
  }

  private finishLogIoCacheStress(totalLogs: number): void {
    if (!this.isRunning) {
      return;
    }

    const elapsedSeconds = this.getElapsedSeconds();
    this.isRunning = false;

    for (let i = 0; i < this.logIntervalIds.length; i++) {
      clearInterval(this.logIntervalIds[i]);
    }
    this.logIntervalIds = [];

    DemoLogger.i(TAG, `I/O cache stress test finished: totalLogs=${totalLogs}, elapsed=${elapsedSeconds}s`);
  }

  /**
   * Send log message
   */
  private sendLog(threadIndex: number): void {
    try {
      const logIndex = this.logCounter++;
      const logMessage = `Stress test log from thread ${threadIndex}, index ${logIndex}`;
      FTLogger.logBackground(logMessage, Status.INFO.name);
    } catch (error) {
      DemoLogger.e(TAG, `Failed to send log from thread ${threadIndex}: ${error}`);
    }
  }

  /**
   * Send action
   */
  private sendAction(threadIndex: number): void {
    try {
      if (this.rumManager === null) {
        DemoLogger.w(TAG, `rumManager is null, cannot send action from thread ${threadIndex}`);
        return;
      }
      if (!this.rumManager.isInitialized()) {
        DemoLogger.w(TAG, `rumManager is not initialized, cannot send action from thread ${threadIndex}`);
        return;
      }
      const actionIndex = this.actionCounter++;
      const actionName = `stress_action_thread${threadIndex}_${actionIndex}`;
      const property: Record<string, object> = {
        "stress_test": new StringWrapper("true"),
        "thread_index": new StringWrapper(threadIndex.toString()),
        "action_index": new StringWrapper(actionIndex.toString())
      };
      this.rumManager.addActionWithProperty(actionName, 'click', property);
    } catch (error) {
      DemoLogger.e(TAG, `Failed to send action from thread ${threadIndex}: ${error}`);
    }
  }

  /**
   * Send resource - uses real API request or fake data based on useRealData flag
   */
  private async sendResource(threadIndex: number): Promise<void> {
    try {
      if (this.rumManager === null) {
        return;
      }
      
      const resourceIndex = this.resourceCounter++;
      
      if (this.useRealData) {
        // Use real API request
        const realApiUrl = this.getTraceTestUrl();
        
        const session = rcp.createSession(createFTRCPTrackConfig());

        // Use a session configured with FT interceptors to generate resource data
        const request = new rcp.Request(realApiUrl, 'GET');
        const response = await session.fetch(request);
        
        if (response.statusCode >= 200 && response.statusCode < 300) {
          DemoLogger.i(TAG, `Resource from thread ${threadIndex}, index ${resourceIndex} request successful: ${response.statusCode}`);
        } else {
          DemoLogger.w(TAG, `Resource from thread ${threadIndex}, index ${resourceIndex} request returned status: ${response.statusCode}`);
        }
      } else {
        // Use fake data (manually generated)
        const resourceId = `stress_resource_thread${threadIndex}_${resourceIndex}_${Date.now()}`;
        const url = `https://api.example.com/stress/resource/thread${threadIndex}/${resourceIndex}`;
        
        // Create resource params
        const params: ResourceParams = new ResourceParams();
        params.url = url;
        params.resourceMethod = 'GET';
        params.resourceStatus = 200;
        params.resourceType = 'network';
        params.requestHeader = 'Content-Type: application/json';
        params.responseHeader = 'Content-Type: application/json; charset=utf-8';
        params.responseBody = `{"status":"success","thread_index":${threadIndex},"resource_index":${resourceIndex},"timestamp":${Date.now()}}`;
        params.responseContentLength = params.responseBody.length;
        params.responseContentType = 'application/json';
        params.responseConnection = 'keep-alive';
        
        // Set property
        const propertyMap: Map<string, object> = new Map();
        propertyMap.set("stress_test", new StringWrapper("true"));
        propertyMap.set("thread_index", new StringWrapper(threadIndex.toString()));
        propertyMap.set("resource_index", new StringWrapper(resourceIndex.toString()));
        params.setProperty(propertyMap);
        
        // Create net status bean with fixed values extracted from Android log
        // Android log line:
        //   resource_dns=10, resource_tcp=20, resource_ssl=30, resource_first_byte=100, resource_ttfb=100
        //   resource_dns_time="{\"duration\":10, \"start\":0}"
        //   resource_connect_time="{\"duration\":20, \"start\":10}"
        //   resource_ssl_time="{\"duration\":30, \"start\":30}"
        //   resource_first_byte_time="{\"duration\":100, \"start\":60}"
        //   resource_download_time="{\"duration\":50, \"start\":160}"
        //   duration=210
        const netStatusBean: NetStatusBean = new NetStatusBean();
        
        // Durations extracted directly from Android log (in milliseconds)
        const dnsDurationMs = 10;        // from resource_dns=10 and resource_dns_time duration=10
        const tcpDurationMs = 20;        // from resource_tcp=20 and resource_connect_time duration=20
        const sslDurationMs = 30;        // from resource_ssl=30 and resource_ssl_time duration=30
        const ttfbDurationMs = 100;      // from resource_first_byte=100, resource_ttfb=100, resource_first_byte_time duration=100
        const downloadDurationMs = 50;   // from resource_download_time duration=50
        
        // Convert to nanoseconds (1ms = 1,000,000ns)
        const MS_TO_NS = 1000000;
        const dnsDuration = dnsDurationMs * MS_TO_NS;
        const tcpDuration = tcpDurationMs * MS_TO_NS;
        const sslDuration = sslDurationMs * MS_TO_NS;
        const ttfbDuration = ttfbDurationMs * MS_TO_NS;
        const downloadDuration = downloadDurationMs * MS_TO_NS;
        
        // DNS: start = 0, duration = 10ms (in nanoseconds)
        netStatusBean.setDNSStartTime(0);
        netStatusBean.setDNSTime(dnsDuration);
        
        // Connect (TCP): start = 10ms, duration = 20ms (in nanoseconds)
        netStatusBean.setConnectStartTime(dnsDuration);
        netStatusBean.setTcpTime(tcpDuration);
        
        // SSL: start = 30ms (10+20), duration = 30ms (in nanoseconds)
        netStatusBean.setSslStartTime(dnsDuration + tcpDuration);
        netStatusBean.setSSLTime(sslDuration);
        
        // FirstByte (TTFB): start = 60ms (10+20+30), duration = 100ms (in nanoseconds)
        netStatusBean.setFirstByteStartTime(dnsDuration + tcpDuration + sslDuration);
        netStatusBean.setFirstByteTime(ttfbDuration);
        
        // Download: start = 160ms (10+20+30+100), duration = 50ms (in nanoseconds)
        netStatusBean.setDownloadTimeStart(dnsDuration + tcpDuration + sslDuration + ttfbDuration);
        netStatusBean.setDownloadTime(downloadDuration);
        
        // Total request time: 210ms (10+20+30+100+50) (in nanoseconds)
        netStatusBean.setHoleRequestTime(dnsDuration + tcpDuration + sslDuration + ttfbDuration + downloadDuration);
        
        // Use addResource directly - it handles startResource, setTransformContent, setNetState, and checkToAddResource internally
        this.rumManager.addResource(resourceId, params, netStatusBean);
        
        // Stop resource after addResource to set end time and trigger data sending
        this.rumManager.stopResource(resourceId, params.resourceStatus || 200, params.responseContentLength || 0);
      }
    } catch (error) {
      DemoLogger.e(TAG, `Failed to send resource from thread ${threadIndex}: ${error}`);
    }
  }

  /**
   * Stop all stress test threads
   */
  public stop(): void {
    if (!this.isRunning) {
      DemoLogger.w(TAG, "Stress test is not running");
      return;
    }

    DemoLogger.i(TAG, "Stopping all stress test threads...");
    
    // Clear auto-stop timer if exists
    if (this.autoStopTimerId !== null) {
      clearTimeout(this.autoStopTimerId);
      this.autoStopTimerId = null;
    }
    
    // Calculate elapsed time BEFORE setting isRunning to false
    // This ensures getElapsedSeconds() returns the correct value
    const elapsedSeconds = this.getElapsedSeconds();
    
    this.isRunning = false;

    // Stop all log threads
    for (let i = 0; i < this.logIntervalIds.length; i++) {
      clearInterval(this.logIntervalIds[i]);
      DemoLogger.i(TAG, `Log thread ${i} stopped`);
    }
    this.logIntervalIds = [];

    // Stop all action threads
    for (let i = 0; i < this.actionIntervalIds.length; i++) {
      clearInterval(this.actionIntervalIds[i]);
      DemoLogger.i(TAG, `Action thread ${i} stopped`);
    }
    this.actionIntervalIds = [];

    // Stop all resource threads
    for (let i = 0; i < this.resourceIntervalIds.length; i++) {
      clearInterval(this.resourceIntervalIds[i]);
      DemoLogger.i(TAG, `Resource thread ${i} stopped`);
    }
    this.resourceIntervalIds = [];

    DemoLogger.i(TAG, `All stress test threads stopped. Total runtime: ${elapsedSeconds} seconds`);
  }

  /**
   * Get elapsed seconds since stress test started
   * @returns number of seconds elapsed, or 0 if not started
   */
  public getElapsedSeconds(): number {
    if (this.startTime === 0) {
      return 0;
    }
    // Calculate elapsed time even if isRunning is false
    // This allows accurate time reporting after stop() is called
    const elapsedMs = Date.now() - this.startTime;
    return Math.floor(elapsedMs / 1000);
  }

  /**
   * Get remaining seconds until stress test ends
   * @returns number of seconds remaining, or -1 if duration is not set (indefinite), or 0 if time is up
   */
  public getRemainingSeconds(): number {
    if (this.durationSeconds <= 0) {
      return -1; // Indefinite duration
    }
    if (this.startTime === 0) {
      return this.durationSeconds; // Not started yet
    }
    const elapsedSeconds = this.getElapsedSeconds();
    const remaining = this.durationSeconds - elapsedSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /**
   * Check if stress test is running
   */
  public isStressTestRunning(): boolean {
    return this.isRunning;
  }
}
