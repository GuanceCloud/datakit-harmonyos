import { ErrorMonitorType, ERROR_MONITOR_NO_SET } from './enum/ErrorMonitorType';
import { DeviceMetricsMonitorType, DEVICE_METRICS_MONITOR_NO_SET } from './enum/DeviceMetricsMonitorType';
import { MonitorInfoBean } from './bean/MonitorInfoBean';
import { ActiveViewBean } from './bean/ActiveViewBean';
import { FTRUMConfig } from '../Configs';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';
import { FpsUtils } from '../utils/FpsUtils';
import { Constants } from '../Constants';
import { FTSessionReplayBridgeRegistry } from '../sessionreplay/FTSessionReplayBridge';
import { DetectFrequency } from '../enum/Enums';
import { batteryInfo } from '@kit.BasicServicesKit';
import { DeviceUtils } from '../utils/DeviceUtils';
import { SDKDedicatedPoolManager } from '../thread/SDKDedicatedPoolManager';
import {
  SDKBackgroundMetricsRequestDTO,
  SDKBackgroundMetricsResultDTO,
  SDKDedicatedPoolType,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest
} from '../thread/SDKWorkerProtocol';

const TAG = 'FTMonitorManager';
const MIN_METRICS_COLLECTION_INTERVAL_MS = 100;
const MAX_METRICS_COLLECTION_INTERVAL_MS = 60000;

/** Keeps scalar monitor values compatible with the SDK's object-only property API. */
class ErrorMonitorValue {
  public value: string;

  constructor(value: number) {
    this.value = String(value);
  }
}

export class FTMonitorManager {
  private static instance: FTMonitorManager | null = null;
  private static readonly ONE_SECOND_NANO_TIMES = 1000000000;

  private errorMonitorType: number = ERROR_MONITOR_NO_SET;
  private deviceMetricsMonitorType: number = DEVICE_METRICS_MONITOR_NO_SET;
  private metricsCollectionIntervalMs: number = DetectFrequency.DEFAULT;
  private runnerMap: Map<string, MonitorRunnable> = new Map();
  private isTVDevice: boolean = false;
  private isAppInForeground: boolean = true;
  private foregroundGeneration: number = 0;

  private constructor() {}

  public static getInstance(): FTMonitorManager {
    if (!FTMonitorManager.instance) {
      FTMonitorManager.instance = new FTMonitorManager();
    }
    return FTMonitorManager.instance;
  }

