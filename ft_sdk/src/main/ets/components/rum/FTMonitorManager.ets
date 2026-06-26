import { ErrorMonitorType, ERROR_MONITOR_NO_SET } from './enum/ErrorMonitorType';
import { DeviceMetricsMonitorType, DEVICE_METRICS_MONITOR_NO_SET } from './enum/DeviceMetricsMonitorType';
import { MonitorInfoBean } from './bean/MonitorInfoBean';
import { ActiveViewBean } from './bean/ActiveViewBean';
import { FTRUMConfig } from '../Configs';
import { FTInnerLogger } from '../log/FTLogger';
import { Constants } from '../Constants';
import { Utils } from '../utils/Utils';
import { CpuUtils } from '../utils/CpuUtils';
import { MemoryUtils } from '../utils/MemoryUtils';
import { BatteryUtils } from '../utils/BatteryUtils';
import { FpsUtils } from '../utils/FpsUtils';

const TAG = "FTMonitorManager";

/**
 * Monitor item configuration
 * Monitor Manager for HarmonyOS
 */
export class FTMonitorManager {
  private static instance: FTMonitorManager | null = null;
  
  /**
   * One second, in nanoseconds
   */
  private static readonly ONE_SECOND_NANO_TIMES = 1000000000;

  /**
   * Error monitor type, default is not set
   */
  private errorMonitorType: number = ERROR_MONITOR_NO_SET;
  
  /**
   * Device metrics monitor type, default is not set
   */
  private deviceMetricsMonitorType: number = DEVICE_METRICS_MONITOR_NO_SET;

  /**
   * Monitor runners map
   */
  private runnerMap: Map<string, MonitorRunnable> = new Map();

  /**
   * Is TV device
   */
  private isTVDevice: boolean = false;

  private constructor() {
    // Initialize
  }

  /**
   * Get singleton instance
   */
  public static getInstance(): FTMonitorManager {
    if (!FTMonitorManager.instance) {
      FTMonitorManager.instance = new FTMonitorManager();
    }
    return FTMonitorManager.instance;
  }

  /**
   * Initialize with config
   * @param config RUM config
   */
  public async initWithConfig(config: FTRUMConfig): Promise<void> {
    this.errorMonitorType = config.getExtraMonitorTypeWithError();
    this.deviceMetricsMonitorType = config.getDeviceMetricsMonitorType();
    
    // Initialize monitoring tools with performance optimization
    try {
      if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)) {
        await CpuUtils.getInstance().init();
        // Set CPU collection interval to 5 seconds for performance
        CpuUtils.getInstance().setCollectionInterval(5000);
        FTInnerLogger.d(TAG, "CPU monitoring initialized with 5s interval");
      }
      
