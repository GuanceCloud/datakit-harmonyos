import { InsightIntentEntry, InsightIntentEntryExecutor, insightIntent } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = 'BackgroundLaunchDiagnosticIntent';

class BackgroundLaunchDiagnosticResult {
  pid: number = 0;
  executeMode: string = '';
  windowStageProvided: boolean = false;
  message: string = '';
}

/**
 * System-discoverable, background-only diagnostic entry for EntryAbility.
 * It does not load UI content, keep the process alive, or force a RUM launch type.
 */
@InsightIntentEntry({
  intentName: 'BackgroundLaunchDiagnostic',
  domain: 'LocalDomain',
  intentVersion: '1.0.1',
  displayName: '后台启动诊断',
  displayDescription: '在后台执行 EntryAbility 启动诊断，不主动创建窗口。',
  icon: $r('app.media.startIcon'),
  llmDescription: '用于测试应用后台意图的识别和执行，不打开应用界面，返回进程 PID 与系统执行模式。',
  keywords: ['后台启动诊断', '后台启动', 'BackgroundLaunchDiagnostic'],
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND]
})
export default class BackgroundLaunchDiagnosticIntent extends
  InsightIntentEntryExecutor<BackgroundLaunchDiagnosticResult> {
  onExecute(): Promise<insightIntent.IntentResult<BackgroundLaunchDiagnosticResult>> {
    const isBackground = this.executeMode === insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND;
    const diagnostic = new BackgroundLaunchDiagnosticResult();
    diagnostic.pid = process.pid;
    diagnostic.executeMode = isBackground ? 'UI_ABILITY_BACKGROUND' : String(this.executeMode);
    // This is the executor's optional WindowStage, not proof that the process
    // has never displayed UI. Start with no existing app process for a cold test.
    diagnostic.windowStageProvided = this.windowStage !== undefined;
    diagnostic.message = isBackground
      ? '后台意图已执行。本入口不播放音频、不提供 5 分钟保活，也不代表冷启动数据已上报。'
      : '系统执行模式不是 UI_ABILITY_BACKGROUND，请检查意图调用配置。';

    const details = `pid=${diagnostic.pid}, ` +
      `executeMode=${diagnostic.executeMode}, windowStageProvided=${diagnostic.windowStageProvided}`;
    if (isBackground) {
      DemoLogger.i(TAG, `BACKGROUND_INTENT_EXECUTED: ${details}`);
    } else {
      DemoLogger.e(TAG, `BACKGROUND_INTENT_MODE_MISMATCH: ${details}`);
    }

    const result: insightIntent.IntentResult<BackgroundLaunchDiagnosticResult> = {
      code: isBackground ? 0 : -1,
      result: diagnostic
    };
    return Promise.resolve(result);
  }
}