  public async initWithConfig(config: FTRUMConfig): Promise<void> {
    this.errorMonitorType = config.getExtraMonitorTypeWithError();
    this.deviceMetricsMonitorType = config.getDeviceMetricsMonitorType();
    this.metricsCollectionIntervalMs = this.normalizeMetricsCollectionInterval(
      config.getDeviceMetricsDetectFrequency()
    );
    this.isTVDevice = false;

    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)) {
      FTInnerLogger.d(TAG, `CPU monitoring interval=${this.metricsCollectionIntervalMs}ms`);
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)) {
      FTInnerLogger.d(TAG, `Memory monitoring interval=${this.metricsCollectionIntervalMs}ms`);
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)) {
      FTInnerLogger.d(TAG, `Battery monitoring interval=${this.metricsCollectionIntervalMs}ms`);
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
      try {
        const fpsUtils = FpsUtils.getInstance();
        await fpsUtils.init();
        if (fpsUtils.start()) {
          FTInnerLogger.d(TAG, 'FPS monitoring ready');
        }
      } catch (error) {
        FTInnerLogger.e(TAG, `Failed to initialize FPS monitoring: ${String(error)}`);
      }
    }
  }

  public isErrorMonitorType(errorMonitorType: ErrorMonitorType): boolean {
    if (this.isTVDevice && errorMonitorType === ErrorMonitorType.BATTERY) {
      return false;
    }
    return ((this.errorMonitorType & errorMonitorType) >>> 0) === (errorMonitorType >>> 0);
  }

  public isDeviceMetricsMonitorType(deviceMetricsMonitorType: DeviceMetricsMonitorType): boolean {
    if (this.isTVDevice && deviceMetricsMonitorType === DeviceMetricsMonitorType.BATTERY) {
      return false;
    }
    return ((this.deviceMetricsMonitorType & deviceMetricsMonitorType) >>> 0) ===
      (deviceMetricsMonitorType >>> 0);
  }

  public addMonitor(viewId: string): void {
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    const existing = this.runnerMap.get(viewId);
    if (existing) {
      existing.stop();
    }
    const runner = new MonitorRunnable(
      this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU),
      this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY),
      this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY),
      this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS),
      this.metricsCollectionIntervalMs,
      () => this.getForegroundGeneration()
    );
    this.runnerMap.set(viewId, runner);
    runner.start();
  }

  public async attachMonitorData(bean: ActiveViewBean, logSummary: boolean = true): Promise<void> {
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    const runner = this.runnerMap.get(bean.getId());
    if (!runner) {
      return;
    }

    await runner.collectSnapshot();

    const battery = runner.getBatteryBean();
    if (battery.isValid()) {
      bean.setBatteryCurrentMax(Math.trunc(battery.maxValue));
      bean.setBatteryCurrentAvg(Math.trunc(battery.avgValue));
    }

    const cpu = runner.getCpuBean();
    if (cpu.isValid() && cpu.maxValue > 0) {
      const tickCount = Math.floor(cpu.maxValue - cpu.miniValue);
      bean.setCpuTickCount(tickCount);
      const duration = Utils.getCurrentNanoTime() - bean.getStartTime();
      if (duration > 0) {
        bean.setCpuTickCountPerSecond((tickCount * FTMonitorManager.ONE_SECOND_NANO_TIMES) / duration);
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

    // Emit a single closing summary in debug mode. This confirms whether a
    // missing View field originated in collection or later serialization,
    // without reintroducing per-sample FPS log noise.
    if (logSummary) {
      FTInnerLogger.d(
        TAG,
        `View metrics attached: viewId=${bean.getId()}, cpuSamples=${cpu.count}, ` +
        `fpsSamples=${fps.count}, memorySamples=${memory.count}, batterySamples=${battery.count}, ` +
        `workerFailures=${runner.getBackgroundMetricsFailureCount()}`
      );
    }
  }

  /**
   * Lifecycle-driven foreground gate for View-scoped device metrics.
   * A monotonically increasing generation also invalidates a Worker response
   * that was requested before an intervening background transition.
   */
  public setAppInForeground(isForeground: boolean): void {
    FTSessionReplayBridgeRegistry.setWebReplayAppForeground(isForeground);
    if (this.isAppInForeground === isForeground) {
      return;
    }
    this.isAppInForeground = isForeground;
    this.foregroundGeneration++;
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
      if (isForeground) {
        FpsUtils.getInstance().start();
      } else {
        FpsUtils.getInstance().stop();
      }
    }
    if (isForeground) {
      this.runnerMap.forEach((runner) => {
        runner.resumeInForeground();
      });
    }
  }

  private getForegroundGeneration(): number {
    return this.isAppInForeground ? this.foregroundGeneration : -1;
  }

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

  public static release(): void {
    if (!FTMonitorManager.instance) {
      return;
    }
    FTMonitorManager.instance.runnerMap.forEach((runner) => {
      runner.stop();
    });
    FTMonitorManager.instance.runnerMap.clear();
    void FpsUtils.getInstance().release();
    FTMonitorManager.instance = null;
  }

  /** Capture the Android-compatible auxiliary fields appended to RUM errors. */
  public getErrorMonitorData(): Record<string, object> {
    const fields: Record<string, object> = {};

    if (this.isErrorMonitorType(ErrorMonitorType.CPU)) {
      try {
        const cpuUse = DeviceUtils.getCpuUsage();
        if (Number.isFinite(cpuUse)) {
          fields[Constants.KEY_CPU_USE] = new ErrorMonitorValue(cpuUse);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to capture error CPU usage: ${String(error)}`);
      }
    }

    if (this.isErrorMonitorType(ErrorMonitorType.MEMORY)) {
      try {
        const memoryUse = DeviceUtils.getMemoryUsagePercent();
        if (Number.isFinite(memoryUse) && memoryUse >= 0) {
          fields[Constants.KEY_MEMORY_USE] = new ErrorMonitorValue(memoryUse);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to capture error memory usage: ${String(error)}`);
      }
    }

    if (this.isErrorMonitorType(ErrorMonitorType.BATTERY)) {
      try {
        const batteryUse = DeviceUtils.getBatteryUsagePercent(batteryInfo.batterySOC);
        if (Number.isFinite(batteryUse) && batteryUse >= 0) {
          fields[Constants.KEY_BATTERY_USE] = new ErrorMonitorValue(batteryUse);
        }
      } catch (error) {
        FTInnerLogger.w(TAG, `Failed to capture error battery level: ${String(error)}`);
      }
    }

    return fields;
  }

  private normalizeMetricsCollectionInterval(value: DetectFrequency): number {
    const interval = Number(value);
    if (!Number.isFinite(interval) || interval <= 0) {
      return DetectFrequency.DEFAULT;
    }
    return Math.max(
      MIN_METRICS_COLLECTION_INTERVAL_MS,
      Math.min(MAX_METRICS_COLLECTION_INTERVAL_MS, Math.floor(interval))
    );
  }
}

