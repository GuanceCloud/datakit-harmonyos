import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import {
  FTDBManager,
  SyncDataWriteFailureFallback
} from '../../main/ets/components/db/FTDBManager';
import { FTDBTaskPoolSyncDraftDTO } from '../../main/ets/components/db/FTDBTaskPoolExecutor';
import { SyncData, SyncDataJSON } from '../../main/ets/components/db/bean/SyncData';
import { DataType } from '../../main/ets/components/enum/Enums';
import { DbInternalTestAccess } from '../../main/ets/components/internal/testaccess/DbInternalTestAccess';

function createContext(): Context {
  return new Object() as Context;
}

function createLogSyncData(uuid: string): SyncData {
  const row = new SyncData(DataType.LOG);
  row.setUuid(uuid);
  row.setTime(100);
  row.setDataString(`df_rum_harmonyos_log,sdk_data_id=${uuid} message="fallback" 100`);
  return row;
}

class FakeSyncDataFailureFallback implements SyncDataWriteFailureFallback {
  sources: string[] = [];
  records: SyncDataJSON[] = [];

  async appendSyncDataJSON(source: string, records: SyncDataJSON[]): Promise<number> {
    this.sources.push(source);
    for (let i = 0; i < records.length; i++) {
      this.records.push(records[i]);
    }
    return records.length;
  }
}

export default function ftDBSpoolUnitTest() {
  describe('FTDBSpoolUnit', () => {
    let manager: FTDBManager;
    let fallback: FakeSyncDataFailureFallback;

    beforeEach(() => {
      DbInternalTestAccess.resetDbManagerInstance();
      manager = FTDBManager.getInstance(createContext());
      fallback = new FakeSyncDataFailureFallback();
      manager.setSyncDataWriteFailureFallback(fallback);
    });

    afterEach(() => {
      manager.setSyncDataWriteFailureFallback(null);
      DbInternalTestAccess.resetDbManagerInstance();
    });

    it('syncDataWriteFailureUseUnifiedFallback', 0, async () => {
      DbInternalTestAccess.forceNextSyncDataWriteFailure();
      const result = await manager.writeSyncDataAtomically(
        'unit.sync-data-failure',
        [createLogSyncData('fallback-sync-data')]
      );

      expect(result.success).assertFalse();
      expect(result.errorMessage.includes('spooled 1 record(s)')).assertTrue();
      expect(fallback.sources.length).assertEqual(1);
      expect(fallback.sources[0]).assertEqual('unit.sync-data-failure');
      expect(fallback.records.length).assertEqual(1);
      expect(fallback.records[0].uuid).assertEqual('fallback-sync-data');
    });

    it('syncDraftWriteFailureUseSameFallback', 0, async () => {
      const draft: FTDBTaskPoolSyncDraftDTO = {
        dataType: DataType.RUM_APP.toString(),
        dataString: 'view,view_id=fallback-draft value=1i 101',
        uuid: 'fallback-draft',
        time: 101
      };
      DbInternalTestAccess.forceNextSyncDataWriteFailure();
      const result = await manager.writeSyncDraftsAtomically(
        'unit.sync-draft-failure',
        [draft],
        DataType.RUM_APP
      );

      expect(result.success).assertFalse();
      expect(result.errorMessage.includes('spooled 1 record(s)')).assertTrue();
      expect(fallback.sources.length).assertEqual(1);
      expect(fallback.sources[0]).assertEqual('unit.sync-draft-failure');
      expect(fallback.records.length).assertEqual(1);
      expect(fallback.records[0].dataType).assertEqual(DataType.RUM_APP);
    });

    it('replayFailureNotRecursivelyFallback', 0, async () => {
      DbInternalTestAccess.forceNextSyncDataWriteFailure();
      const result = await manager.writeSyncDataAtomically(
        'unit.replay-failure',
        [createLogSyncData('fallback-replay')],
        { skipFailureFallback: true }
      );

      expect(result.success).assertFalse();
      expect(fallback.records.length).assertEqual(0);
    });
  });
}
