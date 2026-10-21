import { InsightIntentEntry, InsightIntentEntryExecutor, insightIntent } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'ForegroundLaunchDiagnosticIntent';

class ForegroundLaunchDiagnosticResult {
  pid: number = 0;
  executeMode: string = '';
  windowStageProvided: boolean = false;
  message: string = '';
}

/**
 * System-discoverable foreground diagnostic entry for EntryAbility.
 * EntryAbility loads its normal content through onWindowStageCreate, so the
 * executor does not reload the page or alter cold-launch timing.
 */
@InsightIntentEntry({
  intentName: 'ForegroundLaunchDiagnostic',
  domain: 'LocalDomain',
  intentVersion: '1.0.1',
  displayName: '前台启动诊断',
  displayDescription: '在前台打开 EntryAbility，返回意图执行模式与进程信息。',
  icon: $r('app.media.startIcon'),
  llmDescription: '用于测试应用前台意图的识别和执行，打开应用并返回进程 PID 与系统执行模式。',
  keywords: ['前台启动诊断', '前台启动', '打开应用', 'ForegroundLaunchDiagnostic'],
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND]
})
export default class ForegroundLaunchDiagnosticIntent extends
  InsightIntentEntryExecutor<ForegroundLaunchDiagnosticResult> {
  onExecute(): Promise<insightIntent.IntentResult<ForegroundLaunchDiagnosticResult>> {
    const isForeground = this.executeMode === insightIntent.ExecuteMode.UI_ABILITY_FOREGROUND;
    const diagnostic = new ForegroundLaunchDiagnosticResult();
    diagnostic.pid = process.pid;
    diagnostic.executeMode = isForeground ? 'UI_ABILITY_FOREGROUND' : String(this.executeMode);
    diagnostic.windowStageProvided = this.windowStage !== undefined;
    diagnostic.message = isForeground
      ? '前台意图已执行，EntryAbility 通过正常生命周期显示界面；首帧与冷启动上报需单独验证。'
      : '系统执行模式不是 UI_ABILITY_FOREGROUND，请检查意图调用配置。';

    const details = `pid=${diagnostic.pid}, executeMode=${diagnostic.executeMode}, ` +
      `windowStageProvided=${diagnostic.windowStageProvided}`;
    if (isForeground) {
      DemoLogger.i(TAG, `FOREGROUND_INTENT_EXECUTED: ${details}`);
    } else {
      DemoLogger.e(TAG, `FOREGROUND_INTENT_MODE_MISMATCH: ${details}`);
    }

    const result: insightIntent.IntentResult<ForegroundLaunchDiagnosticResult> = {
      code: isForeground ? 0 : -1,
      result: diagnostic
    };
    return Promise.resolve(result);
  }
}
