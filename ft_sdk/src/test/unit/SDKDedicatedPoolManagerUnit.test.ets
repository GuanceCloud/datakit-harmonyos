import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKDedicatedPoolManager
} from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolContextDTO,
  SDKLineProtocolInputDTO,
  SDKPropertyRecord,
  SDKRumCompletedActionDTO,
  SDKRumCounterUpdateBatchDTO,
  SDKRumCounterUpdateDTO,
  SDKRumErrorCommandBatchDTO,
  SDKRumErrorCommandDTO,
  SDKRumEventBatchDTO,
  SDKRumEventDTO,
  SDKRumResourceCommandBatchDTO,
  SDKRumResourceCommandDTO,
  SDKRumResourceContextDTO,
  SDKRumResourceNetStatusDTO,
  SDKRumResourceParamsDTO,
  SDKStringRecord,
  SDKUploadCommitPageDTO,
  SDKUploadCommitPageResultDTO,
  SDKUploadDbActionDTO,
  SDKUploadExecutePageDTO,
  SDKUploadExecutePageResultDTO,
  SDKUploadHttpRequestDTO,
  SDKUploadHttpResultDTO,
  SDKUploadPageDTO,
  SDKUploadRoundFinishDTO,
  SDKUploadRoundResultDTO,
  SDKUploadRoundStartDTO,
  SDKUploadRoundStartResultDTO,
  SDKUploadRowDTO,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../../main/ets/components/thread/SDKWorkerProtocol';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKDataUploadWorkerRequest,
  handleSDKWorkerRequest,
  SDKUploadWorkerHttpExecutor,
  SDKWorkerRuntimeState
} from '../../main/ets/components/thread/SDKWorkerBusinessHandlers';
import {
  DATA_UPLOAD_MAX_BODY_BYTES,
  DATA_UPLOAD_MAX_PAGE_SIZE,
  DATA_UPLOAD_MAX_RETRY_COUNT
} from '../../main/ets/components/thread/workers/DataUploadLimits';

interface SDKLineProtocolRecordsTestPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SDKCompletedActionPropertyTestValue {
  value?: string | number;
  nested?: string;
}

function createRumWorkerLineContext(): SDKLineProtocolContextDTO {
  const context = new Object() as SDKLineProtocolContextDTO;
  context.basePublicTags = new Object() as SDKStringRecord;
  context.logTags = new Object() as SDKStringRecord;
  context.rumTags = new Object() as SDKStringRecord;
  context.rumTags['service'] = 'native-service';
  context.rumTags['sdk_version'] = 'native-version';
  context.rumTags['sdk_pkg_info'] = '{"agent":"1.0.0","native":"1.0.0"}';
  context.dynamicBaseTags = new Object() as SDKStringRecord;
  context.dynamicBaseTags['env'] = 'worker-test';
  context.dynamicLogTags = new Object() as SDKStringRecord;
  context.dynamicRumTags = new Object() as SDKStringRecord;
  context.dynamicRumTags['custom_key'] = 'worker-value';
  context.rumStaticFields = new Object() as SDKStringRecord;
  context.rumStaticFields['session_sample_rate'] = '1';
  context.logLinkRumData = false;
  context.integerCompatible = false;
  return context;
}

function getPayloadString(payload: SDKWorkerPayload | undefined, key: string): string {
  const record = payload as Record<string, object>;
  if (!record || record[key] === undefined || record[key] === null) {
    return '';
  }
  return String(record[key]);
}

function getPayloadArray(payload: SDKWorkerPayload | undefined, key: string): object[] {
  const record = payload as Record<string, object>;
  if (!record || !Array.isArray(record[key])) {
    return [];
  }
  return record[key] as object[];
}

let unitWorkerStates: Record<string, SDKWorkerRuntimeState> = {};

function resetUnitWorkerStates(): void {
  unitWorkerStates = {};
}

async function executeWorkerCommandForUnit(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
  let state = unitWorkerStates[request.pool];
  if (!state) {
    state = createSDKWorkerRuntimeStateWithBackend(request.pool, `${request.pool}.UnitWorker`, 'unit-worker');
    unitWorkerStates[request.pool] = state;
  }
  return handleSDKWorkerRequest(request, state);
}

class RetryUploadHttpExecutor implements SDKUploadWorkerHttpExecutor {
  lastRequest: SDKUploadHttpRequestDTO | null = null;
  private readonly responseCode: number;

  constructor(responseCode: number = 500) {
    this.responseCode = responseCode;
  }

