import { AppServiceExtensionAbility, Want } from '@kit.AbilityKit';
import rpc from "@ohos.rpc";
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import {
  createDefaultStressTestConfig,
  StressTestConfig,
  StressTestManager,
  StressTrafficMode
} from '../utils/StressTestManager';
import { DemoLogger } from '../utils/DemoLogger';
import {
  markStressServiceError,
  markStressServiceEvent,
  STRESS_SERVICE_STATE_DESTROYED,
  STRESS_SERVICE_STATE_KEEPALIVE,
  STRESS_SERVICE_STATE_STARTED,
  STRESS_SERVICE_STATE_STOPPED,
  STRESS_SERVICE_STATE_STOPPING
} from '../utils/StressServiceStatusStore';
import { initializeDemoColdLaunchRum } from '../utils/DemoColdLaunchRumInitializer';

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
    // AppService may be the only Ability created by a cold process. Reuse the
    // same T1/state snapshot hook and bootstrap RUM from persisted/Want config.
    FTSDK.recordAppApplicationInit(this.context);
    initializeDemoColdLaunchRum(this.context, 'StressServiceAbility', want);
    markStressServiceEvent(STRESS_SERVICE_STATE_STARTED, 'onCreate');
    this.handleRequest(want, 0);
  }

  onDestroy(): void {
    DemoLogger.i(TAG, "StressServiceAbility onDestroy");
    markStressServiceEvent(STRESS_SERVICE_STATE_DESTROYED, 'onDestroy', -1, 'service-destroyed');
    this.stressTestManager.stop('service-destroyed');
  }

  onRequest(want: Want, startId: number): void {
    DemoLogger.i(TAG, `StressServiceAbility onRequest, startId: ${startId}`);
    markStressServiceEvent(STRESS_SERVICE_STATE_STARTED, 'onRequest', startId);
    this.handleRequest(want, startId);
  }

  onConnect(want: Want): rpc.RemoteObject {
    DemoLogger.i(TAG, "StressServiceAbility onConnect");
    markStressServiceEvent(STRESS_SERVICE_STATE_STARTED, 'onConnect');
    return new StressServiceAbilityStub('stress-service');
  }

  onDisconnect(want: Want): void {
    DemoLogger.i(TAG, "StressServiceAbility onDisconnect");
    markStressServiceEvent(STRESS_SERVICE_STATE_STARTED, 'onDisconnect');
  }

  private handleRequest(want: Want, startId: number): void {
    const action = this.resolveAction(want);
    if (action === 'stop') {
      DemoLogger.i(TAG, "Received stop command");
      markStressServiceEvent(STRESS_SERVICE_STATE_STOPPING, 'stop command', startId, 'service-stop');
      this.stressTestManager.stop('service-stop');
      markStressServiceEvent(STRESS_SERVICE_STATE_STOPPED, 'service-stop', startId, 'service-stop');
      return;
    }

    if (action === 'keepalive') {
      DemoLogger.i(TAG, "Received keepalive command");
      markStressServiceEvent(STRESS_SERVICE_STATE_KEEPALIVE, 'keepalive', startId);
      return;
    }

    if (action !== 'start') {
      DemoLogger.w(TAG, `Unknown service action=${action}, startId=${startId}`);
      markStressServiceError('unknown action', `Unknown service action=${action}`, startId);
      return;
    }

    if (this.stressTestManager.isStressTestRunning()) {
      DemoLogger.w(TAG, "Stress test already running, ignoring service start command");
      markStressServiceEvent(STRESS_SERVICE_STATE_KEEPALIVE, 'start ignored: already running', startId);
      return;
    }

    const config = this.readConfig(want);
    DemoLogger.i(TAG,
      `Starting background stress test: duration=${config.durationSeconds}s, traffic=${config.trafficMode}, logs=${config.enableLogs}, actions=${config.enableActions}, resources=${config.enableResources}, navigation=${config.enableNavigation}, navigationInterval=${config.navigationIntervalMs}, errors=${config.enableErrors}, longTasks=${config.enableLongTasks}`);
    this.stressTestManager.runWithConfig(config);
    markStressServiceEvent(STRESS_SERVICE_STATE_STARTED, 'start command', startId);
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
    config.navigationIntervalMs = this.readNumber(want, 'navigationIntervalMs', config.navigationIntervalMs);
    config.errorBatchSize = this.readNumber(want, 'errorBatchSize', config.errorBatchSize);
    config.errorIntervalMs = this.readNumber(want, 'errorIntervalMs', config.errorIntervalMs);
    config.longTaskBatchSize = this.readNumber(want, 'longTaskBatchSize', config.longTaskBatchSize);
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
