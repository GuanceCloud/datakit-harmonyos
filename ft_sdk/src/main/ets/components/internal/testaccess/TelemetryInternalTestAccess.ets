import FTTrackInner from '../../FTTrackInner';
import { TrackLogManager } from '../../log/TrackLogManager';
import { FTRUMConfigManager } from '../../rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../../rum/FTRUMInnerManager';
import { UserDataManager } from '../../rum/UserDataManager';

export class TelemetryInternalTestAccess {
  public static resetState(): void {
    FTRUMInnerManager.resetStateInternal();
    FTRUMConfigManager.resetStateInternal();
    TrackLogManager.resetStateInternal();
    FTTrackInner.resetInstanceInternal();
    UserDataManager.resetStateInternal();
  }
}
