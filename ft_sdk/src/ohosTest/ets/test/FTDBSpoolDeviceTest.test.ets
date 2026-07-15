import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { FTDBManager } from '../../../main/ets/components/db/FTDBManager';
import { FTDBSpoolManager } from '../../../main/ets/components/db/FTDBSpoolManager';
import {
  FTDBSpoolPaths,
  FTDBSpoolTaskPoolExecutor
} from '../../../main/ets/components/db/FTDBSpoolTaskPoolExecutor';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { DBAssert } from './helpers/DBAssert';

const TEST_NOW_NS = 1700000000000;

function createLogSyncData(label: string, time: number): SyncData {
  const row = new SyncData(DataType.LOG);
  row.setTime(time);
  row.setDataString(
    `df_rum_harmonyos_log,sdk_data_id=${row.getUuid()},service=spool_device_test message="${label}" ${time}`
  );
  return row;
}

function createPaths(spoolManager: FTDBSpoolManager): FTDBSpoolPaths {
  const status = spoolManager.getStatus();
  const separator = status.activePath.lastIndexOf('/');
  const spoolDir = separator >= 0 ? status.activePath.substring(0, separator) : '';
  return {
    spoolDir,
    activePath: status.activePath,
    inflightPath: status.inflightPath,
    legacyPath: `${spoolDir}/sync_data_spool.ndjson`
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    return await fileIo.access(path);
  } catch (_) {
    return false;
  }
}

