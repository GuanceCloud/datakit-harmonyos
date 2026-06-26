import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import { FTSDKConfig } from '../../../main/ets/components/Configs';
import { FTDBManager } from '../../../main/ets/components/db/FTDBManager';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { DataType, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { DefaultSyncTaskManagerRuntime } from '../../../main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import { WaitUtils } from './helpers/WaitUtils';
import { MockCollector } from './helpers/MockCollector';
import { DBAssert } from './helpers/DBAssert';

const TEST_HOST = 'http://127.0.0.1:1';
const TEST_NOW_NS = 1700000000000;
const BACKOFF_SLEEP_TEST_DELAY_MS = 300;

class DeviceUploadRuntime extends DefaultSyncTaskManagerRuntime {
  public backoffSleeps: number[] = [];

  sleep(ms: number): Promise<void> {
    if (ms >= 500) {
      this.backoffSleeps.push(ms);
    }
    return new Promise<void>((resolve: Function) => {
      setTimeout(() => {
        resolve();
      }, ms >= 500 ? BACKOFF_SLEEP_TEST_DELAY_MS : Math.min(ms, 5));
    });
  }

  clearBackoffSleeps(): void {
    this.backoffSleeps = [];
  }

  firstBackoffSleep(): number {
    if (this.backoffSleeps.length === 0) {
      return 0;
    }
    return this.backoffSleeps[0];
  }
}

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

function createRumSyncData(dataType: DataType, label: string, time: number): SyncData {
  const syncData = new SyncData(dataType);
  syncData.setTime(time);
  const webViewTags = dataType === DataType.RUM_WEBVIEW ? ',is_web_view=true,service=browser,sdk_version=2.0.0' :
    ',service=upload_chain_test';
  syncData.setDataString(
    `view,sdk_data_id=${syncData.getUuid()},view_id=${syncData.getUuid()},view_name=${label}${webViewTags} value=1i ${time}`
  );
  return syncData;
}

function createSyncData(dataType: DataType, label: string, time: number): SyncData {
  if (dataType === DataType.LOG) {
    return createLogSyncData(label, time);
  }
  return createRumSyncData(dataType, label, time);
}

function appendSyncDataBatch(
  records: SyncData[],
  dataType: DataType,
  labelPrefix: string,
  count: number,
  startTime: number
): void {
  for (let i = 0; i < count; i++) {
    records.push(createSyncData(dataType, `${labelPrefix}-${i}`, startTime + i));
  }
}

function countBodyLines(body: string): number {
  if (body.trim().length === 0) {
    return 0;
  }
  return body.split('\n').filter((line: string) => line.trim().length > 0).length;
}

async function waitForUploadIdle(syncTaskManager: SyncTaskManager, timeoutMs: number = 5000): Promise<boolean> {
  return await waitUntil(async () => {
    const status = syncTaskManager.getStatus();
    const uploadStatus = status.uploadLaneStatus;
    return !status.running &&
      !uploadStatus.isRunning &&
      !uploadStatus.isScheduled;
  }, timeoutMs);
}

async function waitForRequestCountAndStop(
  collector: MockCollector,
  syncTaskManager: SyncTaskManager,
  requestCount: number,
  timeoutMs: number
): Promise<boolean> {
  return await WaitUtils.waitUntil(async () => {
    if (collector.getRequests().length >= requestCount) {
      syncTaskManager.stop();
      return true;
    }
    return false;
  }, timeoutMs, 5);
}

async function uploadSingleAndMeasureBackoff(
  dbManager: FTDBManager,
  collector: MockCollector,
  syncTaskManager: SyncTaskManager,
  runtime: DeviceUploadRuntime,
  dataType: DataType,
  label: string,
  code: number,
  time: number,
  idleTimeoutMs: number = 12000
): Promise<number> {
  const ready = await waitForUploadIdle(syncTaskManager, idleTimeoutMs);
  expect(ready).assertTrue();

  const syncData = createSyncData(dataType, label, time);
  const originalUuid = syncData.getUuid();
  await dbManager.insertFtOperation(syncData);
  collector.setResponse(code, `response-${code}`);
  collector.clearRequests();
  runtime.clearBackoffSleeps();

  syncTaskManager.executePoll(false);
  const backoffRecorded = await WaitUtils.waitUntil(async () => {
    return runtime.backoffSleeps.length > 0;
  }, 3000, 10);
  expect(backoffRecorded).assertTrue();
  const backoff = runtime.firstBackoffSleep();

  syncTaskManager.stop();
  await WaitUtils.delay(BACKOFF_SLEEP_TEST_DELAY_MS + 50);
  const payload = await collector.waitForPayloadContaining([label], 500);
  if (code >= 500) {
    const reinserted = await WaitUtils.waitUntil(async () => {
      const records = await dbManager.queryFtOperation([dataType], 10);
      return records.length > 0 && records[0].getUuid() !== originalUuid;
    }, 3000, 20);
    expect(reinserted).assertTrue();
  }
  await dbManager.resetDatabase();
  const idle = await waitForUploadIdle(syncTaskManager, idleTimeoutMs);

  expect(payload.length > 0).assertTrue();
  expect(idle).assertTrue();
  syncTaskManager.resume();
  return backoff;
}

export default function syncUploadChainDeviceTest() {
  describe('SyncUploadChainDeviceTest', () => {
    let context: Context;
    let dbManager: FTDBManager;
    let syncTaskManager: SyncTaskManager;
    let collector: MockCollector;
    let runtime: DeviceUploadRuntime;

    beforeEach(async () => {
      SyncTaskManager.resetStateInternal();
      runtime = new DeviceUploadRuntime();
      SyncInternalTestAccess.setRuntime(runtime);
      context = await DBAssert.getAppContext();
      dbManager = FTDBManager.getInstance(context);
      await dbManager.init();
      await dbManager.resetDatabase();

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
      SyncInternalTestAccess.resetRuntime();
      SyncTaskManager.resetStateInternal();
    });

    it('successfulUploadShouldDeleteRows', 0, async () => {
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

    it('batchUploadShouldDeleteAllPages', 0, async () => {
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

    it('failedUploadShouldRecover', 0, async () => {
      await dbManager.insertFtOperation(createLogSyncData('retry-preserve', TEST_NOW_NS + 10));
      collector.setResponse(500, 'server-error');
      runtime.clearBackoffSleeps();

      syncTaskManager.executePoll(false);
      const failedPayload = await collector.waitForPayloadContaining(['retry-preserve'], 3000);
      const failureHandled = await WaitUtils.waitUntil(async () => {
        return runtime.backoffSleeps.length > 0;
      }, 3000, 10);
      syncTaskManager.stop();
      await WaitUtils.delay(BACKOFF_SLEEP_TEST_DELAY_MS + 50);
      const preservedAfterFailure = await WaitUtils.waitUntil(async () => {
        return await dbManager.queryTotalCount([DataType.LOG]) === 1;
      }, 3000, 20);

      collector.setResponse(200, '');
      collector.clearRequests();
      syncTaskManager.resume();
      syncTaskManager.executePoll(false);
      const recovered = await waitUntil(async () => {
        return await dbManager.queryTotalCount([DataType.LOG]) === 0;
      }, 4000);
      const recoveredPayload = await collector.waitForPayloadContaining(['retry-preserve'], 1000);

      expect(failedPayload.length > 0).assertTrue();
      expect(failureHandled).assertTrue();
      expect(preservedAfterFailure).assertTrue();
      expect(recoveredPayload.length > 0).assertTrue();
      expect(recovered).assertTrue();
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(0);
    });

    it('ignoredClientBackoffShouldCapAtEightSecondsAndStayIsolatedByDataType', 0, async () => {
      const backoffs: number[] = [];

      for (let i = 0; i < 6; i++) {
        const code = i % 2 === 0 ? 403 : 429;
        const backoff = await uploadSingleAndMeasureBackoff(
          dbManager,
          collector,
          syncTaskManager,
          runtime,
          DataType.LOG,
          `ignored-cap-log-${i}`,
          code,
          TEST_NOW_NS + 100 + i,
          4000
        );
        backoffs.push(backoff);
        expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(0);
      }

      expect(backoffs[0]).assertEqual(500);
      expect(backoffs[1]).assertEqual(1000);
      expect(backoffs[2]).assertEqual(2000);
      expect(backoffs[3]).assertEqual(4000);
      expect(backoffs[4]).assertEqual(8000);
      expect(backoffs[5]).assertEqual(8000);

      const webViewBackoff = await uploadSingleAndMeasureBackoff(
        dbManager,
        collector,
        syncTaskManager,
        runtime,
        DataType.RUM_WEBVIEW,
        'ignored-isolated-webview',
        403,
        TEST_NOW_NS + 200,
        4000
      );

      expect(webViewBackoff).assertEqual(500);
      expect(await dbManager.queryTotalCount([DataType.RUM_WEBVIEW])).assertEqual(0);
    });

    it('retryBackoffShouldStayIsolatedByDataType', 0, async () => {
      const rumBackoffs: number[] = [];

      for (let i = 0; i < 4; i++) {
        const backoff = await uploadSingleAndMeasureBackoff(
          dbManager,
          collector,
          syncTaskManager,
          runtime,
          DataType.RUM_APP,
          `retry-rum-${i}`,
          500,
          TEST_NOW_NS + 300 + i,
          4000
        );
        rumBackoffs.push(backoff);
        await dbManager.resetDatabase();
      }

      expect(rumBackoffs[0]).assertEqual(500);
      expect(rumBackoffs[1]).assertEqual(1000);
      expect(rumBackoffs[2]).assertEqual(2000);
      expect(rumBackoffs[3]).assertEqual(4000);

      const logBackoff = await uploadSingleAndMeasureBackoff(
        dbManager,
        collector,
        syncTaskManager,
        runtime,
        DataType.LOG,
        'retry-isolated-log',
        500,
        TEST_NOW_NS + 400,
        4000
      );
      await dbManager.resetDatabase();

      const webViewBackoff = await uploadSingleAndMeasureBackoff(
        dbManager,
        collector,
        syncTaskManager,
        runtime,
        DataType.RUM_WEBVIEW,
        'retry-isolated-webview',
        500,
        TEST_NOW_NS + 500,
        4000
      );
      await dbManager.resetDatabase();

      expect(logBackoff).assertEqual(500);
      expect(webViewBackoff).assertEqual(500);
    });

    it('uploadPollShouldRespectTypeOrderAndPageBudget', 0, async () => {
      const records: SyncData[] = [];
      const pageSize = SyncPageSize.MINI;
      appendSyncDataBatch(records, DataType.RUM_APP, 'rum-app-budget', pageSize * 3, TEST_NOW_NS + 1000);
      appendSyncDataBatch(records, DataType.RUM_WEBVIEW, 'rum-web-budget', pageSize * 2, TEST_NOW_NS + 2000);
      appendSyncDataBatch(records, DataType.LOG, 'log-budget', pageSize * 2, TEST_NOW_NS + 3000);
      await dbManager.insertFtOptList(records);
      collector.setResponse(200, '');
      collector.clearRequests();

      syncTaskManager.executePoll(false);
      expect(await dbManager.queryTotalCount([DataType.RUM_APP])).assertEqual(pageSize * 3);
      expect(await dbManager.queryTotalCount([DataType.RUM_WEBVIEW])).assertEqual(pageSize * 2);
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(pageSize * 2);

      const capturedFirstPoll = await waitForRequestCountAndStop(collector, syncTaskManager, 4, 8000);
      expect(capturedFirstPoll).assertTrue();
      await WaitUtils.delay(300);

      const requests = collector.getRequests();
      expect(requests.length).assertEqual(4);
      expect(requests[0].bodyString.includes('rum-app-budget-0')).assertTrue();
      expect(requests[1].bodyString.includes('rum-app-budget-5')).assertTrue();
      expect(requests[2].bodyString.includes('rum-web-budget-0')).assertTrue();
      expect(requests[3].bodyString.includes('log-budget-0')).assertTrue();
      expect(countBodyLines(requests[0].bodyString)).assertEqual(pageSize);
      expect(countBodyLines(requests[1].bodyString)).assertEqual(pageSize);
      expect(countBodyLines(requests[2].bodyString)).assertEqual(pageSize);
      expect(countBodyLines(requests[3].bodyString)).assertEqual(pageSize);

      expect(await dbManager.queryTotalCount([DataType.RUM_APP])).assertEqual(pageSize);
      expect(await dbManager.queryTotalCount([DataType.RUM_WEBVIEW])).assertEqual(pageSize);
      expect(await dbManager.queryTotalCount([DataType.LOG])).assertEqual(pageSize);
    });

  });
}
