import { UIContext } from '@kit.ArkUI';
import { FTRUMConfig } from '../../../../main/ets/components/Configs';
import { DefaultFTSDKRuntime } from '../../../../main/ets/components/internal/runtime/FTSDKRuntime';

/** Keep device tests using explicit Views independent of the runner's Index page. */
export class NoNavigationTestRuntime extends DefaultFTSDKRuntime {
  initNavigationTracker(_uiContext: UIContext, _config: FTRUMConfig): void {
  }
}
