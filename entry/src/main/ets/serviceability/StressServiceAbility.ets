import { AppServiceExtensionAbility, Want } from '@kit.AbilityKit';
import rpc from "@ohos.rpc";
import {
  createDefaultStressTestConfig,
  StressTestConfig,
  StressTestManager,
  StressTrafficMode
} from '../utils/StressTestManager';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "StressServiceAbility";

class StressServiceAbilityStub extends rpc.RemoteObject {
  constructor(des: string | object) {
    if (typeof des === 'string') {
      super(des);
    } else {
      return;
    }
  }
}

/**
 * AppService extension for keeping stress scenarios alive when the page moves away.
 */
export default class StressServiceAbility extends AppServiceExtensionAbility {
  private stressTestManager: StressTestManager = StressTestManager.getInstance();

  onCreate(want: Want): void {
    DemoLogger.i(TAG, "StressServiceAbility onCreate");
    this.handleRequest(want, 0);
  }

  onDestroy(): void {
    DemoLogger.i(TAG, "StressServiceAbility onDestroy");
    this.stressTestManager.stop('service-destroyed');
  }

  onRequest(want: Want, startId: number): void {
    DemoLogger.i(TAG, `StressServiceAbility onRequest, startId: ${startId}`);
    this.handleRequest(want, startId);
  }

  onConnect(want: Want): rpc.RemoteObject {
    DemoLogger.i(TAG, "StressServiceAbility onConnect");
    return new StressServiceAbilityStub('stress-service');
  }

  onDisconnect(want: Want): void {
    DemoLogger.i(TAG, "StressServiceAbility onDisconnect");
  }

  private handleRequest(want: Want, startId: number): void {
    const action = this.resolveAction(want);
    if (action === 'stop') {
      DemoLogger.i(TAG, "Received stop command");
      this.stressTestManager.stop('service-stop');
      return;
    }

    if (action === 'keepalive') {
      DemoLogger.i(TAG, "Received keepalive command");
      return;
    }

    if (action !== 'start') {
      DemoLogger.w(TAG, `Unknown service action=${action}, startId=${startId}`);
      return;
    }

    if (this.stressTestManager.isStressTestRunning()) {
      DemoLogger.w(TAG, "Stress test already running, ignoring service start command");
      return;
    }

    const config = this.readConfig(want);
    DemoLogger.i(TAG,
      `Starting background stress test: duration=${config.durationSeconds}s, traffic=${config.trafficMode}, logs=${config.enableLogs}, actions=${config.enableActions}, resources=${config.enableResources}, navigation=${config.enableNavigation}, errors=${config.enableErrors}, longTasks=${config.enableLongTasks}`);
    this.stressTestManager.runWithConfig(config);
  }

  private resolveAction(want: Want): string {
    const parameterAction = this.readString(want, 'action', '');
    if (parameterAction.length > 0) {
      return parameterAction;
    }
    const wantAction = want.action ?? '';
    return wantAction.length > 0 ? wantAction : 'start';
  }

  private readConfig(want: Want): StressTestConfig {
    const trafficModeParam = this.readString(want, 'trafficMode', 'fake');
    const trafficMode: StressTrafficMode = trafficModeParam === 'real' ? 'real' : 'fake';
    const config = createDefaultStressTestConfig(
      this.readNumber(want, 'durationSeconds', 60),
      trafficMode === 'real',
      'background-service'
    );

    config.enableLogs = this.readBoolean(want, 'enableLogs', true);
    config.enableActions = this.readBoolean(want, 'enableActions', true);
    config.enableResources = this.readBoolean(want, 'enableResources', true);
    config.enableNavigation = this.readBoolean(want, 'enableNavigation', true);
    config.enableErrors = this.readBoolean(want, 'enableErrors', false);
    config.enableLongTasks = this.readBoolean(want, 'enableLongTasks', false);
    config.logThreadCount = this.readNumber(want, 'logThreadCount', config.logThreadCount);
    config.logTotalCount = this.readNumber(want, 'logTotalCount', config.logTotalCount);
    config.logBatchSize = this.readNumber(want, 'logBatchSize', config.logBatchSize);
    config.logIntervalMs = this.readNumber(want, 'logIntervalMs', config.logIntervalMs);
    config.actionThreadCount = this.readNumber(want, 'actionThreadCount', config.actionThreadCount);
    config.actionIntervalMs = this.readNumber(want, 'actionIntervalMs', config.actionIntervalMs);
    config.resourceThreadCount = this.readNumber(want, 'resourceThreadCount', config.resourceThreadCount);
    config.resourceIntervalMs = this.readNumber(want, 'resourceIntervalMs', config.resourceIntervalMs);
    config.realResourceUrl = this.readString(want, 'realResourceUrl', config.realResourceUrl).trim();
    config.errorIntervalMs = this.readNumber(want, 'errorIntervalMs', config.errorIntervalMs);
    config.longTaskIntervalMs = this.readNumber(want, 'longTaskIntervalMs', config.longTaskIntervalMs);
    return config;
  }

  private readString(want: Want, key: string, defaultValue: string): string {
    const value = want.parameters?.[key];
    if (value === null || value === undefined) {
      return defaultValue;
    }
    return String(value);
  }

  private readNumber(want: Want, key: string, defaultValue: number): number {
    const value = want.parameters?.[key];
    if (value === null || value === undefined) {
      return defaultValue;
    }

    const numberValue = Number(value);
    return isNaN(numberValue) ? defaultValue : numberValue;
  }

  private readBoolean(want: Want, key: string, defaultValue: boolean): boolean {
    const value = want.parameters?.[key];
    if (value === null || value === undefined) {
      return defaultValue;
    }
    if (typeof value === 'boolean') {
      return value;
    }
    const text = String(value).toLowerCase();
    return text === 'true' || text === '1' || text === 'on';
  }
}