export default function ftDBSpoolDeviceTest() {
  describe('FTDBSpoolDeviceTest', () => {
    let context: Context;
    let dbManager: FTDBManager;
    let spoolManager: FTDBSpoolManager;

    beforeEach(async () => {
      context = await DBAssert.getAppContext();
      dbManager = FTDBManager.getInstance(context);
      await dbManager.init();
      await dbManager.resetDatabase();
      spoolManager = FTDBSpoolManager.getInstance();
      spoolManager.init(context);
      await spoolManager.clear();
    });

    afterEach(async () => {
      await spoolManager.clear();
      await dbManager.delete();
    });

    it('activeAndInflightShouldRemainIsolatedUntilAck', 0, async () => {
      const first = createLogSyncData('active-first', TEST_NOW_NS + 1);
      const second = createLogSyncData('active-second', TEST_NOW_NS + 2);
      const paths = createPaths(spoolManager);

      expect(await spoolManager.appendSyncData('device.first', [first])).assertEqual(1);
      expect(await pathExists(paths.activePath)).assertTrue();
      expect(await pathExists(paths.inflightPath)).assertFalse();

      const prepared = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths);
      expect(prepared.records.length).assertEqual(1);
      expect(prepared.batchToken.length > 0).assertTrue();
      expect(await pathExists(paths.activePath)).assertFalse();
      expect(await pathExists(paths.inflightPath)).assertTrue();

      expect(await spoolManager.appendSyncData('device.second', [second])).assertEqual(1);
      expect(await pathExists(paths.activePath)).assertTrue();
      expect(spoolManager.getStatus().pendingRecords).assertEqual(2);

      const acknowledged = await FTDBSpoolTaskPoolExecutor.ackReplay(paths, prepared.batchToken);
      expect(acknowledged.pendingRecords).assertEqual(1);
      expect(await pathExists(paths.inflightPath)).assertFalse();
      expect(await pathExists(paths.activePath)).assertTrue();
    });

    it('replayShouldBeIdempotentAfterDbCommitBeforeAck', 0, async () => {
      const row = createLogSyncData('commit-before-ack', TEST_NOW_NS + 10);
      const paths = createPaths(spoolManager);
      await spoolManager.appendSyncData('device.idempotent', [row]);

      const prepared = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths);
      const preparedRows: SyncData[] = [];
      for (let i = 0; i < prepared.records.length; i++) {
        preparedRows.push(SyncData.fromJSON(prepared.records[i].data));
      }
      const firstWrite = await dbManager.writeSyncDataAtomically('device.simulate-commit-before-ack', preparedRows, {
        applyCachePolicy: true,
        reInsert: false,
        forceTransaction: true,
        updateOrInsertByUuid: true,
        skipFailureFallback: true
      });

      expect(firstWrite.success).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(1);
      expect(await pathExists(paths.inflightPath)).assertTrue();

      const replayed = await spoolManager.replay(context, 'device.idempotent-retry');
      expect(replayed).assertEqual(1);
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(1);
      expect(spoolManager.getStatus().pendingRecords).assertEqual(0);
      expect(await pathExists(paths.inflightPath)).assertFalse();
    });

    it('ackTokenFaultShouldRetainInflightForIdempotentReplay', 0, async () => {
      const row = createLogSyncData('ack-token-fault', TEST_NOW_NS + 15);
      const paths = createPaths(spoolManager);
      await spoolManager.appendSyncData('device.ack-token-fault', [row]);

      const prepared = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths);
      const preparedRows: SyncData[] = [];
      for (let i = 0; i < prepared.records.length; i++) {
        preparedRows.push(SyncData.fromJSON(prepared.records[i].data));
      }
      const committedBeforeAck = await dbManager.writeSyncDataAtomically(
        'device.ack-token-fault-before-ack',
        preparedRows,
        {
          applyCachePolicy: true,
          reInsert: false,
          forceTransaction: true,
          updateOrInsertByUuid: true,
          skipFailureFallback: true
        }
      );
      expect(committedBeforeAck.success).assertTrue();

      let ackRejected = false;
      try {
        await FTDBSpoolTaskPoolExecutor.ackReplay(paths, `${prepared.batchToken}-stale`);
      } catch (_) {
        ackRejected = true;
      }
      expect(ackRejected).assertTrue();
      expect(await pathExists(paths.inflightPath)).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(1);

      const replayed = await spoolManager.replay(context, 'device.ack-token-fault-retry');
      expect(replayed).assertEqual(1);
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(1);
      expect(spoolManager.getStatus().pendingRecords).assertEqual(0);
      expect(await pathExists(paths.inflightPath)).assertFalse();
    });

    it('replayShouldAdvanceByUtf8ByteCursorWithoutDuplicates', 0, async () => {
      const rows: SyncData[] = [
        createLogSyncData('字节游标-一', TEST_NOW_NS + 21),
        createLogSyncData('字节游标-二', TEST_NOW_NS + 22),
        createLogSyncData('字节游标-三', TEST_NOW_NS + 23),
        createLogSyncData('字节游标-四', TEST_NOW_NS + 24),
        createLogSyncData('字节游标-五', TEST_NOW_NS + 25)
      ];
      const paths = createPaths(spoolManager);
      expect(await spoolManager.appendSyncData('device.byte-cursor', rows)).assertEqual(5);

      const first = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths, 0, 2);
      expect(first.pageStartByteOffset).assertEqual(0);
      expect(first.records.length).assertEqual(2);
      expect(first.nextByteOffset > 0).assertTrue();
      expect(first.nextByteOffset < first.inflightBytes).assertTrue();
      expect(first.hasMoreRecords).assertTrue();

      const second = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths, first.nextByteOffset, 2);
      expect(second.pageStartByteOffset).assertEqual(first.nextByteOffset);
      expect(second.records.length).assertEqual(2);
      expect(second.nextByteOffset > first.nextByteOffset).assertTrue();
      expect(second.hasMoreRecords).assertTrue();

      const third = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths, second.nextByteOffset, 2);
      expect(third.pageStartByteOffset).assertEqual(second.nextByteOffset);
      expect(third.records.length).assertEqual(1);
      expect(third.nextByteOffset).assertEqual(third.inflightBytes);
      expect(third.hasMoreRecords).assertFalse();

      const replayedUuids: string[] = [];
      const pages = [first, second, third];
      for (let pageIndex = 0; pageIndex < pages.length; pageIndex++) {
        for (let rowIndex = 0; rowIndex < pages[pageIndex].records.length; rowIndex++) {
          replayedUuids.push(pages[pageIndex].records[rowIndex].data.uuid);
        }
      }
      expect(replayedUuids.length).assertEqual(5);
      expect(new Set(replayedUuids).size).assertEqual(5);

      await FTDBSpoolTaskPoolExecutor.ackReplay(paths, first.batchToken);
    });

    it('capacityShouldIncludeInflightAndReleaseAfterAck', 0, async () => {
      const first = createLogSyncData('capacity-row', TEST_NOW_NS + 31);
      const second = createLogSyncData('capacity-row', TEST_NOW_NS + 32);
      const paths = createPaths(spoolManager);

      const appended = await FTDBSpoolTaskPoolExecutor.append(
        paths,
        'device.capacity',
        0,
        [first.toJSON()]
      );
      expect(appended.appendedRecords).assertEqual(1);
      expect(appended.pendingBytes > 0).assertTrue();

      const prepared = await FTDBSpoolTaskPoolExecutor.prepareReplay(paths, 0, 1);
      const testCapacity = appended.pendingBytes + 1;
      const rejected = await FTDBSpoolTaskPoolExecutor.append(
        paths,
        'device.capacity',
        1,
        [second.toJSON()],
        testCapacity
      );
      expect(rejected.appendedRecords).assertEqual(0);
      expect(rejected.rejectedRecords).assertEqual(1);
      expect(rejected.pendingBytes).assertEqual(appended.pendingBytes);

      await FTDBSpoolTaskPoolExecutor.ackReplay(paths, prepared.batchToken);
      const retried = await FTDBSpoolTaskPoolExecutor.append(
        paths,
        'device.capacity',
        2,
        [second.toJSON()],
        testCapacity
      );
      expect(retried.appendedRecords).assertEqual(1);
      expect(retried.rejectedRecords).assertEqual(0);
      expect(retried.pendingBytes <= testCapacity).assertTrue();
    });
  });
}
