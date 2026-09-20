import { describe, expect, it } from '@ohos/hypium';
import {
  FTCrashFreeClock,
  FTCrashFreeDurationManager,
  FTCrashFreeStorage
} from '../../main/ets/components/monitor/FTCrashFreeDurationManager';
import {
  applyFTRUMCrashRecoveryContext,
  FTRUMCrashRecoveryContext
} from '../../main/ets/components/rum/FTRUMInnerManager';
import { Constants } from '../../main/ets/components/Constants';
import { AppState, ErrorType, RUMEnumUtils } from '../../main/ets/components/rum/enum/RUMEnums';

class FixedCrashFreeClock implements FTCrashFreeClock {
  public uptimeNs: number = 100;
  public wallClockMs: number = 1000000;

  public nowUptimeNs(): number {
    return this.uptimeNs;
  }

  public nowWallClockMs(): number {
    return this.wallClockMs;
  }
}

class MemoryCrashFreeStorage implements FTCrashFreeStorage {
  public value: string = '';
  public writes: number = 0;
  public failWrites: boolean = false;

  public async read(): Promise<string> {
    return this.value;
  }

  public async write(value: string): Promise<void> {
    this.writes++;
    if (this.failWrites) {
      throw new Error('storage failure');
    }
    this.value = value;
  }
}