class MonitorRunnable {
  private static commandSequence: number = 0;

  private batteryBean: MonitorInfoBean = new MonitorInfoBean();
  private cpuBean: MonitorInfoBean = new MonitorInfoBean();
  private fpsBean: MonitorInfoBean = new MonitorInfoBean();
  private memoryBean: MonitorInfoBean = new MonitorInfoBean();
  private intervalId: number | null = null;
  private isRunning: boolean = false;
  private collectionPromise: Promise<void> | null = null;
  private readonly collectCpu: boolean;
  private readonly collectMemory: boolean;
  private readonly collectBattery: boolean;
  private readonly collectFps: boolean;
  private readonly collectionIntervalMs: number;
  private readonly getForegroundGeneration: () => number;
  private backgroundMetricsFailureCount: number = 0;

  constructor(
    collectCpu: boolean,
    collectMemory: boolean,
    collectBattery: boolean,
    collectFps: boolean,
    collectionIntervalMs: number,
    getForegroundGeneration: () => number
  ) {
    this.collectCpu = collectCpu;
    this.collectMemory = collectMemory;
    this.collectBattery = collectBattery;
    this.collectFps = collectFps;
    this.collectionIntervalMs = collectionIntervalMs;
    this.getForegroundGeneration = getForegroundGeneration;
  }

  public start(): void {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;
    this.collectMetrics();
    this.intervalId = setInterval(() => {
      this.collectMetrics();
    }, this.collectionIntervalMs) as number;
  }

