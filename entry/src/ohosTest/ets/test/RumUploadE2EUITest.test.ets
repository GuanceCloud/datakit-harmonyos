import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { AppState, ErrorType, FTRUMGlobalManager, FTSDK } from '@guancecloud/ft_sdk/Index';
import {
  FTSDKExtensionBridge,
  FTSDKExtensionPreparedRequest
} from '@guancecloud/ft_sdk/src/main/ets/components/integration/FTSDKExtensionBridge';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryWaitUtils } from './helpers/EntryWaitUtils';
import { UiTestUtils } from './helpers/UiTestUtils';

/**
 * This suite is intentionally opt-in. It runs on a real device and verifies
 * the complete client path: RUM API/HTTP bridge -> worker -> DB -> upload
 * worker -> the actual DataKit/Dataway URL supplied in the launch parameters.
 * It deliberately does not inspect server-side ingestion, request headers, or
 * post-upload DB deletion; those are deployment-level checks rather than RUM
 * line-protocol regression coverage.
 */
export default function rumUploadE2EUITest() {
  if (!UiTestUtils.isUploadE2EEnabled()) {
    return;
  }

  describe('RumUploadE2EUITest', () => {
    let driver: Driver;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      if (!UiTestUtils.hasConfiguredUploadEndpoint()) {
        throw new Error(
          'Real upload verification requires entryDatakitUrl, or entryDatawayUrl together with entryClientToken.'
        );
      }
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();

      const syncTaskManager = SyncTaskManager.getInstance();
      syncTaskManager.setAutoSync(false);
    });

    afterEach(async () => {
      // The root afterAll owns SDK restoration, also when this suite is skipped.
      await EntryDBAssert.cleanupAll();
    });

    it('shouldUploadViewActionAxiosBridgeResourceLongTaskAndError', 0, async () => {
      const runId = `rum_upload_e2e_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
      const viewName = `e2e_upload_view_${runId}`;
      const actionName = `e2e_upload_action_${runId}`;
      const resourceUrl = `https://resource.e2e.invalid/${runId}`;
      const longTaskMarker = `e2e_upload_long_task_${runId}`;
      const errorMarker = `e2e_upload_error_${runId}`;
      const rum = FTRUMGlobalManager.getInstance();

      await rum.startView(viewName);
      rum.addAction(actionName, 'click');

      // The extension bridge is the completion path used by Axios Compat.
      // It must set both the content and NetState before stopResource; if the
      // old setNetState regression returns, the following resource never
      // reaches sync_data_flat and therefore cannot enter the upload worker.
      const requestHeaders: Record<string, Object> = {};
      const prepared: FTSDKExtensionPreparedRequest = FTSDKExtensionBridge.prepareHttpRequest(
        {
          url: resourceUrl,
          method: 'GET',
          headers: requestHeaders
        },
        {
          enableTraceInterceptor: false,
          enableResourceInterceptor: true
        }
      );
      await EntryWaitUtils.delay(20);
      const responseHeaders: Record<string, Object> = {};
      responseHeaders['content-type'] = 'application/json' as Object;
      responseHeaders['content-length'] = '11' as Object;
      const completed = FTSDKExtensionBridge.completeHttpResponse({
        url: resourceUrl,
        method: 'GET',
        uniqueId: prepared.uniqueId,
        requestHeaders: prepared.headers,
        responseHeaders: responseHeaders,
        statusCode: 200,
        body: '{"ok":true}'
      });
      expect(completed).assertTrue();

      rum.addLongTask(longTaskMarker, 1_000_000_000);
      rum.addError(`stack: ${errorMarker}`, errorMarker, ErrorType.CUSTOM, AppState.RUN);
      await rum.stopView();

      const queued = await EntryWaitUtils.waitUntil(async () => {
        const records = await EntryDBAssert.querySyncRecords([DataType.RUM_APP], 100, true);
        return RumUploadE2EUITest.hasEveryLineWithFragments(records.map((record) => record.getDataString()), [
          ['view,', `view_name=${viewName}`, 'session_id='],
          ['action,', `action_name=${actionName}`, 'action_type=click', `view_name=${viewName}`],
          ['resource,', `resource_url=${resourceUrl}`, 'resource_method=GET', 'resource_status=200', 'duration='],
          ['long_task,', longTaskMarker, 'duration='],
          ['error,', 'error_type=custom', 'error_stack=', errorMarker]
        ]);
      }, 12000, 200);
      if (!queued) {
        throw new Error(
          `Expected every RUM chain to reach sync_data_flat before upload.\n${await EntryDBAssert.dumpSyncRecords(100)}`
        );
      }

      // This is intentionally the real endpoint configured by entryDatakitUrl
      // or entryDatawayUrl/clientToken in the test launch parameters.
      const uploadSequenceBeforeFlush = SyncTaskManager.getInstance().getStatus().lastUploadResult.sequence;
      UiTestUtils.assertTestConfigurationApplied();
      FTSDK.flushSyncData();
      const uploadCompleted = await EntryWaitUtils.waitUntil(async () => {
        const status = SyncTaskManager.getInstance().getStatus();
        const lane = status.uploadLaneStatus;
        const active = status.running || lane.isRunning || lane.isScheduled;
        const result = status.lastUploadResult;
        return result.sequence > uploadSequenceBeforeFlush && !active && !lane.needReschedule &&
          result.httpAttemptCount > 0 && result.failedHttpResponseCount === 0 &&
          result.successfulHttpResponseCount === result.httpAttemptCount &&
          result.lastHttpStatusCode >= 200 && result.lastHttpStatusCode < 300;
      }, 30000, 50);
      if (!uploadCompleted) {
        const status = SyncTaskManager.getInstance().getStatus();
        throw new Error(
          `Upload did not complete successfully against the launch endpoint: ` +
          `errorCount=${status.errorCount}, httpAttempts=${status.lastUploadResult.httpAttemptCount}, ` +
          `httpSuccess=${status.lastUploadResult.successfulHttpResponseCount}, ` +
          `httpFailure=${status.lastUploadResult.failedHttpResponseCount}, ` +
          `lastHttpCode=${status.lastUploadResult.lastHttpStatusCode}, ` +
          `running=${status.running}, scheduled=${status.uploadLaneStatus.isScheduled}, ` +
          `retry=${status.uploadLaneStatus.needReschedule}`
        );
      }
    });
  });
}

class RumUploadE2EUITest {
  static hasEveryLineWithFragments(lines: string[], expectedLines: string[][]): boolean {
    for (let expectedIndex = 0; expectedIndex < expectedLines.length; expectedIndex++) {
      const expectedFragments = expectedLines[expectedIndex];
      let found = false;
      for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
        let includesEveryFragment = true;
        for (let fragmentIndex = 0; fragmentIndex < expectedFragments.length; fragmentIndex++) {
          if (!lines[lineIndex].includes(expectedFragments[fragmentIndex])) {
            includesEveryFragment = false;
            break;
          }
        }
        if (includesEveryFragment) {
          found = true;
          break;
        }
      }
      if (!found) {
        return false;
      }
    }
    return true;
  }

}
