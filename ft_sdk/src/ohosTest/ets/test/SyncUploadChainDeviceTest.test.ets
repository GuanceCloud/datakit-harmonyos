import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { FTDBManager } from '../../../main/ets/components/db/FTDBManager';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { DataType, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { ThreadPoolManager } from '../../../main/ets/components/thread/ThreadPoolManager';
import { WaitUtils } from './helpers/WaitUtils';
import { MockCollector } from './helpers/MockCollector';
import { DBAssert } from './helpers/DBAssert';

const TEST_HOST = 'http://127.0.0.1:1';
const TEST_NOW_NS = 1700000000000;

async function waitUntil(predicate: () => Promise<boolean>, timeoutMs: number): Promise<boolean> {
  return await WaitUtils.waitUntil(predicate, timeoutMs);
}

function createLogSyncData(label: string, time: number): SyncData {
  const syncData = new SyncData(DataType.LOG);
  syncData.setTime(time);
  syncData.setDataString(
    `df_rum_harmonyos_log,sdk_data_id=${syncData.getUuid()},service=upload_chain_test message="${label}" ${time}`
  );
  return syncData;
}

export default function syncUploadChainDeviceTest() {
  describe('SyncUploadChainDeviceTest', () => {
    let context: Context;
    let dbManager: FTDBManager;
    let syncTaskManager: SyncTaskManager;
    let collector: MockCollector;

    beforeEach(async () => {
      context = await DBAssert.getAppContext();
      dbManager = FTDBManager.getInstance(context);
      await dbManager.init();
      await dbManager.resetDatabase();
      await ThreadPoolManager.getInstance().initialize();

      const config = FTSDKConfig.builder(TEST_HOST)
        .setAutoSync(false)
        .setSyncPageSize(SyncPageSize.MINI)
        .setDataSyncRetryCount(1)
        .setSyncSleepTime(0);
      syncTaskManager = SyncTaskManager.getInstance();
      syncTaskManager.init(config, context);
      syncTaskManager.resume();
      collector = new MockCollector(200, '');
      collector.start();
      await WaitUtils.delay(120);
    });

    afterEach(async () => {
      collector.stop();
      syncTaskManager.stop();
      await dbManager.delete();
    });

    it('successfulUploadShouldConsumeQueueAndDeleteUploadedRows', 0, async () => {
      await dbManager.insertFtOperation(createLogSyncData('success-delete', TEST_NOW_NS));
      collector.setResponse(200, '');

      syncTaskManager.executePoll(false);
      const consumed = await waitUntil(async () => {
        return await dbManager.queryTotalCount([DataType.LOG]) === 0;
      }, 4000);
      const payload = await collector.waitForPayloadContaining(['success-delete'], 1000);

      expect(consumed).assertTrue();
      expect(payload.length > 0).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(0);
    });

    it('batchUploadShouldDeleteAllPagesAcrossMultipleBatches', 0, async () => {
      const records: SyncData[] = [];
      for (let i = 0; i < 7; i++) {
        records.push(createLogSyncData(`batch-${i}`, TEST_NOW_NS + i));
      }
      await dbManager.insertFtOptList(records);
      collector.setResponse(200, '');

      syncTaskManager.executePoll(false);
      const consumed = await waitUntil(async () => {
        return await dbManager.queryTotalCount([DataType.LOG]) === 0;
      }, 5000);
      const payloads = collector.getRequests().map(request => request.bodyString).join('\n');

      expect(consumed).assertTrue();
      expect(payloads.includes('batch-0')).assertTrue();
      expect(payloads.includes('batch-6')).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(0);
    });

    it('failedUploadShouldPreserveDataAndRecoverAfterNextSuccessfulUpload', 0, async () => {
      await dbManager.insertFtOperation(createLogSyncData('retry-preserve', TEST_NOW_NS + 10));
      collector.setResponse(500, 'server-error');

      syncTaskManager.executePoll(false);
      await WaitUtils.delay(1200);
      const countAfterFailure = await dbManager.queryTotalCount([DataType.LOG]);
      const failedPayload = await collector.waitForPayloadContaining(['retry-preserve'], 1000);

      collector.setResponse(200, '');
      collector.clearRequests();
      syncTaskManager.executePoll(false);
      const recovered = await waitUntil(async () => {
        return await dbManager.queryTotalCount([DataType.LOG]) === 0;
      }, 4000);
      const recoveredPayload = await collector.waitForPayloadContaining(['retry-preserve'], 1000);

      expect(countAfterFailure).assertEqual(1);
      expect(failedPayload.length > 0).assertTrue();
      expect(recoveredPayload.length > 0).assertTrue();
      expect(recovered).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(0);
    });

  });
}