export default function ftCrashFreeDurationManagerUnitTest() {
  describe('FTCrashFreeDurationManagerUnit', () => {
    it('accumulatesForegroundAndBackgroundWithOneMonotonicTimeline', 0, async () => {
      const clock = new FixedCrashFreeClock();
      const storage = new MemoryCrashFreeStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      clock.uptimeNs = 150;
      clock.wallClockMs = 1000050;
      await manager.transition(AppState.BACKGROUND);
      clock.uptimeNs = 220;
      clock.wallClockMs = 1000120;
      await manager.transition(AppState.RUN);
      clock.uptimeNs = 300;
      clock.wallClockMs = 1000200;

      const duration = await manager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(duration !== null).assertTrue();
      if (duration) {
        expect(duration.foregroundNs).assertEqual(130);
        expect(duration.backgroundNs).assertEqual(70);
      }
    });

    it('reportsExactForegroundAndBackgroundTailsForJsAndNativeCrashes', 0, async () => {
      const jsClock = new FixedCrashFreeClock();
      const jsStorage = new MemoryCrashFreeStorage();
      const jsManager = new FTCrashFreeDurationManager(jsClock);
      await jsManager.initializeWithStorage(jsStorage, AppState.RUN);

      // JS crash while foreground: [100, 130] is foreground and [130, 180]
      // is background; the foreground crash tail is [180, 230].
      jsClock.uptimeNs = 130;
      jsClock.wallClockMs = 1000030;
      await jsManager.transition(AppState.BACKGROUND);
      jsClock.uptimeNs = 180;
      jsClock.wallClockMs = 1000080;
      await jsManager.transition(AppState.RUN);
      jsClock.uptimeNs = 230;
      jsClock.wallClockMs = 1000130;
      const foregroundJs = await jsManager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(foregroundJs !== null).assertTrue();
      if (foregroundJs) {
        expect(foregroundJs.foregroundNs).assertEqual(80);
        expect(foregroundJs.backgroundNs).assertEqual(50);
        await jsManager.confirmCrashReported(foregroundJs);
      }

      // After the confirmed foreground crash, only [230, 270] belongs to the
      // foreground and the background crash tail is [270, 340].
      jsClock.uptimeNs = 270;
      jsClock.wallClockMs = 1000170;
      await jsManager.transition(AppState.BACKGROUND);
      jsClock.uptimeNs = 340;
      jsClock.wallClockMs = 1000240;
      const backgroundJs = await jsManager.prepareCrashFreeDuration(AppState.BACKGROUND, false);
      expect(backgroundJs !== null).assertTrue();
      if (backgroundJs) {
        expect(backgroundJs.foregroundNs).assertEqual(40);
        expect(backgroundJs.backgroundNs).assertEqual(70);
      }

      // Native crashes are recovered in the next process. The recovery tail
      // is derived from the native event wall clock and is placed on the
      // crash state, not on the state saved before the process exited.
      const nativeForegroundClock = new FixedCrashFreeClock();
      nativeForegroundClock.uptimeNs = 200;
      nativeForegroundClock.wallClockMs = 1000100;
      const nativeForegroundStorage = new MemoryCrashFreeStorage();
      nativeForegroundStorage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 30,
          backgroundNs: 20,
          state: AppState.RUN,
          stateStartUptimeNs: 150,
          observedUptimeNs: 150,
          observedWallClockMs: 1000050,
          bootMarkerMs: 1000000,
          runId: 'native-foreground-process'
        },
        pending: null,
        reportedNativeCrashIds: []
      });
      const nativeForegroundManager = new FTCrashFreeDurationManager(nativeForegroundClock);
      await nativeForegroundManager.initializeWithStorage(nativeForegroundStorage, AppState.RUN);
      const foregroundNative = await nativeForegroundManager.prepareCrashFreeDuration(
        AppState.RUN, true, 1000080, 'native-foreground-id');
      expect(foregroundNative !== null).assertTrue();
      if (foregroundNative) {
        expect(foregroundNative.foregroundNs).assertEqual(30000030);
        expect(foregroundNative.backgroundNs).assertEqual(20);
      }

      const nativeBackgroundClock = new FixedCrashFreeClock();
      nativeBackgroundClock.uptimeNs = 200;
      nativeBackgroundClock.wallClockMs = 1000100;
      const nativeBackgroundStorage = new MemoryCrashFreeStorage();
      nativeBackgroundStorage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 30,
          backgroundNs: 20,
          state: AppState.BACKGROUND,
          stateStartUptimeNs: 150,
          observedUptimeNs: 150,
          observedWallClockMs: 1000050,
          bootMarkerMs: 1000000,
          runId: 'native-background-process'
        },
        pending: null,
        reportedNativeCrashIds: []
      });
      const nativeBackgroundManager = new FTCrashFreeDurationManager(nativeBackgroundClock);
      await nativeBackgroundManager.initializeWithStorage(nativeBackgroundStorage, AppState.RUN);
      const backgroundNative = await nativeBackgroundManager.prepareCrashFreeDuration(
        AppState.BACKGROUND, true, 1000080, 'native-background-id');
      expect(backgroundNative !== null).assertTrue();
      if (backgroundNative) {
        expect(backgroundNative.foregroundNs).assertEqual(30);
        expect(backgroundNative.backgroundNs).assertEqual(30000020);
      }
    });

    it('serializesRepeatedForegroundBackgroundTransitionsWithoutOverlap', 0, async () => {
      const clock = new FixedCrashFreeClock();
      const storage = new MemoryCrashFreeStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      // Repeated foreground signals model overlapping UIAbility foreground
      // callbacks. Repeated background signals are emitted only after the
      // final foreground ability has left. Each boundary must split, rather
      // than duplicate, the one monotonic process timeline.
      clock.uptimeNs = 110;
      clock.wallClockMs = 1000010;
      await manager.transition(AppState.RUN);
      clock.uptimeNs = 125;
      clock.wallClockMs = 1000025;
      await manager.transition(AppState.BACKGROUND);
      clock.uptimeNs = 160;
      clock.wallClockMs = 1000060;
      await manager.transition(AppState.RUN);
      clock.uptimeNs = 200;
      clock.wallClockMs = 1000100;
      await manager.transition(AppState.BACKGROUND);
      clock.uptimeNs = 235;
      clock.wallClockMs = 1000135;
      await manager.transition(AppState.RUN);
      clock.uptimeNs = 265;
      clock.wallClockMs = 1000165;
      await manager.transition(AppState.BACKGROUND);
      clock.uptimeNs = 275;
      clock.wallClockMs = 1000175;
      await manager.transition(AppState.BACKGROUND);
      clock.uptimeNs = 300;
      clock.wallClockMs = 1000200;

      const duration = await manager.prepareCrashFreeDuration(AppState.BACKGROUND, false);
      expect(duration !== null).assertTrue();
      if (duration) {
        // foreground: 100-125 + 160-200 + 235-265 = 95
        // background: 125-160 + 200-235 + 265-300 = 105
        expect(duration.foregroundNs).assertEqual(95);
        expect(duration.backgroundNs).assertEqual(105);
      }
    });

    it('keepsTheIntervalWhenErrorPersistenceDoesNotAcknowledgeThenResetsOnce', 0, async () => {
      const clock = new FixedCrashFreeClock();
      const storage = new MemoryCrashFreeStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      clock.uptimeNs = 180;
      clock.wallClockMs = 1000080;
      const failedError = await manager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(failedError !== null).assertTrue();
      if (failedError) {
        expect(failedError.foregroundNs).assertEqual(80);
      }
      // A failed local Error write never invokes confirmCrashReported().

      clock.uptimeNs = 220;
      clock.wallClockMs = 1000120;
      const persistedError = await manager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(persistedError !== null).assertTrue();
      if (persistedError) {
        // The failed Error did not clear [100, 180], so the successful Error
        // still includes the full [100, 220] interval.
        expect(persistedError.foregroundNs).assertEqual(120);
        await manager.confirmCrashReported(persistedError);
      }

      clock.uptimeNs = 250;
      clock.wallClockMs = 1000150;
      const afterOneConfirmation = await manager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(afterOneConfirmation !== null).assertTrue();
      if (afterOneConfirmation) {
        // Exactly one acknowledged Error starts the next cycle at 220.
        expect(afterOneConfirmation.foregroundNs).assertEqual(30);
        expect(afterOneConfirmation.backgroundNs).assertEqual(0);
      }
    });

    it('recoversPriorProcessSnapshotAndAssignsRecoveredTailToCrashState', 0, async () => {
      const clock = new FixedCrashFreeClock();
      clock.uptimeNs = 200;
      clock.wallClockMs = 1000100;
      const storage = new MemoryCrashFreeStorage();
      storage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 30,
          backgroundNs: 20,
          state: AppState.BACKGROUND,
          stateStartUptimeNs: 150,
          observedUptimeNs: 150,
          observedWallClockMs: 1000050,
          bootMarkerMs: 1000000,
          runId: 'previous-run'
        },
        pending: null,
        reportedNativeCrashIds: []
      });
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      const duration = await manager.prepareCrashFreeDuration(
        AppState.RUN,
        true,
        1000080,
        'native-crash-id'
      );
      expect(duration !== null).assertTrue();
      if (duration) {
        expect(duration.foregroundNs).assertEqual(30000030);
        expect(duration.backgroundNs).assertEqual(20);
      }

      const newProcessSnapshot = await manager.getCurrentSnapshot();
      expect(newProcessSnapshot !== null).assertTrue();
      if (newProcessSnapshot) {
        expect(newProcessSnapshot.foregroundNs).assertEqual(0);
        expect(newProcessSnapshot.backgroundNs).assertEqual(0);
      }
    });

    it('discardsIncompatibleOrMalformedSnapshotsWithoutNegativeDuration', 0, async () => {
      const clock = new FixedCrashFreeClock();
      const malformedStorage = new MemoryCrashFreeStorage();
      malformedStorage.value = '{not-json';
      const malformedManager = new FTCrashFreeDurationManager(clock);
      await malformedManager.initializeWithStorage(malformedStorage, AppState.RUN);

      const malformedDuration = await malformedManager.prepareCrashFreeDuration(AppState.BACKGROUND, true, 1000100);
      expect(malformedDuration !== null).assertTrue();
      if (malformedDuration) {
        expect(malformedDuration.foregroundNs).assertEqual(0);
        expect(malformedDuration.backgroundNs).assertEqual(0);
      }

      const rebootStorage = new MemoryCrashFreeStorage();
      rebootStorage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 10,
          backgroundNs: 20,
          state: AppState.RUN,
          stateStartUptimeNs: 1000,
          observedUptimeNs: 1000,
          observedWallClockMs: 900000,
          bootMarkerMs: 899999,
          runId: 'old-boot'
        },
        pending: null,
        reportedNativeCrashIds: []
      });
      const rebootManager = new FTCrashFreeDurationManager(clock);
      await rebootManager.initializeWithStorage(rebootStorage, AppState.RUN);
      const rebootDuration = await rebootManager.prepareCrashFreeDuration(AppState.RUN, true, 1000100);
      expect(rebootDuration !== null).assertTrue();
      if (rebootDuration) {
        expect(rebootDuration.foregroundNs).assertEqual(0);
        expect(rebootDuration.backgroundNs).assertEqual(0);
      }
    });

    it('resetsOnlyAfterConfirmationAndDeduplicatesConfirmedNativeCrash', 0, async () => {
      const clock = new FixedCrashFreeClock();
      const storage = new MemoryCrashFreeStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.uptimeNs = 180;
      clock.wallClockMs = 1000080;

      const currentDuration = await manager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(currentDuration !== null).assertTrue();
      const beforeConfirmation = await manager.getCurrentSnapshot();
      expect(beforeConfirmation !== null).assertTrue();
      if (beforeConfirmation) {
        expect(beforeConfirmation.foregroundNs).assertEqual(0);
      }
      if (currentDuration) {
        await manager.confirmCrashReported(currentDuration);
      }
      const afterConfirmation = await manager.getCurrentSnapshot();
      expect(afterConfirmation !== null).assertTrue();
      if (afterConfirmation) {
        expect(afterConfirmation.foregroundNs).assertEqual(0);
        expect(afterConfirmation.backgroundNs).assertEqual(0);
      }

      const restartManager = new FTCrashFreeDurationManager(clock);
      await restartManager.initializeWithStorage(storage, AppState.RUN);
      const recovered = await restartManager.prepareCrashFreeDuration(AppState.RUN, true, 1000080, 'same-native-id');
      expect(recovered !== null).assertTrue();
      if (recovered) {
        await restartManager.confirmCrashReported(recovered);
      }
      const duplicate = await restartManager.prepareCrashFreeDuration(AppState.RUN, true, 1000080, 'same-native-id');
      expect(duplicate === null).assertTrue();
    });

    it('recoveredCrashContextUsesPredecessorViewAndSessionTags', 0, () => {
      const tags: Record<string, string> = {};
      const recovered: FTRUMCrashRecoveryContext = {
        sessionId: 'crashed-session',
        viewId: 'crashed-view',
        viewName: 'CrashTestPage',
        viewReferrer: 'HomePage'
      };

      expect(applyFTRUMCrashRecoveryContext(tags, recovered)).assertTrue();
      expect(tags[Constants.KEY_RUM_SESSION_ID]).assertEqual('crashed-session');
      expect(tags[Constants.KEY_RUM_VIEW_ID]).assertEqual('crashed-view');
      expect(tags[Constants.KEY_RUM_VIEW_NAME]).assertEqual('CrashTestPage');
      expect(tags[Constants.KEY_RUM_VIEW_REFERRER]).assertEqual('HomePage');
      expect(tags[Constants.KEY_RUM_ACTION_ID] === undefined).assertTrue();
      expect(tags[Constants.KEY_RUM_ACTION_NAME] === undefined).assertTrue();
    });

    it('recoveredCrashContextWithoutViewAndSessionDoesNotOverwriteTags', 0, () => {
      const tags: Record<string, string> = {};
      tags[Constants.KEY_RUM_SESSION_ID] = 'current-session';
      tags[Constants.KEY_RUM_VIEW_ID] = 'current-view';
      const incomplete: FTRUMCrashRecoveryContext = {
        sessionId: '',
        viewId: '',
        viewName: '',
        viewReferrer: ''
      };

      expect(applyFTRUMCrashRecoveryContext(tags, incomplete)).assertFalse();
      expect(tags[Constants.KEY_RUM_SESSION_ID]).assertEqual('current-session');
      expect(tags[Constants.KEY_RUM_VIEW_ID]).assertEqual('current-view');
    });

    it('usesPredecessorSnapshotForHistoricalSystemFreezeWithoutNativeMarker', 0, async () => {
      const clock = new FixedCrashFreeClock();
      clock.uptimeNs = 200;
      clock.wallClockMs = 1000100;
      const storage = new MemoryCrashFreeStorage();
      storage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 0,
          backgroundNs: 40,
          state: AppState.BACKGROUND,
          stateStartUptimeNs: 150,
          observedUptimeNs: 150,
          observedWallClockMs: 1000050,
          bootMarkerMs: 1000000,
          runId: 'freeze-process'
        },
        pending: null,
        reportedNativeCrashIds: []
      });
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      // APP_FREEZE is delivered after restart. The original event time is
      // before this process started, even though it lacks is_pre_crash.
      const duration = await manager.prepareCrashFreeDuration(
        AppState.BACKGROUND,
        false,
        1000080,
        'historical-freeze-id'
      );
      expect(duration !== null).assertTrue();
      if (duration) {
        expect(duration.isPreCrash).assertTrue();
        expect(duration.foregroundNs).assertEqual(0);
        expect(duration.backgroundNs).assertEqual(30000040);
        await manager.confirmCrashReported(duration);
      }
      const duplicate = await manager.prepareCrashFreeDuration(
        AppState.BACKGROUND,
        false,
        1000080,
        'historical-freeze-id'
      );
      expect(duplicate === null).assertTrue();
    });

    it('selectsTheNewestPredecessorMatchingEachRecoveredCrashTime', 0, async () => {
      const clock = new FixedCrashFreeClock();
      clock.uptimeNs = 500;
      clock.wallClockMs = 1000400;
      const storage = new MemoryCrashFreeStorage();
      storage.value = JSON.stringify({
        version: 1,
        current: {
          foregroundNs: 30,
          backgroundNs: 0,
          state: AppState.RUN,
          stateStartUptimeNs: 300,
          observedUptimeNs: 300,
          observedWallClockMs: 1000300,
          bootMarkerMs: 1000000,
          runId: 'newer-process'
        },
        pending: {
          foregroundNs: 20,
          backgroundNs: 0,
          state: AppState.RUN,
          stateStartUptimeNs: 100,
          observedUptimeNs: 100,
          observedWallClockMs: 1000100,
          bootMarkerMs: 1000000,
          runId: 'older-process'
        },
        reportedNativeCrashIds: []
      });
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);

      const olderDuration = await manager.prepareCrashFreeDuration(AppState.RUN, true, 1000120, 'older-id');
      expect(olderDuration !== null).assertTrue();
      if (olderDuration) {
        expect(olderDuration.foregroundNs).assertEqual(20000020);
        await manager.confirmCrashReported(olderDuration);
      }
      const newerDuration = await manager.prepareCrashFreeDuration(AppState.RUN, true, 1000350, 'newer-id');
      expect(newerDuration !== null).assertTrue();
      if (newerDuration) {
        expect(newerDuration.foregroundNs).assertEqual(50000030);
      }
    });

    it('onlyCrashErrorTypesAreEligibleForCrashFreeDuration', 0, () => {
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.JS_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.NATIVE_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.ANR_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.ANR_ERROR)).assertFalse();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.NETWORK)).assertFalse();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.CUSTOM)).assertFalse();
      expect(RUMEnumUtils.parseErrorType('native_crash')).assertEqual(ErrorType.NATIVE_CRASH);
      expect(RUMEnumUtils.parseErrorType('anr_error')).assertEqual(ErrorType.ANR_ERROR);
      expect(RUMEnumUtils.parseErrorType('network_error')).assertEqual(ErrorType.NETWORK);
      expect(RUMEnumUtils.parseErrorType('network')).assertEqual(ErrorType.NETWORK);
      expect(RUMEnumUtils.getAllErrorTypes().includes(ErrorType.ANR_ERROR)).assertTrue();
    });
  });
}