  async execute(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO> {
    this.lastRequest = request;
    return {
      code: this.responseCode,
      message: this.responseCode === 200 ? 'ok' : 'retry',
      errorCode: String(this.responseCode),
      elapsedMs: 3,
      softTimedOut: false
    };
  }
}

export default function sdkDedicatedPoolManagerUnitTest() {
  describe('SDKDedicatedPoolManagerUnit', () => {
    let manager: SDKDedicatedPoolManager;

    beforeEach(() => {
      SDKDedicatedPoolManager.resetInternal();
      manager = SDKDedicatedPoolManager.getInstance();
      resetUnitWorkerStates();
    });

    afterEach(() => {
      SDKDedicatedPoolManager.resetInternal();
    });

    it('dataProcessCommandShouldUseConfiguredWorkerCount', 0, async () => {
      const workerCount = manager.getDataProcessWorkerCount();
      expect(workerCount).assertEqual(1);
      const status = manager.getStatus().pools[SDKDedicatedPoolType.DATA_PROCESS];
      expect(status.workerCount).assertEqual(workerCount);
    });

    it('dataUploadCommandShouldUseOneStateOwnerWorker', 0, async () => {
      const status = manager.getStatus().pools[SDKDedicatedPoolType.DATA_UPLOAD];
      expect(status.workerCount).assertEqual(1);
      expect(status.maxConcurrency).assertEqual(1);
    });

    it('workerProtocolShouldRejectNonSerializablePayload', 0, async () => {
      let rejected = false;
      const request: SDKWorkerRequest = {
        id: 'bad-payload',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: 'bad.payload',
        priority: 3,
        createdAt: Date.now(),
        payload: new Map<string, string>() as object as SDKWorkerPayload
      };

      try {
        await manager.executeCommand(request);
      } catch (_) {
        rejected = true;
      }

      expect(rejected).assertTrue();
    });

    it('workerHandlerShouldReturnPingPayload', 0, async () => {
      const request: SDKWorkerRequest = {
        id: 'ping-data-process',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.PING,
        priority: 5,
        createdAt: Date.now(),
        payload: null
      };

      const response = await executeWorkerCommandForUnit(request);
      expect(response.ok).assertTrue();
      expect(getPayloadString(response.payload, 'pool')).assertEqual(SDKDedicatedPoolType.DATA_PROCESS);
      expect(getPayloadString(response.payload, 'workerName').length > 0).assertTrue();
      expect(getPayloadString(response.payload, 'backend').length > 0).assertTrue();
    });

    it('extraWorkerPoolsShouldReturnIndependentPingPayloads', 0, async () => {
      const pools: SDKDedicatedPoolType[] = [
        SDKDedicatedPoolType.CRASH_FILE,
        SDKDedicatedPoolType.ANR,
        SDKDedicatedPoolType.BACKGROUND
      ];

      for (const pool of pools) {
        const response = await executeWorkerCommandForUnit({
          id: `ping-${pool}`,
          pool,
          command: SDKWorkerCommand.PING,
          priority: 5,
          createdAt: Date.now(),
          payload: null
        });

        expect(response.ok).assertTrue();
        expect(getPayloadString(response.payload, 'pool')).assertEqual(pool);
        expect(getPayloadString(response.payload, 'workerName').length > 0).assertTrue();
      }

      const status = manager.getStatus().pools;
      expect(status[SDKDedicatedPoolType.CRASH_FILE].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.ANR].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.BACKGROUND].maxConcurrency).assertEqual(1);
    });

    it('dataProcessCommandShouldCreateLineProtocolDraftsFromDto', 0, async () => {
      const tags: SDKStringRecord = {};
      tags['sdk_data_id'] = 'uuid-1';
      tags['status'] = 'info';
      const fields: SDKStringRecord = {};
      fields['message'] = 'hello worker';
      fields['count'] = '3';
      const record: SDKLineProtocolInputDTO = {
        dataType: 'log',
        measurement: 'df_rum_harmonyos_log',
        tags,
        fields,
        time: 123,
        uuid: 'uuid-1'
      };
      const records: SDKLineProtocolInputDTO[] = [record];
      const payload: SDKLineProtocolRecordsTestPayload = {
        records
      };
      const request: SDKWorkerRequest = {
        id: 'line-protocol',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL,
        priority: 5,
        createdAt: Date.now(),
        payload: payload as Object as SDKWorkerPayload
      };

      const response = await executeWorkerCommandForUnit(request);
      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'drafts');
      expect(drafts.length).assertEqual(1);
      const draft = drafts[0] as Record<string, object>;
      expect(String(draft['dataString']).includes('df_rum_harmonyos_log')).assertTrue();
      expect(String(draft['dataString']).includes('message=\"hello worker\"')).assertTrue();
      expect(String(draft['uuid'])).assertEqual('uuid-1');
    });

    it('eventRumCommandShouldCreateSyncDraftFromSerializableDto', 0, async () => {
      const tags: SDKStringRecord = {};
      tags['sdk_data_id'] = 'rum-uuid-1';
      tags['session_id'] = 'session-1';
      tags['view_id'] = 'view-1';
      tags['view_name'] = 'Home';
      const fields: SDKStringRecord = {};
      fields['duration'] = '42';
      fields['is_active'] = 'true';
      const rumEvent: SDKRumEventDTO = {
        eventType: 'view.start',
        name: 'Home',
        time: 456,
        dataType: 'rum_app',
        measurement: 'view',
        uuid: 'rum-uuid-1',
        viewId: 'view-1',
        viewName: 'Home',
        sessionId: 'session-1',
        tags,
        fields
      };
      const request: SDKWorkerRequest = {
        id: 'rum-dto',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: rumEvent as Object as SDKWorkerPayload
      };

      const response = await executeWorkerCommandForUnit(request);
      expect(response.ok).assertTrue();
      expect(getPayloadString(response.payload, 'activeViewId')).assertEqual('view-1');
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const draft = drafts[0] as Record<string, object>;
      expect(String(draft['dataType'])).assertEqual('rum_app');
      expect(String(draft['uuid'])).assertEqual('rum-uuid-1');
      expect(String(draft['dataString']).includes('view')).assertTrue();
      expect(String(draft['dataString']).includes('sdk_data_id=rum-uuid-1')).assertTrue();
      expect(String(draft['dataString']).includes('duration=42i')).assertTrue();
    });

