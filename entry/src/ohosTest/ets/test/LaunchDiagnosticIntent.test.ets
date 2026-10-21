import { describe, expect, it } from '@ohos/hypium';
import { insightIntent } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import ForegroundLaunchDiagnosticIntent from '../../../main/ets/insightintents/ForegroundLaunchDiagnosticIntent';
import BackgroundLaunchDiagnosticIntent from '../../../main/ets/insightintents/BackgroundLaunchDiagnosticIntent';

/** Executor contract checks; system discovery and lifecycle need a real intent invocation. */
export default function launchDiagnosticIntentTest() {
  describe('LaunchDiagnosticIntentTest', () => {
    it('foregroundIntentReportsActualProcessAndMode', 0, async () => {
      const executor = new ForegroundLaunchDiagnosticIntent();
      executor.executeMode = insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND;
      const result = await executor.onExecute();

      expect(result.code).assertEqual(0);
      expect(result.result?.pid).assertEqual(process.pid);
      expect(result.result?.executeMode).assertEqual('UI_ABILITY_FOREGROUND');
      expect(result.result?.windowStageProvided).assertFalse();
    });

    it('backgroundIntentCanExecuteWithoutWindowStage', 0, async () => {
      const executor = new BackgroundLaunchDiagnosticIntent();
      executor.executeMode = insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND;
      const result = await executor.onExecute();

      expect(result.code).assertEqual(0);
      expect(result.result?.pid).assertEqual(process.pid);
      expect(result.result?.executeMode).assertEqual('UI_ABILITY_BACKGROUND');
      expect(result.result?.windowStageProvided).assertFalse();
    });

    it('foregroundIntentRejectsOtherExecutionModes', 0, async () => {
      const executor = new ForegroundLaunchDiagnosticIntent();
      const modes: insightIntent.ExecuteMode[] = [
        insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND,
        insightIntent.ExecuteMode.UI_EXTENSION_ABILITY
      ];
      for (const mode of modes) {
        executor.executeMode = mode;
        const result = await executor.onExecute();
        expect(result.code).assertEqual(-1);
        expect(result.result?.executeMode).assertEqual(String(mode));
      }
    });

    it('backgroundIntentRejectsOtherExecutionModes', 0, async () => {
      const executor = new BackgroundLaunchDiagnosticIntent();
      const modes: insightIntent.ExecuteMode[] = [
        insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND,
        insightIntent.ExecuteMode.UI_EXTENSION_ABILITY
      ];
      for (const mode of modes) {
        executor.executeMode = mode;
        const result = await executor.onExecute();
        expect(result.code).assertEqual(-1);
        expect(result.result?.executeMode).assertEqual(String(mode));
      }
    });
  });
}