  public stop(): void {
    this.isRunning = false;
    if (this.intervalId !== null) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  public resumeInForeground(): void {
    if (this.isRunning) {
      this.collectMetrics();
    }
  }

  private collectMetrics(): void {
    if (!this.isRunning || this.getForegroundGeneration() < 0) {
      return;
    }
    this.collectFpsMetric();
    void this.collectBackgroundMetrics(false);
  }

  public async collectSnapshot(): Promise<void> {
    if (this.getForegroundGeneration() < 0) {
      return;
    }
    await this.collectBackgroundMetrics(true);
    this.collectFpsMetric();
  }

  private async collectBackgroundMetrics(force: boolean): Promise<void> {
    if (this.collectionPromise !== null) {
      await this.collectionPromise;
    }
    if ((!this.isRunning && !force) || this.getForegroundGeneration() < 0) {
      return;
    }
    const foregroundGeneration = this.getForegroundGeneration();
    const collection = this.collectBackgroundMetricsOnce(foregroundGeneration);
    this.collectionPromise = collection;
    try {
      await collection;
    } finally {
      if (this.collectionPromise === collection) {
        this.collectionPromise = null;
      }
    }
  }

  private async collectBackgroundMetricsOnce(foregroundGeneration: number): Promise<void> {
    if ((!this.collectCpu && !this.collectMemory && !this.collectBattery) || foregroundGeneration < 0) {
      return;
    }
    MonitorRunnable.commandSequence++;
    const payload: SDKBackgroundMetricsRequestDTO = {
      collectCpu: this.collectCpu,
      collectMemory: this.collectMemory,
      collectBattery: this.collectBattery,
      cpuCacheMs: 0,
      memoryCacheMs: 0
    };
    const request: SDKWorkerRequest = {
      id: `${SDKWorkerCommand.BACKGROUND_COLLECT_METRICS}:${Date.now()}:${MonitorRunnable.commandSequence}`,
      pool: SDKDedicatedPoolType.DATA_PROCESS,
      command: SDKWorkerCommand.BACKGROUND_COLLECT_METRICS,
      priority: SDKTaskPriority.BACKGROUND,
      createdAt: Date.now(),
      payload: payload as Object as SDKWorkerPayload
    };
    try {
      const response = await SDKDedicatedPoolManager.getInstance().executeCommand(request);
      if (!response.ok || !response.payload) {
        throw new Error(response.errorMessage || 'DataProcessWorker returned an empty metrics response');
      }
      if (foregroundGeneration !== this.getForegroundGeneration()) {
        return;
      }
      this.applyBackgroundMetrics(response.payload as Object as SDKBackgroundMetricsResultDTO);
    } catch (error) {
      this.backgroundMetricsFailureCount++;
      if (this.backgroundMetricsFailureCount === 1 || this.backgroundMetricsFailureCount % 10 === 0) {
        FTInnerLogger.w(
          TAG,
          `Background metrics collection failed (${this.backgroundMetricsFailureCount}): ${String(error)}`
        );
      }
    }
  }

  private applyBackgroundMetrics(metrics: SDKBackgroundMetricsResultDTO): void {
    if (metrics.hasBatteryCurrent && Number.isFinite(metrics.batteryCurrent)) {
      this.batteryBean.addBatteryCurrentValue(metrics.batteryCurrent);
    }
    if (Number.isFinite(metrics.cpuTickCount) && metrics.cpuTickCount >= 0) {
      this.cpuBean.addValue(metrics.cpuTickCount);
    }
    if (Number.isFinite(metrics.memoryUsageBytes) && metrics.memoryUsageBytes >= 0) {
      this.memoryBean.addValue(metrics.memoryUsageBytes);
    }
  }

  private collectFpsMetric(): void {
    if (!this.collectFps || this.getForegroundGeneration() < 0) {
      return;
    }
    try {
      const fps = FpsUtils.getInstance().getFps();
      if (fps > 0) {
        this.fpsBean.addValue(fps);
      }
    } catch (error) {
      FTInnerLogger.w(TAG, `Failed to collect FPS metrics: ${String(error)}`);
    }
  }

  public getBatteryBean(): MonitorInfoBean {
    return this.batteryBean;
  }

  public getCpuBean(): MonitorInfoBean {
    return this.cpuBean;
  }

  public getFpsBean(): MonitorInfoBean {
    return this.fpsBean;
  }

  public getMemoryBean(): MonitorInfoBean {
    return this.memoryBean;
  }

  public getBackgroundMetricsFailureCount(): number {
    return this.backgroundMetricsFailureCount;
  }
}
