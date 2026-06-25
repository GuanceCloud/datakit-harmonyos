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

  startMonitoring(): void {
    this.startMonitoringCount++;
  }

  shutdown(): void {
    this.shutdownCount++;
  }
}

class DeviceLifecycleUIContext {
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

    it('rumWithoutAppIdShouldIgnorePublicRumCalls', 0, async () => {
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
  });
}
