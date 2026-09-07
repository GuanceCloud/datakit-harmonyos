import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import {
  FTSDKAnrManager,
  FTSDKRuntime
} from '../../../main/ets/components/internal/runtime/FTSDKRuntime';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTAppStartCounter } from '../../../main/ets/components/monitor/FTAppStartCounter';
import { FTActionTrackingHandler } from '../../../main/ets/components/rum/handler/FTActionTrackingHandler';
import { ActionEventWrapper } from '../../../main/ets/components/rum/bean/ActionEventWrapper';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { DBAssert } from './helpers/DBAssert';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';

class DeviceLifecycleAnrManager implements FTSDKAnrManager {
  initializeCount: number = 0;
  startMonitoringCount: number = 0;
  shutdownCount: number = 0;

  initialize(): void {
    this.initializeCount++;
  }

  startMonitoring(): boolean {
    this.startMonitoringCount++;
    return true;
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class DeviceLifecycleUIContext {
}

interface DeviceApplicationStateCallback {
  onApplicationForeground: () => void;
  onApplicationBackground: () => void;
}

class DeviceProcessInformation {
  public state: number;

  constructor(state: number) {
    this.state = state;
  }
}

/**
 * Captures the same application-state subscription that AbilityStage installs,
 * while the test still uses the device's actual RDB and Worker pipeline.
 */
class DeviceLaunchApplicationContext {
  private stateCallback: DeviceApplicationStateCallback | null = null;

  public getRunningProcessInformation(): Promise<Array<DeviceProcessInformation>> {
    // appManager.ProcessState.FOREGROUND
    return Promise.resolve([new DeviceProcessInformation(1)]);
  }

  public on(type: string, callback: DeviceApplicationStateCallback): void {
    if (type === 'applicationStateChange') {
      this.stateCallback = callback;
    }
  }

  public off(type: string, callback?: DeviceApplicationStateCallback): void {
    if (type === 'applicationStateChange' && (!callback || callback === this.stateCallback)) {
      this.stateCallback = null;
    }
  }

  public emitForeground(): void {
    this.stateCallback?.onApplicationForeground();
  }
}

class DeviceLaunchStageContext {
  private readonly applicationContext: DeviceLaunchApplicationContext;

  constructor(applicationContext: DeviceLaunchApplicationContext) {
    this.applicationContext = applicationContext;
  }

  public getApplicationContext(): Object {
    return this.applicationContext;
  }
}

/** A rejecting automatic Action handler must not affect SDK-owned launch Actions. */
class RejectAllAutomaticActionsHandler implements FTActionTrackingHandler {
  public invocationCount: number = 0;

  public resolveHandlerAction(_actionEventWrapper: ActionEventWrapper): null {
    this.invocationCount++;
    return null;
  }
}

class DeviceLifecycleRuntime implements FTSDKRuntime {
  abilityContext: common.UIAbilityContext | null = null;
  uiContext: UIContext | null = new DeviceLifecycleUIContext() as Object as UIContext;
  anrManager: DeviceLifecycleAnrManager = new DeviceLifecycleAnrManager();
  registerLifecycleListenerCount: number = 0;
  setMainWindowCount: number = 0;
  initActionTrackerCount: number = 0;
  destroyActionTrackerCount: number = 0;
  initNavigationTrackerCount: number = 0;
  destroyNavigationTrackerCount: number = 0;

  initUtils(context: common.UIAbilityContext): void {
    this.abilityContext = context;
  }

  getAbilityContext(): common.UIAbilityContext | null {
    return this.abilityContext;
  }

  initSyncTaskManager(_config: FTSDKConfig, _context: Context): void {
  }

  registerLifecycleListener(): void {
    this.registerLifecycleListenerCount++;
  }

  getAnrDetectManager(): FTSDKAnrManager | null {
    return this.anrManager;
  }

  initExceptionHandler(_config: FTRUMConfig): void {
  }

  startUIBlockManager(_config: FTRUMConfig): void {
  }

  setMainWindow(_mainWindow?: window.Window): void {
    this.setMainWindowCount++;
  }

  getUIContext(): UIContext | null {
    return this.uiContext;
  }

  initActionTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.initActionTrackerCount++;
  }

  destroyActionTracker(): void {
    this.destroyActionTrackerCount++;
  }

  initNavigationTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
    this.initNavigationTrackerCount++;
  }

  destroyNavigationTracker(): void {
    this.destroyNavigationTrackerCount++;
  }
}

