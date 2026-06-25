import { FTDBCachePolicy } from '../../main/ets/components/db/FTDBCachePolicy';
import { AxiosChainMethodStore, HttpAutoTrackStateStore } from '../../main/ets/components/network/FTHttpAutoTrackShared';
import { FTTraceConfigManager } from '../../main/ets/components/trace/FTTraceConfigManager';
import { FTTraceManager } from '../../main/ets/components/trace/FTTraceManager';

export class TestReset {
  public static resetP0State(): void {
    const cachePolicy = FTDBCachePolicy.getInstance();
    cachePolicy.resetCounts();
    cachePolicy.resetTestConfig();

    AxiosChainMethodStore.getInstance().clear();
    HttpAutoTrackStateStore.getInstance().clear();
    FTTraceConfigManager.getInstance().reset();
    FTTraceManager.getInstance().clearAllHandlers();
  }
}
