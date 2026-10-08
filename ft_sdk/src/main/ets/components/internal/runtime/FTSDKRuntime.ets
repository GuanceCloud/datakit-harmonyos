import { Context, common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import window from '@ohos.window';
import { FTRUMConfig, FTSDKConfig } from '../../Configs';
import { SyncTaskManager } from '../../SyncTaskManager';
import { ANRDetectManager } from '../../monitor/ANRDetectManager';
import { FTExceptionHandler } from '../../FTExceptionHandler';
import { FTUIBlockManager } from '../../monitor/FTUIBlockManager';
import { FTAbilityLifecycleListener } from '../../monitor/FTAbilityLifecycleListener';
import { FTActionTracker } from '../../rum/FTActionTracker';
import { FTNavigationTracker } from '../../rum/FTNavigationTracker';
import { Utils } from '../../utils/Utils';

export interface FTSDKAnrManager {
  initialize(): void;
  startMonitoring(): boolean;
  shutdown(): void;
}

export interface FTSDKRuntime {
  initUtils(context: common.UIAbilityContext): void;
  getAbilityContext(): common.UIAbilityContext | null;
  initSyncTaskManager(config: FTSDKConfig, context: Context): void;
  registerLifecycleListener(): void;
  getAnrDetectManager(): FTSDKAnrManager | null;
  initExceptionHandler(config: FTRUMConfig): void;
  startUIBlockManager(config: FTRUMConfig): void;
  setMainWindow(mainWindow?: window.Window): void;
  getUIContext(): UIContext | null;
  initActionTracker(uiContext: UIContext, config: FTRUMConfig): void;
  destroyActionTracker(): void;
  initNavigationTracker(uiContext: UIContext, config: FTRUMConfig): void;
  destroyNavigationTracker(): void;
}

export class DefaultFTSDKRuntime implements FTSDKRuntime {
  initUtils(context: common.UIAbilityContext): void {
    Utils.init(context);
  }

  getAbilityContext(): common.UIAbilityContext | null {
    return Utils.getAbilityContext();
  }

  initSyncTaskManager(config: FTSDKConfig, context: Context): void {
    SyncTaskManager.getInstance().init(config, context);
  }

  registerLifecycleListener(): void {
    FTAbilityLifecycleListener.getInstance().register();
  }

  getAnrDetectManager(): FTSDKAnrManager | null {
    return ANRDetectManager.getInstance();
  }

  initExceptionHandler(config: FTRUMConfig): void {
    FTExceptionHandler.getInstance().initConfig(config);
  }

  startUIBlockManager(config: FTRUMConfig): void {
    FTUIBlockManager.getInstance().start(config);
  }

  setMainWindow(mainWindow?: window.Window): void {
    if (mainWindow) {
      Utils.setMainWindow(mainWindow);
    } else {
      Utils.setMainWindow();
    }
  }

  getUIContext(): UIContext | null {
    return Utils.getUIContext() || null;
  }

  initActionTracker(uiContext: UIContext, config: FTRUMConfig): void {
    FTActionTracker.getInstance().init(uiContext, config);
  }

  destroyActionTracker(): void {
    FTActionTracker.getInstance().destroy();
  }

  initNavigationTracker(uiContext: UIContext, config: FTRUMConfig): void {
    let windowId: number | undefined;
    // The same Window can return a different UIContext wrapper after resume.
    // Its stable ID lets View tracking retain the visible NavDestination.
    if (Utils.getUIContext() === uiContext) {
      try {
        windowId = Utils.getMainWindow()?.getWindowProperties().id;
      } catch (_error) {
        // The tracker can still fall back to UIContext identity.
      }
    }
    FTNavigationTracker.getInstance().init(uiContext, config, windowId);
  }

  destroyNavigationTracker(): void {
    FTNavigationTracker.getInstance().destroy();
  }
}

let ftSDKRuntime: FTSDKRuntime = new DefaultFTSDKRuntime();

export function getFTSDKRuntime(): FTSDKRuntime {
  return ftSDKRuntime;
}

export function setFTSDKRuntimeInternal(runtime: FTSDKRuntime): void {
  ftSDKRuntime = runtime;
}

export function resetFTSDKRuntimeInternal(): void {
  ftSDKRuntime = new DefaultFTSDKRuntime();
}