export default function ftSDKLifecycleDeviceTest() {
  describe('FTSDKLifecycleDeviceTest', () => {
    let context: Context;

    beforeEach(async () => {
      SdkInternalTestAccess.resetRuntime();
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      await DBAssert.resetAll();
    });

    afterEach(async () => {
      SdkInternalTestAccess.resetRuntime();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.cleanupAll();
      SdkInternalTestAccess.resetRuntime();
    });

    it('beforeInstallCallsShouldNoOp', 0, async () => {
      FTSDK.flushSyncData();
      await FTSDK.clearAllData();

      const stayedEmpty = await DBAssert.waitForSyncCount([
        DataType.LOG,
        DataType.RUM_APP,
        DataType.RUM_WEBVIEW
      ], 0, 1000);

      expect(stayedEmpty).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG, DataType.RUM_APP, DataType.RUM_WEBVIEW])).assertEqual(0);
    });

    it('rumWithoutAppIdIgnorePublicRumCalls', 0, async () => {
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig());

      await FTRUMGlobalManager.getInstance().startView('rum_no_app_id_view');
      FTRUMGlobalManager.getInstance().addAction('rum_no_app_id_action', 'click');
      await FTRUMGlobalManager.getInstance().stopView();
      await WaitUtils.delay(300);

      expect(await DBAssert.querySyncCount([DataType.RUM_APP])).assertEqual(0);
      expect((await DBAssert.queryViews(10)).length).assertEqual(0);
      expect((await DBAssert.queryActions(10)).length).assertEqual(0);
    });

    it('cleanupUiShouldAllowReinit', 0, async () => {
      const runtime = new DeviceLifecycleRuntime();
      SdkInternalTestAccess.setRuntime(runtime);

      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserView(true)
        .setEnableTrackAppANR(true));

      expect(runtime.registerLifecycleListenerCount).assertEqual(1);
      expect(runtime.setMainWindowCount).assertEqual(1);
      expect(runtime.initActionTrackerCount).assertEqual(1);
      expect(runtime.initNavigationTrackerCount).assertEqual(1);
      expect(runtime.anrManager.initializeCount).assertEqual(1);
      expect(runtime.anrManager.startMonitoringCount).assertEqual(1);

      FTSDK.cleanupUIFeatures();

      expect(runtime.destroyActionTrackerCount).assertEqual(1);
      expect(runtime.destroyNavigationTrackerCount).assertEqual(1);
      expect(runtime.anrManager.shutdownCount).assertEqual(1);

      FTSDK.onWindowStageActive();

      expect(runtime.setMainWindowCount).assertEqual(2);
      expect(runtime.initActionTrackerCount).assertEqual(2);
      expect(runtime.initNavigationTrackerCount).assertEqual(2);
      expect(runtime.anrManager.initializeCount).assertEqual(2);
      expect(runtime.anrManager.startMonitoringCount).assertEqual(2);
    });

    it('foregroundColdLaunchIgnoreActionHandler', 0, async () => {
      const actionHandler = new RejectAllAutomaticActionsHandler();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true)
        .setActionTrackingHandler(actionHandler));

      const applicationContext = new DeviceLaunchApplicationContext();
      const stageContext = new DeviceLaunchStageContext(applicationContext);
      FTSDK.recordAppApplicationInit(stageContext);

      // Let the two-turn initial-lifecycle barrier settle before the first
      // UIAbility. The foreground snapshot must keep this cold launch pending.
      await WaitUtils.delay(30);
      applicationContext.emitForeground();
      FTSDK.recordAppFirstUIAbilityCreate();
      FTSDK.recordAppLaunchWindowForeground();
      await WaitUtils.delay(5);
      FTSDK.recordAppFirstFrame();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action_type=launch_cold',
        'app_launch_type="foreground"'
      ]);
      expect(record !== null).assertTrue();
      // FTActionTrackingHandler only handles automatic input Actions. It must
      // neither receive nor filter the SDK-owned launch_cold Action.
      expect(actionHandler.invocationCount).assertEqual(0);
    });

    it('hotStartNotPersistColdLaunchTypeField', 0, async () => {
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true));

      FTAppStartCounter.getInstance().hotStart(1_000_000, Date.now() * 1_000_000);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action_type=launch_hot'
      ]);
      expect(record !== null).assertTrue();
      expect(record!.getDataString().includes('app_launch_type')).assertFalse();
    });
  });
}
