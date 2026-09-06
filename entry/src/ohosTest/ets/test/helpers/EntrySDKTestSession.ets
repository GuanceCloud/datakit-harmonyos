import { Want } from '@kit.AbilityKit';
import window from '@ohos.window';
import { FTLoggerConfig, FTRUMConfig, FTSDK, FTSDKConfig, FTTraceConfig } from '@guancecloud/ft_sdk/Index';
import {
  setRuntimeDatakitUrlInternal,
  setRuntimeDatawayUrlInternal
} from '@guancecloud/ft_sdk/src/main/ets/components/Configs';
import { FTExceptionHandler } from '@guancecloud/ft_sdk/src/main/ets/components/FTExceptionHandler';
import FTTrackInner from '@guancecloud/ft_sdk/src/main/ets/components/FTTrackInner';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { FTDBTaskPoolExecutor } from '@guancecloud/ft_sdk/src/main/ets/components/db/FTDBTaskPoolExecutor';
import { TrackLogManager } from '@guancecloud/ft_sdk/src/main/ets/components/log/TrackLogManager';
import { FTMonitorManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTMonitorManager';
import { FTRUMConfigManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '@guancecloud/ft_sdk/src/main/ets/components/rum/FTRUMInnerManager';
import { FTTraceConfigManager } from '@guancecloud/ft_sdk/src/main/ets/components/trace/FTTraceConfigManager';
import EntryAbility, { RuntimeConfig } from '../../../../main/ets/entryability/EntryAbility';
import { EntryWaitUtils } from './EntryWaitUtils';

/** Keep the protected test reset out of the Demo's production interfaces. */
class EntrySDKReset extends FTSDK {
  static clear(): void {
    EntrySDKReset.resetInternalState();
  }
}

/**
 * One session spans the complete entry UI-test run. Construct it before the
 * first test Want is applied, then restore it from the runner's finally block.
 * Config objects retain callbacks, proxy/DNS, modifiers, filters and runtime
 * updates that cannot be reconstructed from the Demo's string preferences.
 */
export class EntrySDKTestSession {
  private readonly ability: EntryAbility;
  private readonly runtime: RuntimeConfig;
  private readonly sdkConfig: FTSDKConfig | null;
  private readonly rumConfig: FTRUMConfig | null;
  private readonly logConfig: FTLoggerConfig | null;
  private readonly traceConfig: FTTraceConfig | null;
  private readonly datakitUrl: string;
  private readonly datawayUrl: string;
  private readonly clientToken: string;
  private readonly configAutoSync: boolean;
  private readonly syncAutoSync: boolean;
  private readonly syncStopped: boolean;
  private touched: boolean = false;
  private applied: boolean = false;
  private restored: boolean = false;

  constructor(ability: EntryAbility) {
    this.ability = ability;
    this.runtime = ability.getRuntimeConfigForTest();
    this.sdkConfig = ability.getSDKConfigForTest();
    this.rumConfig = FTSDK.getRumConfig();
    this.logConfig = TrackLogManager.getInstance().getLogConfig();
    this.traceConfig = FTTraceConfigManager.getInstance().getConfig();
    this.datakitUrl = this.sdkConfig === null ? '' : this.sdkConfig.getDatakitUrl();
    this.datawayUrl = this.sdkConfig === null ? '' : this.sdkConfig.getDatawayUrl();
    this.clientToken = this.sdkConfig === null ? '' : this.sdkConfig.getClientToken();
    this.configAutoSync = this.sdkConfig === null ? false : this.sdkConfig.isAutoSyncEnabled();
    const status = SyncTaskManager.getInstance().getStatus();
    this.syncAutoSync = status.autoSync;
    this.syncStopped = status.isStop;
  }

  async apply(want: Want): Promise<void> {
    if (this.restored) {
      throw new Error('Cannot apply a restored Entry SDK test session');
    }
    if (this.applied) {
      return;
    }
    // Mark before awaiting so the runner can restore even after setup fails.
    this.touched = true;
    await this.clearActiveSDK();
    await this.ability.applyRuntimeConfigForTest(want);
    const sync = SyncTaskManager.getInstance();
    sync.resume();
    sync.executeSyncPoll();
    await this.rebindWindowIfNeeded(FTSDK.getRumConfig());
    this.applied = true;
  }

  async restore(): Promise<void> {
    if (this.restored || !this.touched) {
      return;
    }
    await this.clearActiveSDK();
    // Closing test Views may enqueue a final update after a case's cleanup.
    // Drain first, then remove test records before the original endpoint resumes.
    let cleanupFailed = false;
    try {
      // The executor propagates failures; FTDBManager.delete() only logs them.
      await FTDBTaskPoolExecutor.deleteAll(this.ability.context);
    } catch (_error) {
      cleanupFailed = true;
    }
    const sync = SyncTaskManager.getInstance();
    try {
      const sdk = this.sdkConfig;
      if (sdk !== null) {
        // resetInternalState clears endpoint overrides on the discarded SDK.
        // Reapply the captured effective endpoint before installing managers.
        if (this.datawayUrl.length > 0) {
          setRuntimeDatawayUrlInternal(sdk, this.datawayUrl, this.clientToken);
        } else {
          setRuntimeDatakitUrlInternal(sdk, this.datakitUrl);
        }
        sdk.setAutoSync(false);
        FTSDK.install(sdk, this.ability.context);
        if (this.logConfig !== null) {
          FTSDK.installLogConfig(this.logConfig);
        }
        if (this.rumConfig !== null) {
          FTSDK.installRUMConfig(this.rumConfig);
        }
        if (this.traceConfig !== null) {
          FTSDK.installTraceConfig(this.traceConfig);
        }
        await this.rebindWindowIfNeeded(this.rumConfig);
      } else {
        // SyncTaskManager survives the SDK reset. Remove its test endpoint
        // even when there was no installed SDK to restore on this device.
        sync.init(FTSDKConfig.builder().setAutoSync(false), this.ability.context);
      }
    } finally {
      // Restore the original model and demo-visible values even if a UI
      // rebinding failure makes the test runner report restoration failure.
      if (this.sdkConfig !== null) {
        this.sdkConfig.setAutoSync(this.configAutoSync);
      }
      this.ability.restoreRuntimeConfigForTest(this.runtime, this.sdkConfig);
      sync.setAutoSync(this.syncAutoSync);
      if (this.syncStopped || cleanupFailed) {
        sync.stop();
      } else {
        sync.resume();
        sync.executeSyncPoll();
      }
    }
    this.restored = true;
    if (cleanupFailed) {
      throw new Error('Original SDK configuration restored, but test-data cleanup failed; uploads remain paused');
    }
  }

  private async clearActiveSDK(): Promise<void> {
    const sync = SyncTaskManager.getInstance();
    // Changing the manager flag does not mutate the original config object.
    sync.setAutoSync(false);
    const uploadIdle = await EntryWaitUtils.waitUntil(async () => {
      const status = sync.getStatus();
      return !status.running && !status.uploadLaneStatus.isRunning;
    }, 60000, 100);
    if (!uploadIdle) {
      throw new Error('Cannot switch Entry SDK configuration while an upload is still running');
    }
    // stop() clears `running`, so it must follow the actual completion check.
    // It also cancels delayed polls that setAutoSync(false) does not cancel.
    sync.stop();
    FTSDK.cleanupUIFeatures();
    await FTRUMInnerManager.getInstance().shutdown();
    FTSDK.shutDown();
    FTExceptionHandler.release();
    FTMonitorManager.release();
    const track = FTTrackInner.getInstance();
    await track.flushPendingWorkerDataBeforeUpload(10000);
    await track.shutdown();
    TrackLogManager.resetStateInternal();
    FTRUMConfigManager.resetStateInternal();
    FTRUMInnerManager.resetStateInternal();
    FTTrackInner.resetInstanceInternal();
    FTTraceConfigManager.getInstance().reset();
    EntrySDKReset.clear();
  }

  private async rebindWindowIfNeeded(rumConfig: FTRUMConfig | null): Promise<void> {
    if (rumConfig === null || (!rumConfig.isEnableTraceUserAction() &&
      !rumConfig.isEnableTraceUserView() && !rumConfig.isEnableTrackAppANR())) {
      return;
    }
    const mainWindow = await window.getLastWindow(this.ability.context);
    FTSDK.onWindowStageActive(mainWindow);
  }
}