    it('eventRumBatchShouldDeriveSortAndDeduplicateRawEventsInWorker', 0, async () => {
      await executeWorkerCommandForUnit({
        id: 'rum-raw-context',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      });
      const viewId = 'view-1234567890abcdef-extra';
      const viewEvent = new Object() as SDKRumEventDTO;
      viewEvent.time = 300;
      viewEvent.dataType = 'rum_app';
      viewEvent.measurement = 'view';
      viewEvent.tags = new Object() as SDKStringRecord;
      viewEvent.tags['session_id'] = 'session-raw';
      viewEvent.tags['view_id'] = viewId;
      viewEvent.tags['view_name'] = 'RawView';
      viewEvent.fields = new Object() as SDKStringRecord;
      viewEvent.fields['is_active'] = 'true';
      viewEvent.fields['duration'] = '30';
      const actionEvent = new Object() as SDKRumEventDTO;
      actionEvent.time = 100;
      actionEvent.dataType = 'rum_app';
      actionEvent.measurement = 'action';
      actionEvent.tags = new Object() as SDKStringRecord;
      actionEvent.tags['session_id'] = 'session-raw';
      actionEvent.tags['view_id'] = viewId;
      actionEvent.tags['action_id'] = 'action-raw';
      actionEvent.tags['action_name'] = 'tap';
      actionEvent.fields = new Object() as SDKStringRecord;
      actionEvent.fields['duration'] = '10';
      const batch: SDKRumEventBatchDTO = {
        events: [viewEvent, actionEvent, viewEvent]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'rum-raw-batch',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      expect(getPayloadString(response.payload, 'activeViewId')).assertEqual(viewId);
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(2);
      const first = drafts[0] as Record<string, object>;
      const second = drafts[1] as Record<string, object>;
      expect(String(first['dataString']).startsWith('action,')).assertTrue();
      expect(String(second['dataString']).startsWith('view,')).assertTrue();
      expect(String(second['uuid'])).assertEqual(viewId.substring(0, 16));
      expect(String(second['dataString']).includes('env=worker-test')).assertTrue();

      const duplicateResponse = await executeWorkerCommandForUnit({
        id: 'rum-raw-duplicate',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: viewEvent as Object as SDKWorkerPayload
      });
      expect(getPayloadArray(duplicateResponse.payload, 'syncDrafts').length).assertEqual(0);
    });

    it('eventRumWorkerShouldFullyFormatRawWebViewData', 0, async () => {
      await executeWorkerCommandForUnit({
        id: 'rum-webview-context',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      });
      const webViewEvent = new Object() as SDKRumEventDTO;
      webViewEvent.time = 400;
      webViewEvent.dataType = 'rum_webview';
      webViewEvent.measurement = 'view';
      webViewEvent.tags = new Object() as SDKStringRecord;
      webViewEvent.tags['session_id'] = 'web-session';
      webViewEvent.tags['view_id'] = 'web-view-1234567890';
      webViewEvent.tags['view_name'] = 'WebView';
      webViewEvent.tags['service'] = 'browser';
      webViewEvent.tags['sdk_version'] = '2.3.4';
      webViewEvent.fields = new Object() as SDKStringRecord;
      webViewEvent.fields['duration'] = '42';
      webViewEvent.fields['is_active'] = 'true';
      const response = await executeWorkerCommandForUnit({
        id: 'rum-webview-raw',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: webViewEvent as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.includes('service=browser')).assertTrue();
      expect(line.includes('sdk_version=2.3.4')).assertTrue();
      expect(line.includes('env=worker-test')).assertTrue();
      expect(line.includes('custom_key=worker-value')).assertTrue();
      expect(line.includes('"web":"2.3.4"')).assertTrue();
      expect(line.includes('duration=42i')).assertTrue();

      const repeatedView = await executeWorkerCommandForUnit({
        id: 'rum-webview-repeat-view',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: webViewEvent as Object as SDKWorkerPayload
      });
      expect(getPayloadArray(repeatedView.payload, 'syncDrafts').length).assertEqual(1);

      const webViewAction = new Object() as SDKRumEventDTO;
      webViewAction.time = 500;
      webViewAction.dataType = 'rum_webview';
      webViewAction.measurement = 'action';
      webViewAction.tags = new Object() as SDKStringRecord;
      webViewAction.tags['session_id'] = 'web-session';
      webViewAction.tags['view_id'] = 'web-view-1234567890';
      webViewAction.fields = new Object() as SDKStringRecord;
      webViewAction.fields['action_id'] = '"web-action"';
      webViewAction.fields['action_name'] = '"click"';
      const actionBatch: SDKRumEventBatchDTO = { events: [webViewAction, webViewAction] };
      const actionResponse = await executeWorkerCommandForUnit({
        id: 'rum-webview-action-dedup',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: actionBatch as Object as SDKWorkerPayload
      });
      expect(getPayloadString(actionResponse.payload, 'activeActionId')).assertEqual('web-action');
      expect(getPayloadArray(actionResponse.payload, 'syncDrafts').length).assertEqual(1);
    });

    it('eventRumCounterShouldBatchSerializableCounterUpdates', 0, async () => {
      const updates: SDKRumCounterUpdateDTO[] = [
        {
          updateType: 'resource.pending.increase',
          viewId: 'view-1',
          actionId: 'action-1'
        },
        {
          updateType: 'resource.complete',
          viewId: 'view-1',
          actionId: 'action-1'
        },
        {
          updateType: 'view.action',
          viewId: 'view-1'
        }
      ];

      for (let i = 0; i < updates.length; i++) {
        const update = updates[i];
        const response = await executeWorkerCommandForUnit({
          id: `rum-counter-${i}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE,
          priority: 7,
          createdAt: Date.now(),
          payload: update as Object as SDKWorkerPayload
        });
        expect(response.ok).assertTrue();
      }

      const flushResponse = await executeWorkerCommandForUnit({
        id: 'rum-counter-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      expect(flushResponse.ok).assertTrue();
      expect(getPayloadString(flushResponse.payload, 'needsActionCloseCheck')).assertEqual('true');
      const deltas = getPayloadArray(flushResponse.payload, 'deltas');
      expect(deltas.length).assertEqual(2);
      let viewFinalized = '';
      let actionFinalized = '';
      for (let i = 0; i < deltas.length; i++) {
        const delta = deltas[i] as Record<string, object>;
        if (String(delta['actionId']) === 'action-1') {
          actionFinalized = `${String(delta['viewResourceDelta'])},${String(delta['actionResourceDelta'])},${String(delta['actionPendingDelta'])}`;
        } else if (String(delta['viewId']) === 'view-1') {
          viewFinalized = `${String(delta['viewResourceDelta'])},${String(delta['viewPendingDelta'])},${String(delta['viewActionDelta'])}`;
        }
      }
      expect(viewFinalized).assertEqual('1,0,1');
      expect(actionFinalized).assertEqual('0,1,0');
    });

    it('eventRumCounterBatchShouldCompactAndFinalizeByViewAndAction', 0, async () => {
      const updates: SDKRumCounterUpdateDTO[] = [];
      for (let i = 0; i < 2; i++) {
        updates.push({ updateType: 'resource.pending.increase', viewId: 'view-final', actionId: 'action-final' });
        updates.push({ updateType: 'resource.complete', viewId: 'view-final', actionId: 'action-final' });
        updates.push({ updateType: 'view.action', viewId: 'view-final' });
      }
      const batch: SDKRumCounterUpdateBatchDTO = { updates };
      const updateResponse = await executeWorkerCommandForUnit({
        id: 'rum-counter-compact',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });
      expect(updateResponse.ok).assertTrue();
      expect(getPayloadString(updateResponse.payload, 'pendingCount')).assertEqual('6');

      const flushResponse = await executeWorkerCommandForUnit({
        id: 'rum-counter-finalize',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      const deltas = getPayloadArray(flushResponse.payload, 'deltas');
      expect(deltas.length).assertEqual(2);
      const view = deltas[0] as Record<string, object>;
      const action = deltas[1] as Record<string, object>;
      expect(String(view['viewId'])).assertEqual('view-final');
      expect(String(view['actionId'])).assertEqual('');
      expect(String(view['viewResourceDelta'])).assertEqual('2');
      expect(String(view['viewPendingDelta'])).assertEqual('0');
      expect(String(view['viewActionDelta'])).assertEqual('2');
      expect(String(action['viewId'])).assertEqual('');
      expect(String(action['actionId'])).assertEqual('action-final');
      expect(String(action['actionResourceDelta'])).assertEqual('2');
      expect(String(action['actionPendingDelta'])).assertEqual('0');
    });

    it('eventRumLifecycleShouldTrackActionAndResourceStateFromDto', 0, async () => {
      const actionPayload: SDKRumEventDTO = {
        eventType: 'action.complete',
        name: 'tap',
        time: 100,
        actionId: 'action-1',
        actionName: 'tap',
        viewId: 'view-1',
        viewName: 'Home',
        sessionId: 'session-1'
      };
      const actionResponse = await executeWorkerCommandForUnit({
        id: 'rum-action-complete',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: actionPayload as Object as SDKWorkerPayload
      });
      expect(actionResponse.ok).assertTrue();
      expect(getPayloadString(actionResponse.payload, 'activeActionId')).assertEqual('');

      const resourceStartPayload: SDKRumEventDTO = {
        eventType: 'resource.start',
        name: 'https://example.com',
        time: 101,
        resourceId: 'resource-1',
        viewId: 'view-1',
        actionId: 'action-1',
        sessionId: 'session-1'
      };
      const startResponse = await executeWorkerCommandForUnit({
        id: 'rum-resource-start',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: resourceStartPayload as Object as SDKWorkerPayload
      });
      expect(startResponse.ok).assertTrue();
      expect(getPayloadString(startResponse.payload, 'activeResourceCount')).assertEqual('1');

      const resourceCompletePayload: SDKRumEventDTO = {
        eventType: 'resource.complete',
        name: 'https://example.com',
        time: 102,
        resourceId: 'resource-1',
        viewId: 'view-1',
        actionId: 'action-1',
        sessionId: 'session-1'
      };
      const completeResponse = await executeWorkerCommandForUnit({
        id: 'rum-resource-complete',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: resourceCompletePayload as Object as SDKWorkerPayload
      });
      expect(completeResponse.ok).assertTrue();
      expect(getPayloadString(completeResponse.payload, 'activeResourceCount')).assertEqual('0');
    });

    it('eventRumWorkerShouldNormalizeAndDeduplicateRawErrorProperties', 0, async () => {
      await executeWorkerCommandForUnit({
        id: 'rum-error-context',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      });
      const context: SDKRumResourceContextDTO = {
        sessionId: 'error-session',
        viewId: 'error-view',
        viewName: 'ErrorView',
        viewReferrer: 'root',
        actionId: 'error-action',
        actionName: 'tap'
      };
      const errorProperty = new Object() as SDKPropertyRecord;
      const customError = new Object() as SDKCompletedActionPropertyTestValue;
      customError.value = 'normalized';
      errorProperty['custom_error'] = customError;
      const customNested = new Object() as SDKCompletedActionPropertyTestValue;
      customNested.nested = 'yes';
      errorProperty['custom_nested'] = customNested;
      const errorCommand = new Object() as SDKRumErrorCommandDTO;
      errorCommand.context = context;
      errorCommand.log = 'stack-line';
      errorCommand.message = 'worker-error';
      errorCommand.errorType = 'TypeError';
      errorCommand.errorSource = 'logger';
      errorCommand.appState = 'run';
      errorCommand.property = errorProperty;
      errorCommand.time = 500;
      const batch: SDKRumErrorCommandBatchDTO = {
        commands: [errorCommand, errorCommand]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'rum-error-batch',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.includes('error_type=TypeError')).assertTrue();
      expect(line.includes('custom_error="normalized"')).assertTrue();
      expect(line.includes('custom_nested=')).assertTrue();
      expect(line.includes('stack-line')).assertTrue();
    });

    it('eventRumWorkerShouldSortMergeAndNormalizeResourceCommands', 0, async () => {
      await executeWorkerCommandForUnit({
        id: 'rum-resource-context',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      });
      const context: SDKRumResourceContextDTO = {
        sessionId: 'resource-session',
        viewId: 'resource-view',
        viewName: 'ResourceView',
        viewReferrer: 'root',
        actionId: 'resource-action',
        actionName: 'load'
      };
      const resourceProperty = new Object() as SDKPropertyRecord;
      const resourceDNS = new Object() as SDKCompletedActionPropertyTestValue;
      resourceDNS.value = 12;
      resourceProperty['resourceDNS'] = resourceDNS;
      const customResource = new Object() as SDKCompletedActionPropertyTestValue;
      customResource.value = 'normalized';
      resourceProperty['custom_resource'] = customResource;
      const params: SDKRumResourceParamsDTO = {
        url: 'https://example.com/users/123/profile?from=test',
        requestHeader: 'accept: application/json',
        responseHeader: 'content-type: application/json',
        responseConnection: 'keep-alive',
        responseContentType: 'application/json',
        responseContentEncoding: 'gzip',
        responseContentLength: 128,
        resourceMethod: 'GET',
        responseBody: '{}',
        resourceStatus: 200,
        resourceType: 'network',
        requestErrorStack: '',
        requestErrorMsg: '',
        property: resourceProperty
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 12,
        dnsStartTime: 1,
        tcpTime: 13,
        tcpStartTime: 13,
        sslTime: 14,
        sslStartTime: 26,
        ttfbTime: 15,
        responseTime: 16,
        firstByteTime: 17,
        firstByteStartTime: 40,
        downloadTime: 18,
        downloadStartTime: 57,
        holeRequestTime: 50,
        resourceHostIP: '127.0.0.1'
      };
      const start: SDKRumResourceCommandDTO = {
        commandType: 'start', resourceId: 'resource-worker', context, startTime: 10
      };
      const content: SDKRumResourceCommandDTO = {
        commandType: 'setContent', resourceId: 'resource-worker', context, params, eventTime: 20
      };
      const network: SDKRumResourceCommandDTO = {
        commandType: 'setNetState', resourceId: 'resource-worker', context, netStatus, eventTime: 30
      };
      const stop: SDKRumResourceCommandDTO = {
        commandType: 'stop', resourceId: 'resource-worker', context, endTime: 40
      };
      const batch: SDKRumResourceCommandBatchDTO = {
        commands: [stop, network, content, content, start]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'rum-resource-batch',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.startsWith('resource,')).assertTrue();
      expect(line.includes('resource_url_host=example.com')).assertTrue();
      expect(line.includes('resource_url_path_group=/users/?/profile')).assertTrue();
      expect(line.includes('custom_resource="normalized"')).assertTrue();
      expect(line.includes('resource_dns=12i')).assertTrue();
      expect(line.includes('duration=50i')).assertTrue();
    });

    it('eventRumCompletedActionShouldBuildLineProtocolInputFromDto', 0, async () => {
      const customText: SDKCompletedActionPropertyTestValue = { value: 'fast' };
      const customJson: SDKCompletedActionPropertyTestValue = { nested: 'yes' };
      const properties = new Object() as Record<string, object>;
      properties['custom_text'] = customText;
      properties['custom_json'] = customJson;
      const dynamicTags = new Object() as SDKStringRecord;
      dynamicTags['env'] = 'test';
      const completedAction = new Object() as SDKRumCompletedActionDTO;
      completedAction.dataType = 'rum_app';
      completedAction.measurement = 'action';
      completedAction.uuid = 'action-sync-uuid';
      completedAction.time = 12345;
      completedAction.dynamicTags = dynamicTags;
      completedAction.actionId = 'action-1';
      completedAction.actionName = 'tap';
      completedAction.actionType = 'click';
      completedAction.sessionId = 'session-1';
      completedAction.viewId = 'view-1';
      completedAction.viewName = 'Home';
      completedAction.viewReferrer = 'Launcher';
      completedAction.duration = 42;
      completedAction.errorCount = 1;
      completedAction.longTaskCount = 2;
      completedAction.resourceCount = 3;
      completedAction.properties = properties;

      const response = await executeWorkerCommandForUnit({
        id: 'rum-completed-action',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION,
        priority: 7,
        createdAt: Date.now(),
        payload: completedAction as Object as SDKWorkerPayload
      });
      expect(response.ok).assertTrue();
      const records = getPayloadArray(response.payload, 'records');
      expect(records.length).assertEqual(1);
      const record = records[0] as Record<string, object>;
      const tags = record['tags'] as Record<string, object>;
      const fields = record['fields'] as Record<string, object>;
      expect(String(record['measurement'])).assertEqual('action');
      expect(String(record['uuid'])).assertEqual('action-sync-uuid');
      expect(String(tags['action_id'])).assertEqual('action-1');
      expect(String(tags['action_type'])).assertEqual('click');
      expect(String(tags['view_id'])).assertEqual('view-1');
      expect(String(fields['duration'])).assertEqual('42');
      expect(String(fields['action_error_count'])).assertEqual('1');
      expect(String(fields['action_long_task_count'])).assertEqual('2');
      expect(String(fields['action_resource_count'])).assertEqual('3');
      expect(String(fields['custom_text'])).assertEqual('fast');
      expect(String(fields['custom_json']).includes('nested')).assertTrue();
    });

    it('dataUploadCommandShouldFormatBodyInsideUploadPoolWithoutDeadlock', 0, async () => {
      const row: SDKUploadRowDTO = {
        id: 1,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=uuid-1 message=\"hello\" 123',
        uuid: 'uuid-1',
        time: 123
      };
      const page: SDKUploadPageDTO = {
        dataType: 'log',
        rows: [row],
        packageId: 'pkg-1'
      };
      const request: SDKWorkerRequest = {
        id: 'upload-format-body',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_FORMAT_BODY,
        priority: 5,
        createdAt: Date.now(),
        payload: page as Object as SDKWorkerPayload
      };

      const response = await executeWorkerCommandForUnit(request);
      expect(response.ok).assertTrue();
      const body = getPayloadString(response.payload, 'body');
      expect(body.includes('pkg-1.uuid-1')).assertTrue();
      expect(body.includes('message=\"hello\"')).assertTrue();
    });

    it('dataUploadWorkerShouldOwnDedupPackagingPaginationAndRetryState', 0, async () => {
      const startPayload: SDKUploadRoundStartDTO = {
        ownerId: 'unit-upload-owner',
        taskName: 'unit-upload-round',
        pageSize: 2,
        syncSleepTime: 10
      };
      const startResponse = await executeWorkerCommandForUnit({
        id: 'upload-round-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      });
      expect(startResponse.ok).assertTrue();
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;

      const row: SDKUploadRowDTO = {
        id: 1,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=retry-uuid message=\"hello\" 123',
        uuid: 'retry-uuid',
        time: 123
      };
      const duplicate: SDKUploadRowDTO = {
        id: 2,
        dataType: 'log',
        dataString: row.dataString,
        uuid: row.uuid,
        time: row.time
      };
      const executePayload: SDKUploadExecutePageDTO = {
        roundId: start.roundId,
        dataType: 'log',
        rows: [row, duplicate],
        httpConfig: {
          datakitUrl: 'https://localhost',
          datawayUrl: '',
          clientToken: '',
          model: 'logging_v1',
          deviceTimeMs: 100,
          connectTimeoutMs: 60_000,
          readTimeoutMs: 60_000,
          softTimeoutMs: 125_000
        }
      };
      const httpExecutor = new RetryUploadHttpExecutor();
      const executeResponse = await handleSDKDataUploadWorkerRequest({
        id: 'upload-execute-page',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, unitWorkerStates[SDKDedicatedPoolType.DATA_UPLOAD], httpExecutor);
      expect(executeResponse.ok).assertTrue();
      const executed = executeResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(executed.acceptedRows).assertEqual(1);
      expect(executed.duplicateRows).assertEqual(1);
      expect(executed.shouldUpload).assertTrue();
      expect(executed.bodyLength > 0).assertTrue();
      expect(executed.bodyPreview.includes(`${executed.packageId}.retry-uuid`)).assertTrue();
      expect(httpExecutor.lastRequest !== null).assertTrue();
      expect((httpExecutor.lastRequest as SDKUploadHttpRequestDTO).body.includes(
        `${executed.packageId}.retry-uuid`)).assertTrue();
      expect(executed.dbAction).assertEqual(SDKUploadDbActionDTO.REINSERT);
      expect(executed.reInsertRows.length).assertEqual(1);
      expect(executed.retryCount).assertEqual(1);
      expect(executed.delayMs).assertEqual(500);
      expect(executed.shouldContinueDataType).assertFalse();
      expect(executed.roundHasMoreData).assertTrue();
      expect(executed.checkpointAfterCommit.version).assertEqual(1);

      const commitPayload: SDKUploadCommitPageDTO = {
        roundId: start.roundId,
        attemptId: executed.attemptId,
        dbSucceeded: true
      };
      const commitResponse = await executeWorkerCommandForUnit({
        id: 'upload-commit-page',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: commitPayload as Object as SDKWorkerPayload
      });
      expect(commitResponse.ok).assertTrue();
      const committed = commitResponse.payload as Object as SDKUploadCommitPageResultDTO;
      expect(committed.checkpoint.version).assertEqual(1);
      expect(committed.errorCount).assertEqual(1);
      expect(committed.delayMs).assertEqual(500);
      expect(committed.shouldContinueDataType).assertFalse();
      expect(committed.roundHasMoreData).assertTrue();

      const finishPayload: SDKUploadRoundFinishDTO = { roundId: start.roundId };
      const finishResponse = await executeWorkerCommandForUnit({
        id: 'upload-consume-finish',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME_FINISH,
        priority: 5,
        createdAt: Date.now(),
        payload: finishPayload as Object as SDKWorkerPayload
      });
      expect(finishResponse.ok).assertTrue();
      const finished = finishResponse.payload as Object as SDKUploadRoundResultDTO;
      expect(finished.consumedRows).assertEqual(1);
      expect(finished.hasMoreData).assertTrue();
      expect(finished.errorCount).assertEqual(1);
    });

    it('dataUploadWorkerShouldStopAutomaticRetryAfterConfiguredLimit', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'RetryLimitWorker', 'unit-worker');
      const startPayload: SDKUploadRoundStartDTO = {
        ownerId: 'retry-limit-owner',
        taskName: 'retry-limit-first',
        pageSize: 1,
        syncSleepTime: 0,
        maxRetryCount: 1
      };
      const firstStartResponse = handleSDKWorkerRequest({
        id: 'retry-limit-first-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      }, state);
      const firstStart = firstStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const row: SDKUploadRowDTO = {
        id: 31,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=retry-limit value=1i 100',
        uuid: 'retry-limit',
        time: 100
      };
      const executePayload: SDKUploadExecutePageDTO = {
        roundId: firstStart.roundId,
        dataType: 'log',
        rows: [row],
        httpConfig: {
          datakitUrl: 'https://localhost',
          datawayUrl: '',
          clientToken: '',
          model: 'logging_v1',
          deviceTimeMs: 100,
          connectTimeoutMs: 60_000,
          readTimeoutMs: 60_000,
          softTimeoutMs: 125_000
        }
      };
      const retryExecutor = new RetryUploadHttpExecutor(500);
      const firstExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'retry-limit-first-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, state, retryExecutor);
      const firstExecuted = firstExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(firstExecuted.retryCount).assertEqual(1);
      expect(firstExecuted.retryLimitReached).assertFalse();
      expect(firstExecuted.roundHasMoreData).assertTrue();
      expect(firstExecuted.delayMs).assertEqual(500);

      const firstCommit: SDKUploadCommitPageDTO = {
        roundId: firstStart.roundId,
        attemptId: firstExecuted.attemptId,
        dbSucceeded: true
      };
      const firstFinish: SDKUploadRoundFinishDTO = { roundId: firstStart.roundId };
      handleSDKWorkerRequest({
        id: 'retry-limit-first-commit',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: firstCommit as Object as SDKWorkerPayload
      }, state);
      handleSDKWorkerRequest({
        id: 'retry-limit-first-finish',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME_FINISH,
        priority: 5,
        createdAt: Date.now(),
        payload: firstFinish as Object as SDKWorkerPayload
      }, state);

      startPayload.taskName = 'retry-limit-terminal';
      const terminalStartResponse = handleSDKWorkerRequest({
        id: 'retry-limit-terminal-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      }, state);
      const terminalStart = terminalStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      executePayload.roundId = terminalStart.roundId;
      const terminalExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'retry-limit-terminal-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, state, retryExecutor);
      const terminal = terminalExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(terminal.retryCount).assertEqual(2);
      expect(terminal.retryLimitReached).assertTrue();
      expect(terminal.roundHasMoreData).assertFalse();
      expect(terminal.delayMs).assertEqual(0);
      expect(terminal.dbAction).assertEqual(SDKUploadDbActionDTO.REINSERT);
    });

    it('dataUploadWorkerShouldClampPageAndSplitBodyAtUtf8ByteLimit', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'BodyLimitWorker', 'unit-worker');
      const startPayload: SDKUploadRoundStartDTO = {
        ownerId: 'body-limit-owner',
        taskName: 'body-limit',
        pageSize: DATA_UPLOAD_MAX_PAGE_SIZE + 1000,
        syncSleepTime: 0,
        maxRetryCount: DATA_UPLOAD_MAX_RETRY_COUNT + 100
      };
      const startResponse = handleSDKWorkerRequest({
        id: 'body-limit-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      expect(start.pageSize).assertEqual(DATA_UPLOAD_MAX_PAGE_SIZE);
      expect(start.maxRetryCount).assertEqual(DATA_UPLOAD_MAX_RETRY_COUNT);

      const largeMessage = 'x'.repeat(Math.floor(DATA_UPLOAD_MAX_BODY_BYTES * 0.6));
      const rows: SDKUploadRowDTO[] = [{
        id: 41,
        dataType: 'log',
        dataString: `df_rum_harmonyos_log,sdk_data_id=body-limit-one message="${largeMessage}" 100`,
        uuid: 'body-limit-one',
        time: 100
      }, {
        id: 42,
        dataType: 'log',
        dataString: `df_rum_harmonyos_log,sdk_data_id=body-limit-two message="${largeMessage}" 101`,
        uuid: 'body-limit-two',
        time: 101
      }];
      const executePayload: SDKUploadExecutePageDTO = {
        roundId: start.roundId,
        dataType: 'log',
        rows,
        httpConfig: {
          datakitUrl: 'https://localhost',
          datawayUrl: '',
          clientToken: '',
          model: 'logging_v1',
          deviceTimeMs: 100,
          connectTimeoutMs: 60_000,
          readTimeoutMs: 60_000,
          softTimeoutMs: 125_000
        }
      };
      const successExecutor = new RetryUploadHttpExecutor(200);
      const executeResponse = await handleSDKDataUploadWorkerRequest({
        id: 'body-limit-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, state, successExecutor);
      const executed = executeResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(executed.acceptedRows).assertEqual(1);
      expect(executed.deferredRows).assertEqual(1);
      expect(executed.bodyLimitReached).assertTrue();
      expect(executed.bodyBytes <= DATA_UPLOAD_MAX_BODY_BYTES).assertTrue();
      expect((successExecutor.lastRequest as SDKUploadHttpRequestDTO).body.length > 0).assertTrue();

      const commitPayload: SDKUploadCommitPageDTO = {
        roundId: start.roundId,
        attemptId: executed.attemptId,
        dbSucceeded: true
      };
      const commitResponse = handleSDKWorkerRequest({
        id: 'body-limit-commit',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: commitPayload as Object as SDKWorkerPayload
      }, state);
      const committed = commitResponse.payload as Object as SDKUploadCommitPageResultDTO;
      expect(committed.roundHasMoreData).assertTrue();
    });

    it('dataUploadWorkerShouldRestoreHostCheckpointAfterAckWindowRestart', 0, async () => {
      const firstState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'DataUploadFirstWorker', 'unit-worker');
      const ownerId = 'checkpoint-owner';
      const firstStartPayload: SDKUploadRoundStartDTO = {
        ownerId,
        taskName: 'checkpoint-first',
        pageSize: 1,
        syncSleepTime: 0
      };
      const firstStartResponse = handleSDKWorkerRequest({
        id: 'checkpoint-first-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: firstStartPayload as Object as SDKWorkerPayload
      }, firstState);
      const firstStart = firstStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const firstExecutePayload: SDKUploadExecutePageDTO = {
        roundId: firstStart.roundId,
        dataType: 'log',
        rows: [{
          id: 11,
          dataType: 'log',
          dataString: 'df_rum_harmonyos_log,sdk_data_id=checkpoint-one value=1i 100',
          uuid: 'checkpoint-one',
          time: 100
        }],
        httpConfig: {
          datakitUrl: 'https://localhost',
          datawayUrl: '',
          clientToken: '',
          model: 'logging_v1',
          deviceTimeMs: 100,
          connectTimeoutMs: 60_000,
          readTimeoutMs: 60_000,
          softTimeoutMs: 125_000
        }
      };
      const successExecutor = new RetryUploadHttpExecutor(200);
      const firstExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'checkpoint-first-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: firstExecutePayload as Object as SDKWorkerPayload
      }, firstState, successExecutor);
      const firstExecuted = firstExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(firstExecuted.checkpointAfterCommit.version).assertEqual(1);
      expect(firstExecuted.checkpointAfterCommit.logSequence).assertEqual(1);
      expect(firstState.uploadCheckpointVersion).assertEqual(0);

      // Simulate DB success followed by Worker loss before UPLOAD_COMMIT_PAGE.
      // The Host retained checkpoint must seed the replacement Worker.
      const replacementState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'DataUploadReplacementWorker', 'unit-worker');
      const replacementStartPayload: SDKUploadRoundStartDTO = {
        ownerId,
        taskName: 'checkpoint-replacement',
        pageSize: 1,
        syncSleepTime: 0,
        checkpoint: firstExecuted.checkpointAfterCommit
      };
      const replacementStartResponse = handleSDKWorkerRequest({
        id: 'checkpoint-replacement-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: replacementStartPayload as Object as SDKWorkerPayload
      }, replacementState);
      const replacementStart = replacementStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      expect(replacementStart.checkpoint.version).assertEqual(1);
      expect(replacementStart.checkpoint.logSequence).assertEqual(1);
      expect(replacementStart.checkpoint.processId).assertEqual(firstExecuted.checkpointAfterCommit.processId);

      firstExecutePayload.roundId = replacementStart.roundId;
      firstExecutePayload.rows = [{
        id: 12,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=checkpoint-two value=1i 101',
        uuid: 'checkpoint-two',
        time: 101
      }];
      const replacementExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'checkpoint-replacement-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: firstExecutePayload as Object as SDKWorkerPayload
      }, replacementState, successExecutor);
      const replacementExecuted = replacementExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(replacementExecuted.packageId.startsWith('1.')).assertTrue();
      expect(replacementExecuted.checkpointAfterCommit.version).assertEqual(2);
      expect(replacementExecuted.checkpointAfterCommit.logSequence).assertEqual(2);
    });
  });
}
