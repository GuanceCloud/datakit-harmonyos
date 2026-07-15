import { ErrorMonitorType, ERROR_MONITOR_NO_SET } from './enum/ErrorMonitorType';
import { DeviceMetricsMonitorType, DEVICE_METRICS_MONITOR_NO_SET } from './enum/DeviceMetricsMonitorType';
import { MonitorInfoBean } from './bean/MonitorInfoBean';
import { ActiveViewBean } from './bean/ActiveViewBean';
import { FTRUMConfig } from '../Configs';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';
import { FpsUtils } from '../utils/FpsUtils';
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
const METRICS_COLLECTION_INTERVAL_MS = 2000;
const CPU_CACHE_INTERVAL_MS = 5000;
const MEMORY_CACHE_INTERVAL_MS = 3000;

export class FTMonitorManager {
  private static instance: FTMonitorManager | null = null;
  private static readonly ONE_SECOND_NANO_TIMES = 1000000000;

  private errorMonitorType: number = ERROR_MONITOR_NO_SET;
  private deviceMetricsMonitorType: number = DEVICE_METRICS_MONITOR_NO_SET;
  private runnerMap: Map<string, MonitorRunnable> = new Map();
  private isTVDevice: boolean = false;

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
    this.isTVDevice = false;

    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.CPU)) {
      FTInnerLogger.d(TAG, 'CPU monitoring delegated to DataProcessWorker with 5s cache');
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.MEMORY)) {
      FTInnerLogger.d(TAG, 'Memory monitoring delegated to DataProcessWorker with 3s cache');
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.BATTERY)) {
      FTInnerLogger.d(TAG, 'Battery monitoring delegated to DataProcessWorker');
    }
    if (this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)) {
      try {
        await FpsUtils.getInstance().init();
        FpsUtils.getInstance().start();
        FTInnerLogger.d(TAG, 'FPS monitoring initialized and started');
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
    FTInnerLogger.d(TAG, `addMonitor: ${viewId}, remain count: ${this.runnerMap.size}`);
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
      this.isDeviceMetricsMonitorType(DeviceMetricsMonitorType.FPS)
    );
    this.runnerMap.set(viewId, runner);
    runner.start();
  }

  public attachMonitorData(bean: ActiveViewBean): void {
    if (this.deviceMetricsMonitorType === DEVICE_METRICS_MONITOR_NO_SET) {
      return;
    }
    const runner = this.runnerMap.get(bean.getId());
    if (!runner) {
      return;
    }

    const battery = runner.getBatteryBean();
    if (battery.isValid()) {
      bean.setBatteryCurrentMax(Math.floor(battery.maxValue));
      bean.setBatteryCurrentAvg(Math.floor(battery.avgValue));
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
    FTMonitorManager.instance = null;
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
  private isCollecting: boolean = false;
  private readonly collectCpu: boolean;
  private readonly collectMemory: boolean;
  private readonly collectBattery: boolean;
  private readonly collectFps: boolean;

  constructor(collectCpu: boolean, collectMemory: boolean, collectBattery: boolean, collectFps: boolean) {
    this.collectCpu = collectCpu;
    this.collectMemory = collectMemory;
    this.collectBattery = collectBattery;
    this.collectFps = collectFps;
  }

  public start(): void {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;
    this.intervalId = setInterval(() => {
      this.collectMetrics();
    }, METRICS_COLLECTION_INTERVAL_MS) as number;
  }

  public stop(): void {
    this.isRunning = false;
    if (this.intervalId !== null) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  private collectMetrics(): void {
    if (!this.isRunning) {
      return;
    }
    this.collectFpsMetric();
    if (this.isCollecting) {
      return;
    }
    this.isCollecting = true;
    this.collectMetricsAsync().finally(() => {
      this.isCollecting = false;
    });
  }

  private async collectMetricsAsync(): Promise<void> {
    if (!this.collectCpu && !this.collectMemory && !this.collectBattery) {
      return;
    }
    MonitorRunnable.commandSequence++;
    const payload: SDKBackgroundMetricsRequestDTO = {
      collectCpu: this.collectCpu,
      collectMemory: this.collectMemory,
      collectBattery: this.collectBattery,
      cpuCacheMs: CPU_CACHE_INTERVAL_MS,
      memoryCacheMs: MEMORY_CACHE_INTERVAL_MS
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
      if (!this.isRunning) {
        return;
      }
      this.applyBackgroundMetrics(response.payload as Object as SDKBackgroundMetricsResultDTO);
    } catch (error) {
      FTInnerLogger.w(TAG, `Background metrics collection failed: ${String(error)}`);
    }
  }

  private applyBackgroundMetrics(metrics: SDKBackgroundMetricsResultDTO): void {
    if (metrics.batteryCurrent > 0) {
      this.batteryBean.addValue(metrics.batteryCurrent);
    }
    if (metrics.cpuTickCount > 0) {
      this.cpuBean.addValue(metrics.cpuTickCount);
    }
    if (metrics.memoryUsageMB > 0) {
      this.memoryBean.addValue(metrics.memoryUsageMB);
    }
  }

  private collectFpsMetric(): void {
    if (!this.collectFps) {
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
}
