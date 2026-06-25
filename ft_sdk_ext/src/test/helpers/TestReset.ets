import { FTTraceConfigManager, FTTraceManager } from '@guancecloud/ft_sdk/Index';

export class TestReset {
  public static resetP0State(): void {
    FTTraceConfigManager.getInstance().reset();
    FTTraceManager.getInstance().clearAllHandlers();
  }
}
