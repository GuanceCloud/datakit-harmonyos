import { describe, expect, it } from '@ohos/hypium';
import {
  FTCrashFreeClock,
  FTCrashFreeDurationManager,
  FTCrashFreeStorage
} from '../../main/ets/components/monitor/FTCrashFreeDurationManager';
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
          stateStartUptimeNs: 100,
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

    it('onlyCrashErrorTypesAreEligibleForCrashFreeDuration', 0, () => {
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.JS_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.NATIVE_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.ANR_CRASH)).assertTrue();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.ANR_ERROR)).assertFalse();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.NETWORK)).assertFalse();
      expect(RUMEnumUtils.isCrashErrorType(ErrorType.CUSTOM)).assertFalse();
      expect(RUMEnumUtils.parseErrorType('native_crash')).assertEqual(ErrorType.NATIVE_CRASH);
      expect(RUMEnumUtils.parseErrorType('anr_error')).assertEqual(ErrorType.ANR_ERROR);
      expect(RUMEnumUtils.getAllErrorTypes().includes(ErrorType.ANR_ERROR)).assertTrue();
    });
  });
}
