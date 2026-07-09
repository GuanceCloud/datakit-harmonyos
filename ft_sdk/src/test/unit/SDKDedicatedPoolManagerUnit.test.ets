import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKDedicatedPoolManager
} from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKLineProtocolInputDTO,
  SDKRumCompletedActionDTO,
  SDKRumCounterUpdateDTO,
  SDKRumEventDTO,
  SDKStringRecord,
  SDKUploadPageDTO,
  SDKUploadRowDTO,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../../main/ets/components/thread/SDKWorkerProtocol';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerRuntimeState
} from '../../main/ets/components/thread/SDKWorkerBusinessHandlers';

interface SDKLineProtocolRecordsTestPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SDKCompletedActionPropertyTestValue {
  value?: string;
  nested?: string;
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
      let resourceJoined = '';
      let viewActionDelta = '';
      for (let i = 0; i < deltas.length; i++) {
        const delta = deltas[i] as Record<string, object>;
        if (String(delta['actionId']) === 'action-1') {
          resourceJoined = `${String(delta['viewResourceDelta'])},${String(delta['viewPendingDelta'])},${String(delta['actionResourceDelta'])},${String(delta['actionPendingDelta'])}`;
        } else {
          viewActionDelta = String(delta['viewActionDelta']);
        }
      }
      expect(resourceJoined).assertEqual('1,0,1,0');
      expect(viewActionDelta).assertEqual('1');
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
  });
}
