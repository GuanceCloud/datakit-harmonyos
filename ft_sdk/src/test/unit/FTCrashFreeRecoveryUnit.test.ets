import { describe, expect, it } from '@ohos/hypium';
import {
  FTCrashFreeClock, FTCrashFreeDurationManager, FTCrashFreeStorage
} from '../../main/ets/components/monitor/FTCrashFreeDurationManager';
import { FTCrashFreeCommit } from '../../main/ets/components/monitor/FTCrashFreeState';
import { AppState } from '../../main/ets/components/rum/enum/RUMEnums';

class RecoveryClock implements FTCrashFreeClock {
  public uptimeNs: number = 100000000;
  public nowUptimeNs(): number { return this.uptimeNs; }
  public nowWallClockMs(): number { return 1000000 + this.uptimeNs / 1000000; }
  public advance(ms: number): void { this.uptimeNs += ms * 1000000; }
}

class RecoveryStorage implements FTCrashFreeStorage {
  public value: string = '';
  public commits: FTCrashFreeCommit[] = [];
  public failWrites: boolean = false;
  public failReceipts: boolean = false;
  public async read(): Promise<string> { return this.value; }
  public async readCommits(): Promise<FTCrashFreeCommit[]> {
    if (this.failReceipts) { throw new Error('receipt read failure'); }
    return this.commits;
  }
  public async write(value: string): Promise<void> {
    if (this.failWrites) { throw new Error('snapshot write failure'); }
    this.value = value;
  }
}

