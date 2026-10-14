import FTTrackInner from '../../FTTrackInner';
import { TrackLogManager } from '../../log/TrackLogManager';
import { FTConsoleLogBridge } from '../../log/FTConsoleLogBridge';
import { FTRUMConfigManager } from '../../rum/FTRUMConfigManager';
import { FTRUMInnerManager } from '../../rum/FTRUMInnerManager';
import { UserDataManager } from '../../rum/UserDataManager';
import { DeviceUUIDManager } from '../../utils/DeviceUUIDManager';

export class TelemetryInternalTestAccess {
  public static resetState(): void {
    FTRUMInnerManager.resetStateInternal();
    FTRUMConfigManager.resetStateInternal();
    TrackLogManager.resetStateInternal();
    FTConsoleLogBridge.resetStateInternal();
    FTTrackInner.resetInstanceInternal();
    UserDataManager.resetStateInternal();
    DeviceUUIDManager.resetStateInternal();
  }
}