      if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)) {
        await MemoryUtils.getInstance().init();
        // Set memory collection interval to 3 seconds for performance
        MemoryUtils.getInstance().setCollectionInterval(3000);
        FTInnerLogger.d(TAG, "Memory monitoring initialized with 3s interval");
      }
      
      if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)) {
        await BatteryUtils.getInstance().init();
        FTInnerLogger.d(TAG, "Battery monitoring initialized");
      }
      
      if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
        await FpsUtils.getInstance().init();
        FpsUtils.getInstance().start();
        FTInnerLogger.d(TAG, "FPS monitoring initialized and started");
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to initialize monitoring tools: ${error}`);
    }

    // TODO: Check if TV device
    this.isTVDevice = false;
  }

  /**
   * Determine whether a certain type of monitoring is enabled
   * @param errorMonitorType Error monitor type
   * @returns true if enabled
   */
  public isErrorMonitorType(errorMonitorType: ErrorMonitorType): boolean {
    if (this.isTVDevice && errorMonitorType === ErrorMonitorType.BATTERY) {
      return false;
    }
    return ((this.errorMonitorType & errorMonitorType) >>> 0) === (errorMonitorType >>> 0);
  }

  /**
   * Determine whether a certain device metrics monitoring is enabled
   * @param deviceMetricsMonitorType Device metrics monitor type
   * @returns true if enabled
   */
  public isDeviceMetricsMonitorType(deviceMetricsMonitorType: DeviceMetricsMonitorType): boolean {
    if (this.isTVDevice && deviceMetricsMonitorType === DeviceMetricsMonitorType.BATTERY) {
      return false;
    }
    return ((this.deviceMetricsMonitorType & deviceMetricsMonitorType) >>> 0) === (deviceMetricsMonitorType >>> 0);
  }

  /**
   * Register viewId for monitoring
   * @param viewId View unique ID
   */
  public addMonitor(viewId: string): void {
    FTInnerLogger.d(TAG, `addMonitor: ${viewId}, remain count: ${this.runnerMap.size}`);
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    
    const runner = new MonitorRunnable();
    this.runnerMap.set(viewId, runner);
    runner.start();
  }

  /**
   * Attach monitoring indicator data (fps, cpu, memory)
   * @param bean ActiveViewBean
   */
  public attachMonitorData(bean: ActiveViewBean): void {
    const viewId = bean.getId();
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    
    const runner = this.runnerMap.get(viewId);
    if (runner) {
      const battery = runner.getBatteryBean();
      if (battery.isValid()) {
        bean.setBatteryCurrentMax(Math.floor(battery.maxValue));
        bean.setBatteryCurrentAvg(Math.floor(battery.avgValue));
      }
      
      const cpu = runner.getCpuBean();
      if (cpu.isValid()) {
        if (cpu.maxValue > 0) {
          const tickCount = Math.floor(cpu.maxValue - cpu.miniValue);
          bean.setCpuTickCount(tickCount);
          const now = Utils.getCurrentNanoTime(); // Get nanosecond timestamp
          const duration = now - bean.getStartTime();
          if (duration > 0) {
            bean.setCpuTickCountPerSecond((tickCount * FTMonitorManager.ONE_SECOND_NANO_TIMES) / duration);
          }
        }
      }
      
      const fps = runner.getFpsBean();
      if (fps.isValid()) {
        bean.setFpsMini(fps.miniValue);
        bean.setFpsAvg(fps.avgValue);
      }
      
      const memory = runner.getMemoryBean();
      if (memory.isValid()) {
        bean.setMemoryMax(Math.floor(memory.maxValue));
        bean.setMemoryAvg(Math.floor(memory.avgValue));
      }
    }
  }

  /**
   * Remove monitoring
   * @param viewId View ID
   */
  public removeMonitor(viewId: string): void {
    FTInnerLogger.d(TAG, `removeMonitor: ${viewId}`);
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    
    const runner = this.runnerMap.get(viewId);
    if (runner) {
      runner.stop();
      this.runnerMap.delete(viewId);
    }
  }

  /**
   * Release resources
   */
  public static release(): void {
    if (FTMonitorManager.instance) {
      // Stop all runners
      FTMonitorManager.instance.runnerMap.forEach((runner) => {
        runner.stop();
      });
      FTMonitorManager.instance.runnerMap.clear();
      FTMonitorManager.instance = null;
    }
  }
}

/**
 * Monitor runnable for collecting device metrics
 */
class MonitorRunnable {
  private batteryBean: MonitorInfoBean = new MonitorInfoBean();
  private cpuBean: MonitorInfoBean = new MonitorInfoBean();
  private fpsBean: MonitorInfoBean = new MonitorInfoBean();
  private memoryBean: MonitorInfoBean = new MonitorInfoBean();
  private intervalId: number | null = null;
  private isRunning: boolean = false;

  /**
   * Start monitoring
   */
  public start(): void {
    if (this.isRunning) {
      return;
    }
    
    this.isRunning = true;
    // Start monitoring every 2 seconds for better performance
    // Individual tools have their own caching mechanisms
    this.intervalId = setInterval(async () => {
      await this.collectMetrics();
    }, 2000);
  }

  /**
   * Stop monitoring
   */
  public stop(): void {
    this.isRunning = false;
    if (this.intervalId !== null) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  /**
   * Collect device metrics
   */
  private async collectMetrics(): Promise<void> {
    await Promise.all([
      this.collectBatteryMetrics(),
      this.collectCpuMetrics(),
      this.collectFpsMetrics(),
      this.collectMemoryMetrics()
    ]);
  }

  /**
   * Collect battery metrics
   */
  private async collectBatteryMetrics(): Promise<void> {
    try {
      const batteryCurrent = await BatteryUtils.getInstance().getBatteryCurrent();
      if (batteryCurrent > 0) {
        this.batteryBean.addValue(batteryCurrent);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to collect battery metrics: ${error}`);
    }
  }

  /**
   * Collect CPU metrics
   */
  private async collectCpuMetrics(): Promise<void> {
    try {
      const cpuTickCount = await CpuUtils.getInstance().getAppCpuTickCount();
      if (cpuTickCount > 0) {
        this.cpuBean.addValue(cpuTickCount);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to collect CPU metrics: ${error}`);
    }
  }

  /**
   * Collect FPS metrics
   */
  private async collectFpsMetrics(): Promise<void> {
    try {
      const fps = FpsUtils.getInstance().getFps();
      if (fps > 0) {
        this.fpsBean.addValue(fps);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to collect FPS metrics: ${error}`);
    }
  }

  /**
   * Collect memory metrics
   */
  private async collectMemoryMetrics(): Promise<void> {
    try {
      const memoryUsage = await MemoryUtils.getInstance().getAppMemoryUsageMB();
      if (memoryUsage > 0) {
        this.memoryBean.addValue(memoryUsage);
      }
    } catch (error) {
      FTInnerLogger.e(TAG, `Failed to collect memory metrics: ${error}`);
    }
  }

  /**
   * Get battery bean
   */
  public getBatteryBean(): MonitorInfoBean {
    return this.batteryBean;
  }

  /**
   * Get CPU bean
   */
  public getCpuBean(): MonitorInfoBean {
    return this.cpuBean;
  }

  /**
   * Get FPS bean
   */
  public getFpsBean(): MonitorInfoBean {
    return this.fpsBean;
  }

  /**
   * Get memory bean
   */
  public getMemoryBean(): MonitorInfoBean {
    return this.memoryBean;
  }
}