export default function ftCrashFreeRecoveryUnitTest() {
  describe('FTCrashFreeRecoveryUnit', () => {
    it('duplicateAndStaleConfirmationsNeverResetANewerCycle', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const first = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      storage.commits.push(first.commit);
      expect(await manager.confirmCrashReported(first)).assertTrue();
      clock.advance(10);
      expect(await manager.confirmCrashReported(first)).assertFalse();
      const second = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      expect(second.foregroundNs).assertEqual(10000000);
      storage.commits.push(second.commit);
      await manager.confirmCrashReported(second);
      clock.advance(5);
      await manager.confirmCrashReported(first);
      expect((await manager.prepareCrashFreeDuration(AppState.RUN, false))!.foregroundNs).assertEqual(5000000);
    });

    it('aSnapshotWriteFailureCanRetryConfirmationWithoutResettingAgain', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      storage.commits.push(duration.commit);
      storage.failWrites = true;
      let failed = false;
      try { await manager.confirmCrashReported(duration); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      clock.advance(10);
      storage.failWrites = false;
      expect(await manager.confirmCrashReported(duration)).assertFalse();
      expect((await manager.prepareCrashFreeDuration(AppState.RUN, false))!.foregroundNs).assertEqual(10000000);
    });

    it('restartReplaysAnErrorReceiptEvenWhenItsSnapshotWasNeverUpdated', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      // Simulate process death after Error+receipt commit but before onComplete.
      storage.commits.push(duration.commit);
      clock.advance(10);
      const restarted = new FTCrashFreeDurationManager(clock);
      await restarted.initializeWithStorage(storage, AppState.RUN);
      const recovered = (await restarted.prepareCrashFreeDuration(AppState.RUN, true,
        clock.nowWallClockMs() - 5, 'later-native-crash'))!;
      // The old cycle is excluded; only [120ms, 125ms] remains.
      expect(recovered.foregroundNs).assertEqual(5000000);
    });

    it('confirmedNativeReceiptsSuppressRecoveryAcrossRepeatedRestarts', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const first = new FTCrashFreeDurationManager(clock);
      await first.initializeWithStorage(storage, AppState.BACKGROUND);
      clock.advance(20);
      await first.shutdown();
      const crashMs = clock.nowWallClockMs();
      clock.advance(10);
      const recovery = new FTCrashFreeDurationManager(clock);
      await recovery.initializeWithStorage(storage, AppState.RUN);
      const duration = (await recovery.prepareCrashFreeDuration(AppState.BACKGROUND, true, crashMs, 'native-1'))!;
      storage.commits.push(duration.commit);
      // No acknowledgement and no Preferences write after the durable Error.
      for (let index = 0; index < 2; index++) {
        clock.advance(10);
        const restarted = new FTCrashFreeDurationManager(clock);
        await restarted.initializeWithStorage(storage, AppState.RUN);
        expect(await restarted.prepareCrashFreeDuration(AppState.BACKGROUND, true, crashMs, 'native-1')).assertNull();
      }
    });

    it('missingDurableErrorReceiptCannotResetTheTimeline', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      let failed = false;
      try { await manager.confirmCrashReported(duration); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      clock.advance(10);
      expect((await manager.prepareCrashFreeDuration(AppState.RUN, false))!.foregroundNs).assertEqual(30000000);
    });

    it('failedReceiptRecoveryDoesNotSilentlyStartAnUnverifiedTimeline', 0, async () => {
      const storage = new RecoveryStorage();
      storage.failReceipts = true;
      const manager = new FTCrashFreeDurationManager(new RecoveryClock());
      let failed = false;
      try { await manager.initializeWithStorage(storage, AppState.RUN); } catch (_) { failed = true; }
      expect(failed).assertTrue();
      expect(storage.value).assertEqual('');
    });

    it('backgroundOnlyStartupUsesInitialVisibilityWithoutAUiAbilityEvent', 0, async () => {
      const clock = new RecoveryClock();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(new RecoveryStorage());
      expect(manager.getCurrentAppState()).assertEqual(AppState.UNKNOWN);
      clock.advance(10);
      await manager.recordInitialAppState(AppState.BACKGROUND);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.BACKGROUND, false))!;
      expect(duration.foregroundNs).assertEqual(0);
      expect(duration.backgroundNs).assertEqual(30000000);
    });

    it('delayedInitializationPreservesTheEarlyLifecycleTimeline', 0, async () => {
      const clock = new RecoveryClock();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.transition(AppState.BACKGROUND);
      clock.advance(20);
      await manager.initializeWithStorage(new RecoveryStorage(), AppState.RUN);
      clock.advance(10);
      const duration = (await manager.prepareCrashFreeDuration(AppState.BACKGROUND, false))!;
      expect(manager.getCurrentAppState()).assertEqual(AppState.BACKGROUND);
      expect(duration.foregroundNs).assertEqual(0);
      expect(duration.backgroundNs).assertEqual(30000000);
    });

    it('aLateInitialVisibilityResultCannotOverrideALifecycleTransition', 0, async () => {
      const clock = new RecoveryClock();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(new RecoveryStorage());
      await manager.transition(AppState.RUN);
      clock.advance(10);
      await manager.recordInitialAppState(AppState.BACKGROUND);
      expect(manager.getCurrentAppState()).assertEqual(AppState.RUN);
      expect((await manager.prepareCrashFreeDuration(AppState.RUN, false))!.foregroundNs).assertEqual(10000000);
    });

    it('queuedTransitionsUseEventTimeRatherThanStorageCompletionTime', 0, async () => {
      const clock = new RecoveryClock();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(new RecoveryStorage(), AppState.RUN);
      clock.advance(10);
      const background = manager.transition(AppState.BACKGROUND);
      clock.advance(20);
      const foreground = manager.transition(AppState.RUN);
      clock.advance(10);
      await background;
      await foreground;
      const duration = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      expect(duration.foregroundNs).assertEqual(20000000);
      expect(duration.backgroundNs).assertEqual(20000000);
    });

    it('spoolCompletionAdvancesTheCycleWithoutTheOriginalWriteCallback', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const failed = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      clock.advance(10);
      // A later spool replay atomically saves this Error and its receipt.
      storage.commits.push(failed.commit);
      const next = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      expect(next.foregroundNs).assertEqual(10000000);
      expect(next.reportToken === failed.reportToken).assertFalse();
    });

    it('confirmationUsesTheFirstDurableReceiptForConcurrentReportsOfOneCycle', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const first = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      clock.advance(10);
      const later = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      expect(first.reportToken).assertEqual(later.reportToken);
      storage.commits.push(first.commit);
      await manager.confirmCrashReported(later);
      expect((await manager.prepareCrashFreeDuration(AppState.RUN, false))!.foregroundNs).assertEqual(10000000);
    });

    it('aCrashTailStateDifferentFromTheTrackedStateStillResetsTheWholePrefix', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.BACKGROUND, false))!;
      expect(duration.foregroundNs).assertEqual(0);
      expect(duration.backgroundNs).assertEqual(20000000);
      storage.commits.push(duration.commit);
      await manager.confirmCrashReported(duration);
      const next = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      expect(next.foregroundNs).assertEqual(0);
      expect(next.backgroundNs).assertEqual(0);
    });

    it('lifecycleChangesWhileTheErrorIsBeingStoredBelongToTheNextCycle', 0, async () => {
      const clock = new RecoveryClock();
      const storage = new RecoveryStorage();
      const manager = new FTCrashFreeDurationManager(clock);
      await manager.initializeWithStorage(storage, AppState.RUN);
      clock.advance(20);
      const duration = (await manager.prepareCrashFreeDuration(AppState.RUN, false))!;
      clock.advance(10);
      await manager.transition(AppState.BACKGROUND);
      clock.advance(20);
      storage.commits.push(duration.commit);
      await manager.confirmCrashReported(duration);
      const next = (await manager.prepareCrashFreeDuration(AppState.BACKGROUND, false))!;
      expect(next.foregroundNs).assertEqual(10000000);
      expect(next.backgroundNs).assertEqual(20000000);
    });
  });
}
