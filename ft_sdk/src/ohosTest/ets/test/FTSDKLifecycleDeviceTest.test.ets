import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import {
  FTSDKAnrManager,
  FTSDKRuntime
} from '../../../main/ets/components/internal/runtime/FTSDKRuntime';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTRUMInnerManager } from '../../../main/ets/components/rum/FTRUMInnerManager';
import { FTNavigationTracker } from '../../../main/ets/components/rum/FTNavigationTracker';
import { FTAppStartCounter } from '../../../main/ets/components/monitor/FTAppStartCounter';
import { FTAppLaunchTracker } from '../../../main/ets/components/monitor/FTAppLaunchTracker';
import { FTActionTrackingHandler } from '../../../main/ets/components/rum/handler/FTActionTrackingHandler';
import { ActionEventWrapper } from '../../../main/ets/components/rum/bean/ActionEventWrapper';
import { HandlerAction } from '../../../main/ets/components/rum/bean/HandlerAction';
import { ActionSourceType } from '../../../main/ets/components/rum/enum/ActionSourceType';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { FTAbilityLifecycleListener } from '../../../main/ets/components/monitor/FTAbilityLifecycleListener';
import {
  FTCrashFreeClock,
  FTCrashFreeDurationManager,
  FTCrashFreeStorage
} from '../../../main/ets/components/monitor/FTCrashFreeDurationManager';
import { AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { Utils } from '../../../main/ets/components/utils/Utils';
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

interface DeviceAbilityLifecycleCallback {
  onAbilityForeground?: (ability: Object) => void;
  onAbilityBackground?: (ability: Object) => void;
}

class DeviceCrashFreeClock implements FTCrashFreeClock {
  public uptimeNs: number = 100;
  public wallClockMs: number = 1000000;

  public nowUptimeNs(): number {
    return this.uptimeNs;
  }

  public nowWallClockMs(): number {
    return this.wallClockMs;
  }
}

class DeviceCrashFreeStorage implements FTCrashFreeStorage {
  public value: string = '';

  public async read(): Promise<string> {
    return this.value;
  }

  public async write(value: string): Promise<void> {
    this.value = value;
  }
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

class DeviceMultiAbilityApplicationContext {
  public stateCallback: DeviceApplicationStateCallback | null = null;
  public lifecycleCallback: DeviceAbilityLifecycleCallback | null = null;

  public on(type: string, callback: Object): number {
    if (type === 'applicationStateChange') {
      this.stateCallback = callback as DeviceApplicationStateCallback;
      return 1;
    }
    if (type === 'abilityLifecycle') {
      this.lifecycleCallback = callback as DeviceAbilityLifecycleCallback;
      return 2;
    }
    return -1;
  }

  public off(type: string, callbackOrId?: Object | number): Promise<void> {
    if (type === 'applicationStateChange' &&
      (callbackOrId === undefined || callbackOrId === this.stateCallback)) {
      this.stateCallback = null;
    }
    if (type === 'abilityLifecycle' &&
      (callbackOrId === undefined || callbackOrId === 2)) {
      this.lifecycleCallback = null;
    }
    return Promise.resolve();
  }
}

class DeviceMultiAbilityStageContext {
  private readonly applicationContext: DeviceMultiAbilityApplicationContext;

  public constructor(applicationContext: DeviceMultiAbilityApplicationContext) {
    this.applicationContext = applicationContext;
  }

  public getApplicationContext(): Object {
    return this.applicationContext;
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

class RejectAllAutomaticActionsHandler implements FTActionTrackingHandler {
  public invocationCount: number = 0;

  public resolveHandlerAction(_actionEventWrapper: ActionEventWrapper): null {
    this.invocationCount++;
    return null;
  }
}

class CustomLaunchActionHandler implements FTActionTrackingHandler {
  public coldCount: number = 0;
  public hotCount: number = 0;

  resolveHandlerAction(event: ActionEventWrapper): HandlerAction | undefined {
    if (event.getSourceType() === ActionSourceType.LAUNCH_COLD) {
      this.coldCount++;
      const properties: Record<string, object> = {};
      properties['handler_source'] = new String('cold');
      properties['app_launch_type'] = new String('tampered');
      return new HandlerAction('custom_cold_launch', properties);
    }
    if (event.getSourceType() === ActionSourceType.LAUNCH_HOT) {
      this.hotCount++;
      const properties: Record<string, object> = {};
      properties['handler_source'] = new String('hot');
      return new HandlerAction('custom_hot_launch', properties);
    }
    return undefined;
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

    it('foregroundColdLaunchCanBeFilteredByActionHandler', 0, async () => {
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

      await WaitUtils.delay(300);
      const records = await DBAssert.querySyncData([DataType.RUM_APP]);
      expect(records.some(record => record.getDataString().includes('action_type=launch_cold'))).assertFalse();
      expect(actionHandler.invocationCount).assertEqual(1);
      expect(FTAppLaunchTracker.getInstance().getSnapshot().finished).assertTrue();
      expect(FTAppLaunchTracker.getInstance().getSnapshot().reported).assertFalse();
      expect(await DBAssert.waitForViewNamed(Constants.VIEW_NAME_APPLICATION_LAUNCH, 300)).assertEqual(null);
    });

    it('foregroundColdLaunchHandlerCustomizesNameAndPreservesSdkFields', 0, async () => {
      const actionHandler = new CustomLaunchActionHandler();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true)
        .setActionTrackingHandler(actionHandler));

      const applicationContext = new DeviceLaunchApplicationContext();
      FTSDK.recordAppApplicationInit(new DeviceLaunchStageContext(applicationContext));
      await WaitUtils.delay(30);
      applicationContext.emitForeground();
      FTSDK.recordAppFirstUIAbilityCreate();
      FTSDK.recordAppLaunchWindowForeground();
      await WaitUtils.delay(5);
      FTSDK.recordAppFirstFrame();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action_type=launch_cold',
        'action_name=custom_cold_launch',
        'handler_source=',
        'app_launch_type="foreground"',
        `view_name=${Constants.VIEW_NAME_APPLICATION_LAUNCH}`
      ]);
      expect(record !== null).assertTrue();
      const launchView = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_APPLICATION_LAUNCH);
      expect(launchView !== null).assertTrue();
      expect(record!.getDataString().includes(`view_id=${launchView!.getId()}`)).assertTrue();
      expect(launchView!.getViewReferrer()).assertEqual(Constants.VIEW_NAME_ROOT);
      await FTRUMGlobalManager.getInstance().startView('first_foreground_page');
      const closedOnFirstPage = await WaitUtils.waitUntil(async () => {
        const views = await DBAssert.queryViews(100);
        return views.some(view => view.getId() === launchView!.getId() && view.getIsClose());
      }, 5000);
      expect(closedOnFirstPage).assertTrue();
      expect(actionHandler.coldCount).assertEqual(1);
      expect(FTAppLaunchTracker.getInstance().getSnapshot().reported).assertTrue();
    });

    it('customColdLaunchUsesErrorSampledStagingWhenSessionRequiresIt', 0, async () => {
      const actionHandler = new CustomLaunchActionHandler();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true)
        .setSessionSamplingRate(0)
        .setSessionOnErrorSamplingRate(100)
        .setActionTrackingHandler(actionHandler));

      const applicationContext = new DeviceLaunchApplicationContext();
      FTSDK.recordAppApplicationInit(new DeviceLaunchStageContext(applicationContext));
      await WaitUtils.delay(30);
      applicationContext.emitForeground();
      FTSDK.recordAppFirstUIAbilityCreate();
      FTSDK.recordAppLaunchWindowForeground();
      await WaitUtils.delay(5);
      FTSDK.recordAppFirstFrame();

      const staged = await DBAssert.waitForRawSyncRecordContaining('rum_app_error_sampled', [
        'action_type=launch_cold',
        'action_name=custom_cold_launch'
      ]);
      expect(staged !== null).assertTrue();
      const normalRecords = await DBAssert.querySyncData([DataType.RUM_APP]);
      expect(normalRecords.some(record => record.getDataString().includes('action_type=launch_cold'))).assertFalse();
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

    it('hotLaunchHandlerCustomizesNameAndProperties', 0, async () => {
      const actionHandler = new CustomLaunchActionHandler();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true)
        .setActionTrackingHandler(actionHandler));

      await FTRUMGlobalManager.getInstance().startView('foreground_page');
      const foregroundViewId = FTRUMInnerManager.getInstance().getActiveView()!.getId();
      FTAppStartCounter.getInstance().hotStart(1_000_000, Date.now() * 1_000_000);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action_type=launch_hot',
        'action_name=custom_hot_launch',
        'handler_source=',
        `view_name=${Constants.VIEW_NAME_APPLICATION_LAUNCH}`
      ]);
      expect(record !== null).assertTrue();
      const launchView = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_APPLICATION_LAUNCH);
      expect(launchView !== null).assertTrue();
      expect(launchView!.getId() === foregroundViewId).assertFalse();
      expect(record!.getDataString().includes(`view_id=${launchView!.getId()}`)).assertTrue();
      expect(FTRUMInnerManager.getInstance().getActiveView()!.getId()).assertEqual(foregroundViewId);
      const launchViewClosed = await WaitUtils.waitUntil(async () => {
        const views = await DBAssert.queryViews(100);
        return views.some(view => view.getId() === launchView!.getId() && view.getIsClose() &&
          view.getTimeSpent() === 1_000_000);
      }, 5000);
      expect(launchViewClosed).assertTrue();
      expect(actionHandler.hotCount).assertEqual(1);
    });

    it('hotLaunchHandlerCanFilterAction', 0, async () => {
      const actionHandler = new RejectAllAutomaticActionsHandler();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
      FTSDK.installRUMConfig(new FTRUMConfig()
        .setRumAppId(TEST_FAKE_RUM_ID)
        .setEnableTraceUserAction(true)
        .setActionTrackingHandler(actionHandler));

      FTAppStartCounter.getInstance().hotStart(1_000_000, Date.now() * 1_000_000);
      await WaitUtils.delay(300);

      const records = await DBAssert.querySyncData([DataType.RUM_APP]);
      expect(records.some(record => record.getDataString().includes('action_type=launch_hot'))).assertFalse();
      expect(actionHandler.invocationCount).assertEqual(1);
    });

    it('multipleUiAbilitiesKeepOneCrashFreeApplicationTimeline', 0, async () => {
      const originalAbilityContext = Utils.getAbilityContext();
      const applicationContext = new DeviceMultiAbilityApplicationContext();
      const stageContext = new DeviceMultiAbilityStageContext(applicationContext);
      const clock = new DeviceCrashFreeClock();
      const crashFreeManager = new FTCrashFreeDurationManager(clock);
      const listener = FTAbilityLifecycleListener.getInstance();
      const firstAbility = new Object();
      const secondAbility = new Object();

      try {
        await crashFreeManager.initializeWithStorage(new DeviceCrashFreeStorage(), AppState.RUN);
        FTCrashFreeDurationManager.setInstanceForTesting(crashFreeManager);
        Utils.init(stageContext as Object as common.UIAbilityContext);
        listener.register();

        expect(applicationContext.lifecycleCallback !== null).assertTrue();
        expect(applicationContext.stateCallback !== null).assertTrue();
        applicationContext.lifecycleCallback?.onAbilityForeground?.(firstAbility);
        clock.uptimeNs = 130;
        clock.wallClockMs = 1000030;
        applicationContext.lifecycleCallback?.onAbilityForeground?.(secondAbility);

        // One of two foreground abilities leaving must not classify the
        // application as background or add a background duration.
        clock.uptimeNs = 160;
        clock.wallClockMs = 1000060;
        applicationContext.lifecycleCallback?.onAbilityBackground?.(firstAbility);
        await crashFreeManager.getCurrentSnapshot();

        clock.uptimeNs = 200;
        clock.wallClockMs = 1000100;
        applicationContext.lifecycleCallback?.onAbilityBackground?.(secondAbility);
        await crashFreeManager.getCurrentSnapshot();

        clock.uptimeNs = 250;
        clock.wallClockMs = 1000150;
        applicationContext.stateCallback?.onApplicationForeground();
        await crashFreeManager.getCurrentSnapshot();

        clock.uptimeNs = 310;
        clock.wallClockMs = 1000210;
        const duration = await crashFreeManager.prepareCrashFreeDuration(AppState.RUN, false);
        expect(duration !== null).assertTrue();
        if (duration) {
          // foreground: 100-130 + 130-200 + 250-310 = 160
          // background: 200-250 = 50. The first ability's background event
          // at 160 is intentionally absent from the application timeline.
          expect(duration.foregroundNs).assertEqual(160);
          expect(duration.backgroundNs).assertEqual(50);
        }
      } finally {
        listener.unregister();
        FTCrashFreeDurationManager.setInstanceForTesting(null);
        Utils.init(originalAbilityContext);
      }
    });

    it('backgroundingOneOfTwoAbilitiesKeepsTheActiveViewOpen', 0, async () => {
      const originalAbilityContext = Utils.getAbilityContext();
      const applicationContext = new DeviceMultiAbilityApplicationContext();
      const stageContext = new DeviceMultiAbilityStageContext(applicationContext);
      const listener = FTAbilityLifecycleListener.getInstance();
      const firstAbility = new Object();
      const secondAbility = new Object();

      try {
        FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL).setDebug(true).setAutoSync(false), context);
        FTSDK.installRUMConfig(new FTRUMConfig()
          .setRumAppId(TEST_FAKE_RUM_ID)
          .setEnableTraceUserView(true));
        listener.unregister();
        Utils.init(stageContext as Object as common.UIAbilityContext);
        listener.register();

        applicationContext.lifecycleCallback?.onAbilityForeground?.(firstAbility);
        applicationContext.lifecycleCallback?.onAbilityForeground?.(secondAbility);
        // Let the automatic foreground recovery finish before starting a manual View.
        await FTNavigationTracker.getInstance().resumeAutomaticViewOnForeground();
        await FTRUMGlobalManager.getInstance().startView('two_ability_view');
        const view = FTRUMInnerManager.getInstance().getActiveView();
        expect(view?.isClose()).assertFalse();

        applicationContext.lifecycleCallback?.onAbilityBackground?.(firstAbility);
        await WaitUtils.delay(150);
        expect(view?.isClose()).assertFalse();

        applicationContext.lifecycleCallback?.onAbilityBackground?.(secondAbility);
        const closed = await WaitUtils.waitUntil(async () => view?.isClose() === true, 5000);
        expect(closed).assertTrue();
      } finally {
        listener.unregister();
        Utils.init(originalAbilityContext);
      }
    });
  });
}
