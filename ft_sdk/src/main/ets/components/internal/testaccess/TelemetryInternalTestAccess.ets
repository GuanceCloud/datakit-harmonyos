import FTTrackInner from '../../FTTrackInner';
import { TrackLogManager } from '../../log/TrackLogManager';
import { FTRUMGlobalManager } from '../../rum/FTRUMGlobalManager';
import { UserDataManager } from '../../rum/UserDataManager';

export class TelemetryInternalTestAccess {
  public static resetState(): void {
    FTRUMGlobalManager.resetStateInternal();
    TrackLogManager.resetStateInternal();
    FTTrackInner.resetInstanceInternal();
    UserDataManager.resetStateInternal();
  }
}
