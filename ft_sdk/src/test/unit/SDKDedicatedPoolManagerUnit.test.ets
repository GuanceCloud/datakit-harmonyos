import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import {
  SDKDedicatedPoolManager
} from '../../main/ets/components/thread/SDKDedicatedPoolManager';
import {
  SDKDedicatedPoolType,
  SDKANRParseRequestDTO,
  SDKLineProtocolContextDTO,
  SDKLineProtocolInputDTO,
  SDKPropertyRecord,
  SDKRumCompletedActionBatchDTO,
  SDKRumCompletedActionDTO,
  SDKRumCounterDeltaDTO,
  SDKRumCounterUpdateBatchDTO,
  SDKRumCounterUpdateDTO,
  SDKRumErrorCommandBatchDTO,
  SDKRumErrorCommandDTO,
  SDKRumEventBatchDTO,
  SDKRumEventDTO,
  SDKRumResourceCommandBatchDTO,
  SDKRumResourceCommandDTO,
  SDKRumResourceContextDTO,
  SDKRumResourceNetworkSnapshotDTO,
  SDKRumResourceNetStatusDTO,
  SDKRumResourceParamsDTO,
  SDKRumResourceTransportMetricsDTO,
  SDKStringRecord,
  SDKUploadCommitPageDTO,
  SDKUploadCommitPageResultDTO,
  SDKUploadDbActionDTO,
  SDKUploadExecutePageDTO,
  SDKUploadExecutePageResultDTO,
  SDKUploadHttpConfigDTO,
  SDKUploadHttpProxyDTO,
  SDKUploadHttpRequestDTO,
  SDKUploadHttpResultDTO,
  SDKUploadPageDTO,
  SDKUploadPreparePageDTO,
  SDKUploadPreparePageResultDTO,
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
  DATA_UPLOAD_BODY_TARGET_BYTES,
  DATA_UPLOAD_MAX_PAGE_SIZE,
  DATA_UPLOAD_MAX_RETRY_COUNT
} from '../../main/ets/components/thread/workers/DataUploadLimits';
import { awaitDataUploadHttpResult } from '../../main/ets/components/thread/workers/DataUploadSoftTimeout';
import {
  DataUploadPayloadCompressor,
  resetDataUploadPayloadCompressorInternal,
  setDataUploadPayloadCompressorInternal
} from '../../main/ets/components/thread/workers/DataUploadCompression';
import {
  createDataUploadHeaders,
  getDataUploadRequestBody
} from '../../main/ets/components/thread/workers/DataUploadHttpRequest';
import { createDataUploadNetworkOptions } from '../../main/ets/components/thread/workers/DataUploadNetworkOptions';
import { NetCodeStatus } from '../../main/ets/components/http/HttpEngine';
import {
  isSDKWorkerExternalSideEffectCommand,
  isSDKWorkerInFlightReplaySafe,
  isSDKWorkerMailboxReplaySafe
} from '../../main/ets/components/thread/SDKWorkerReplayPolicy';
import { parseANREventInWorker } from '../../main/ets/components/thread/workers/ANRWorkerOperations';
import { normalizeANRParamsForWorker } from '../../main/ets/components/monitor/ANRDetectManager';
import {
  calculateBatteryUsagePercent,
  calculateSystemMemoryUsagePercent,
  formatAndroidLocale,
  normalizeProcessCpuUsage
} from '../../main/ets/components/utils/DeviceUtils';
import { MonitorInfoBean } from '../../main/ets/components/rum/bean/MonitorInfoBean';
import {
  parseProcStatCpuTicks,
  parseProcStatusMemoryBytes
} from '../../main/ets/components/thread/workers/BackgroundWorkerOperations';

interface SDKLineProtocolRecordsTestPayload {
  records: SDKLineProtocolInputDTO[];
}

interface SDKCompletedActionPropertyTestValue {
  value?: string | number;
  nested?: string;
}

interface SDKCompletedActionLaunchPhaseTestValue {
  start: number;
  duration: number;
}

class SDKCrashFreeDurationTestCase {
  public readonly marker: string;
  public readonly errorType: string;
  public readonly foregroundNs: number;
  public readonly backgroundNs: number;

  public constructor(marker: string, errorType: string, foregroundNs: number, backgroundNs: number) {
    this.marker = marker;
    this.errorType = errorType;
    this.foregroundNs = foregroundNs;
    this.backgroundNs = backgroundNs;
  }
}

class SDKNonCrashErrorTestCase {
  public readonly marker: string;
  public readonly errorType: string;

  public constructor(marker: string, errorType: string) {
    this.marker = marker;
    this.errorType = errorType;
  }
}

interface SDKANRTestFrame {
  file: string;
  line: number;
  column: number;
  symbol: string;
}

interface SDKANRTestThread {
  thread_name: string;
  tid: number;
  frames: SDKANRTestFrame[];
}

interface SDKANRTestParams {
  freeze_type: string;
  foreground: boolean;
  process_name: string;
  threads: SDKANRTestThread[];
  time?: number;
  uuid?: string;
}

function createRumWorkerLineContext(): SDKLineProtocolContextDTO {
  const context = new Object() as SDKLineProtocolContextDTO;
  context.basePublicTags = new Object() as SDKStringRecord;
  context.logTags = new Object() as SDKStringRecord;
  context.rumTags = new Object() as SDKStringRecord;
  context.rumTags['service'] = 'native-service';
  context.rumTags['app_id'] = 'gc_app_harmonyos_demo';
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

function createTransportResourceCommandsForUnit(
  resourceId: string,
  metrics?: SDKRumResourceTransportMetricsDTO,
  deferred?: SDKRumResourceTransportMetricsDTO
): SDKRumResourceCommandDTO[] {
  const context: SDKRumResourceContextDTO = {
    sessionId: 'transport-session', viewId: 'transport-view', viewName: 'TransportView',
    viewReferrer: '', actionId: 'transport-action', actionName: 'request'
  };
  const params: SDKRumResourceParamsDTO = {
    url: 'https://example.com/same-url', requestHeader: '', responseHeader: '', responseConnection: '',
    responseContentType: '', responseContentEncoding: '', responseContentLength: 0, resourceMethod: 'POST',
    responseBody: '', resourceStatus: 200, resourceType: 'network', requestErrorStack: '', requestErrorMsg: '',
    property: {}, transportMetrics: metrics
  };
  const netStatus: SDKRumResourceNetStatusDTO = {
    dnsTime: 0, dnsStartTime: 0, tcpTime: 0, tcpStartTime: 0, sslTime: 0, sslStartTime: 0,
    ttfbTime: 0, responseTime: 0, firstByteTime: 0, firstByteStartTime: 0, downloadTime: 0,
    downloadStartTime: 0, holeRequestTime: 80, resourceHostIP: '', transportMetrics: deferred
  };
  return [
    { commandType: 'start', resourceId, context, startTime: 100, draftUuid: resourceId },
    { commandType: 'setContent', resourceId, context, params, eventTime: 120 },
    { commandType: 'setNetState', resourceId, context, netStatus, eventTime: 140 },
    { commandType: 'stop', resourceId, context, endTime: 180 }
  ];
}

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

async function getRumWorkerSnapshotForUnit(id: string): Promise<SDKWorkerResponse> {
  return executeWorkerCommandForUnit({
    id,
    pool: SDKDedicatedPoolType.EVENT_CONSUMER,
    command: SDKWorkerCommand.EVENT_RUM_SNAPSHOT,
    priority: 7,
    createdAt: Date.now()
  });
}

class RetryUploadHttpExecutor implements SDKUploadWorkerHttpExecutor {
  lastRequest: SDKUploadHttpRequestDTO | null = null;
  private readonly responseCode: number;
  private readonly softTimedOut: boolean;

  constructor(responseCode: number = 500, softTimedOut: boolean = false) {
    this.responseCode = responseCode;
    this.softTimedOut = softTimedOut;
  }

  async execute(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO> {
    this.lastRequest = request;
    return {
      code: this.responseCode,
      message: this.responseCode === 200 ? 'ok' : 'retry',
      errorCode: String(this.responseCode),
      elapsedMs: 3,
      softTimedOut: this.softTimedOut
    };
  }
}

/**
 * Keeps the upload protocol unit tests independent of the device zlib service.
 * Native zlib output is verified by the device test suite; these tests only
 * assert that a successfully prepared binary payload is carried to HTTP.
 */
class FixedPayloadCompressor implements DataUploadPayloadCompressor {
  lastBody: string = '';

  async compress(body: string): Promise<ArrayBuffer> {
    this.lastBody = body;
    const payload = new ArrayBuffer(4);
    const bytes = new Uint8Array(payload);
    bytes[0] = 0x78;
    bytes[1] = 0x9c;
    bytes[2] = 0x01;
    bytes[3] = 0x00;
    return payload;
  }
}

export default function sdkDedicatedPoolManagerUnitTest() {
  describe('SDKDedicatedPoolManagerUnit', () => {
    let manager: SDKDedicatedPoolManager;

    beforeEach(() => {
      SDKDedicatedPoolManager.resetInternal();
      manager = SDKDedicatedPoolManager.getInstance();
      resetUnitWorkerStates();
      resetDataUploadPayloadCompressorInternal();
    });

    afterEach(() => {
      SDKDedicatedPoolManager.resetInternal();
      resetDataUploadPayloadCompressorInternal();
    });

    it('dataProcessUseConfiguredWorkerCount', 0, async () => {
      const workerCount = manager.getDataProcessWorkerCount();
      expect(workerCount).assertEqual(1);
      const status = manager.getStatus().pools[SDKDedicatedPoolType.DATA_PROCESS];
      expect(status.workerCount).assertEqual(workerCount);
    });

    it('uploadUseOneStateOwnerWorker', 0, async () => {
      const status = manager.getStatus().pools[SDKDedicatedPoolType.DATA_UPLOAD];
      expect(status.workerCount).assertEqual(1);
      expect(status.maxConcurrency).assertEqual(1);
      expect(status.commandReplayCount).assertEqual(0);
      expect(status.mailboxReplayCount).assertEqual(0);
      expect(status.mailboxReplayPending).assertEqual(0);
      expect(status.mailboxReplayDropped).assertEqual(0);
    });

    it('replayExcludesUploadSideEffects', 0, () => {
      expect(isSDKWorkerInFlightReplaySafe(SDKWorkerCommand.EVENT_RUM_COMMAND)).assertTrue();
      expect(isSDKWorkerMailboxReplaySafe(SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH)).assertTrue();
      expect(isSDKWorkerInFlightReplaySafe(SDKWorkerCommand.UPLOAD_EXECUTE_PAGE)).assertFalse();
      expect(isSDKWorkerMailboxReplaySafe(SDKWorkerCommand.UPLOAD_EXECUTE_PAGE)).assertFalse();
      expect(isSDKWorkerExternalSideEffectCommand(SDKWorkerCommand.UPLOAD_EXECUTE_PAGE)).assertTrue();
      expect(isSDKWorkerExternalSideEffectCommand(SDKWorkerCommand.UPLOAD_COMMIT_PAGE)).assertTrue();
      expect(isSDKWorkerExternalSideEffectCommand(SDKWorkerCommand.EVENT_RUM_COMMAND)).assertFalse();
    });

    it('workerRejectsNonSerializablePayload', 0, async () => {
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

    it('workerPoolsReturnIndependentPings', 0, async () => {
      const pools: SDKDedicatedPoolType[] = [
        SDKDedicatedPoolType.CRASH,
        SDKDedicatedPoolType.ANR
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
      expect(status[SDKDedicatedPoolType.CRASH].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.CRASH].idleTimeoutMs).assertEqual(120000);
      expect(status[SDKDedicatedPoolType.ANR].maxConcurrency).assertEqual(1);
      expect(status[SDKDedicatedPoolType.ANR].idleTimeoutMs).assertEqual(90000);
      expect(status[SDKDedicatedPoolType.ANR].idleRecycleCount).assertEqual(0);
      expect(status[SDKDedicatedPoolType.DATA_PROCESS].idleTimeoutMs).assertEqual(0);
    });

    it('anrWorkerFormatsFreezeWithoutHostIo', 0, () => {
      const frame: SDKANRTestFrame = {
        file: 'Index.ets',
        line: 12,
        column: 3,
        symbol: 'onClick'
      };
      const thread: SDKANRTestThread = {
        thread_name: 'main',
        tid: 1,
        frames: [frame]
      };
      const params: SDKANRTestParams = {
        freeze_type: 'THREAD_BLOCK_6S',
        foreground: true,
        process_name: 'demo',
        threads: [thread],
        time: 9988,
        uuid: 'freeze-event-id'
      };
      const payload: SDKANRParseRequestDTO = {
        eventName: 'APP_FREEZE',
        params: params as Object,
        dateline: 9988,
        systemLogDirs: []
      };

      const result = parseANREventInWorker(payload);
      expect(result.stackTrace.includes('App freeze detected: APP_FREEZE')).assertTrue();
      expect(result.stackTrace.includes('onClick (Index.ets:12:3)')).assertTrue();
      expect(result.properties['freeze_type']).assertEqual('THREAD_BLOCK_6S');
      expect(result.properties['timestamp']).assertEqual('9988');
      expect(result.properties['uuid']).assertEqual('freeze-event-id');
      expect(result.foreground).assertTrue();
      expect(result.dateline).assertEqual(9988);
      expect(result.filesRead).assertEqual(0);
    });

    it('anrEnvelopeBoundsAllowedParams', 0, () => {
      const sources: Array<Record<string, Object>> = [];
      for (let sourceIndex = 0; sourceIndex < 12; sourceIndex++) {
        const frames: Object[] = [];
        for (let frameIndex = 0; frameIndex < 140; frameIndex++) {
          const frame = new Object() as Record<string, Object>;
          frame['file'] = `Index-${frameIndex}.ets`;
          frame['line'] = frameIndex;
          frame['symbol'] = 'x'.repeat(5000);
          frame['ignored'] = 'must-not-cross-worker-mailbox';
          frames.push(frame);
        }
        const threads: Object[] = [];
        for (let threadIndex = 0; threadIndex < 20; threadIndex++) {
          const thread = new Object() as Record<string, Object>;
          thread['thread_name'] = `thread-${threadIndex}`;
          thread['tid'] = threadIndex;
          thread['frames'] = frames;
          thread['ignored'] = 'must-not-cross-worker-mailbox';
          threads.push(thread);
        }
        const hilog: Object[] = [];
        for (let lineIndex = 0; lineIndex < 60; lineIndex++) {
          hilog.push('h'.repeat(3000));
        }
        const source = new Object() as Record<string, Object>;
        source['freeze_type'] = `freeze-${sourceIndex}`;
        source['stack_trace'] = 's'.repeat(70 * 1024);
        source['hilog'] = hilog;
        source['threads'] = threads;
        source['unknown_payload'] = 'must-not-cross-worker-mailbox';
        sources.push(source);
      }

      const normalized = normalizeANRParamsForWorker(sources);
      const normalizedThreads = normalized['threads'] as Object[];
      const firstThread = normalizedThreads[0] as Record<string, Object>;
      const normalizedFrames = firstThread['frames'] as Object[];
      const firstFrame = normalizedFrames[0] as Record<string, Object>;
      const normalizedHilog = normalized['hilog'] as Object[];

      expect(String(normalized['freeze_type'])).assertEqual('freeze-11');
      expect(String(normalized['stack_trace']).length).assertEqual(64 * 1024);
      expect(normalizedHilog.length).assertEqual(50);
      expect(String(normalizedHilog[0]).length).assertEqual(2048);
      expect(normalizedThreads.length).assertEqual(16);
      expect(normalizedFrames.length).assertEqual(128);
      expect(String(firstFrame['symbol']).length).assertEqual(4096);
      expect(firstFrame['ignored'] === undefined).assertTrue();
      expect(normalized['unknown_payload'] === undefined).assertTrue();
    });

    it('workerParsesProcMetrics', 0, () => {
      const stat = '123 (demo process) S 1 2 3 4 5 6 7 8 9 10 120 30 0 0';
      expect(parseProcStatCpuTicks(stat)).assertEqual(120);
      expect(parseProcStatusMemoryBytes('Name:\tdemo\nVmRSS:\t20480 kB\n')).assertEqual(20480000);
      expect(parseProcStatCpuTicks('invalid')).assertEqual(-1);
      expect(parseProcStatusMemoryBytes('VmSize: 10 kB')).assertEqual(-1);
    });

    it('errorMonitorMetricUnitsMatchAndroid', 0, () => {
      // Android reports device memory occupancy (not app PSS) as a percentage.
      expect(calculateSystemMemoryUsagePercent(8 * 1024 * 1024, 2 * 1024 * 1024)).assertEqual(75);
      // HiDebug reports a 0–1 process ratio; Android normalizes its top value by cores.
      expect(normalizeProcessCpuUsage(0.5, 4)).assertEqual(12.5);
      // Android's battery_use means consumed battery, not remaining SOC.
      expect(calculateBatteryUsagePercent(20)).assertEqual(80);
      expect(calculateBatteryUsagePercent(120)).assertEqual(0);
      expect(formatAndroidLocale('zh-Hans-CN')).assertEqual('zh_CN_#Hans');
      expect(formatAndroidLocale('en-US')).assertEqual('en_US');

      const battery = new MonitorInfoBean();
      battery.addBatteryCurrentValue(-300);
      battery.addBatteryCurrentValue(-100);
      expect(battery.maxValue).assertEqual(0);
      expect(battery.miniValue).assertEqual(-300);
      expect(battery.avgValue).assertEqual(-200);
    });

    it('dataProcessBuildsDraftsFromDto', 0, async () => {
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

    it('rumBuildsDraftFromDto', 0, async () => {
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

    it('errorSampledViewKeepsEventTimeButStagesAtSnapshotOrErrorTime', 0, async () => {
      const tags = new Object() as SDKStringRecord;
      tags['session_id'] = 'sampled-session';
      tags['view_id'] = 'sampled-view';
      const fields = new Object() as SDKStringRecord;
      fields['is_active'] = 'true';
      const errorSampledView: SDKRumEventDTO = {
        time: 100, storageTime: 300, dataType: 'rum_app', customDataType: 'rum_app_error_sampled',
        measurement: 'view', uuid: 'sampled-view-uuid', tags, fields
      };
      const response = await executeWorkerCommandForUnit({
        id: 'error-sampled-view-storage-time', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND, priority: 7, createdAt: Date.now(),
        payload: errorSampledView as Object as SDKWorkerPayload
      });
      expect(response.ok).assertTrue();
      const draft = getPayloadArray(response.payload, 'syncDrafts')[0] as Record<string, object>;
      expect(Number(draft['time'])).assertEqual(300);
      expect(String(draft['dataString']).trim().endsWith(' 100')).assertTrue();

      const ordinaryView: SDKRumEventDTO = {
        time: 200, dataType: 'rum_app', measurement: 'view', uuid: 'ordinary-view-uuid', tags, fields
      };
      const ordinaryResponse = await executeWorkerCommandForUnit({
        id: 'ordinary-view-storage-time', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND, priority: 7, createdAt: Date.now(),
        payload: ordinaryView as Object as SDKWorkerPayload
      });
      const ordinaryDraft = getPayloadArray(ordinaryResponse.payload, 'syncDrafts')[0] as Record<string, object>;
      expect(Number(ordinaryDraft['time'])).assertEqual(200);
      expect(String(ordinaryDraft['dataString']).trim().endsWith(' 200')).assertTrue();
    });

    it('rumWorkerDerivesAndSortsEvents', 0, async () => {
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
      expect(drafts.length).assertEqual(3);
      const first = drafts[0] as Record<string, object>;
      const second = drafts[1] as Record<string, object>;
      const third = drafts[2] as Record<string, object>;
      expect(String(first['dataString']).startsWith('action,')).assertTrue();
      expect(String(second['dataString']).startsWith('view,')).assertTrue();
      expect(String(third['dataString']).startsWith('view,')).assertTrue();
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
      expect(getPayloadArray(duplicateResponse.payload, 'syncDrafts').length).assertEqual(1);
    });

    it('rumWorkerFullyFormatRawWebViewData', 0, async () => {
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
      expect(line.includes('sdk_version=native-version')).assertTrue();
      expect(line.includes('sdk_version=2.3.4')).assertFalse();
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
        id: 'rum-webview-action-repeat',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: actionBatch as Object as SDKWorkerPayload
      });
      expect(getPayloadString(actionResponse.payload, 'activeActionId')).assertEqual('web-action');
      // Browser action IDs identify one event; repeated view updates above remain valid.
      expect(getPayloadArray(actionResponse.payload, 'syncDrafts').length).assertEqual(1);
    });

    it('webResourceErrorLinksExpire', 0, async () => {
      await executeWorkerCommandForUnit({
        id: 'rum-webview-expired-link-context',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      });
      const resourceUuid = 'stale-webview-resource-uuid';
      const resourceEvent = new Object() as SDKRumEventDTO;
      resourceEvent.time = 1000;
      resourceEvent.dataType = 'rum_webview';
      resourceEvent.measurement = 'resource';
      resourceEvent.uuid = resourceUuid;
      resourceEvent.tags = new Object() as SDKStringRecord;
      resourceEvent.tags['view_id'] = 'stale-link-view';
      resourceEvent.tags['resource_method'] = 'GET';
      resourceEvent.tags['resource_url'] = 'https://webview.test/api/stale-link';
      resourceEvent.fields = new Object() as SDKStringRecord;
      resourceEvent.fields['duration'] = '1';
      const resourceResponse = await executeWorkerCommandForUnit({
        id: 'rum-webview-expired-link-resource',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: resourceEvent as Object as SDKWorkerPayload
      });
      expect(resourceResponse.ok).assertTrue();

      const errorEvent = new Object() as SDKRumEventDTO;
      errorEvent.time = 32001;
      errorEvent.dataType = 'rum_webview';
      errorEvent.measurement = 'error';
      errorEvent.tags = new Object() as SDKStringRecord;
      errorEvent.tags['view_id'] = 'stale-link-view';
      errorEvent.tags['resource_method'] = 'GET';
      errorEvent.tags['resource_url'] = 'https://webview.test/api/stale-link';
      errorEvent.tags['error_source'] = 'network';
      errorEvent.fields = new Object() as SDKStringRecord;
      errorEvent.fields['error_message'] = 'network error without a matching resource';
      const errorResponse = await executeWorkerCommandForUnit({
        id: 'rum-webview-expired-link-error',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMMAND,
        priority: 7,
        createdAt: Date.now(),
        payload: errorEvent as Object as SDKWorkerPayload
      });
      expect(errorResponse.ok).assertTrue();
      const drafts = getPayloadArray(errorResponse.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.includes(`resource_id=${resourceUuid}`)).assertFalse();
      expect(unitWorkerStates[SDKDedicatedPoolType.EVENT_CONSUMER].webViewResourceErrorLinks.size).assertEqual(0);
    });

    it('rumCountersSerializableCounterUpdates', 0, async () => {
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
      const snapshot = await getRumWorkerSnapshotForUnit('rum-counter-state-key-snapshot');
      expect(getPayloadString(snapshot.payload, 'rumCounterStateKeyCount')).assertEqual('0');
    });

    it('rumCountersCompactByViewAndAction', 0, async () => {
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

    it('rumCountersKeepMergedLongTasks', 0, async () => {
      const batch: SDKRumCounterUpdateBatchDTO = {
        updates: [
          { updateType: 'long_task.view', viewId: 'view-long-task', count: 50 },
          { updateType: 'long_task.action', actionId: 'action-long-task', count: 50 }
        ]
      };
      const updateResponse = await executeWorkerCommandForUnit({
        id: 'rum-counter-coalesced-long-task',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });
      expect(updateResponse.ok).assertTrue();
      expect(getPayloadString(updateResponse.payload, 'pendingCount')).assertEqual('100');

      const flushResponse = await executeWorkerCommandForUnit({
        id: 'rum-counter-coalesced-long-task-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      expect(flushResponse.ok).assertTrue();
      expect(getPayloadString(flushResponse.payload, 'needsRumDataGenerate')).assertEqual('true');
      const deltas = getPayloadArray(flushResponse.payload, 'deltas');
      expect(deltas.length).assertEqual(2);
      const view = deltas[0] as Record<string, object>;
      const action = deltas[1] as Record<string, object>;
      expect(String(view['viewId'])).assertEqual('view-long-task');
      expect(String(view['viewLongTaskDelta'])).assertEqual('50');
      expect(String(view['viewUpdateTimeDelta'])).assertEqual('50');
      expect(String(action['actionId'])).assertEqual('action-long-task');
      expect(String(action['actionLongTaskDelta'])).assertEqual('50');
    });

    it('rumErrorCounterRefreshesItsViewAggregate', 0, async () => {
      const update: SDKRumCounterUpdateDTO = {
        updateType: 'rum.error', viewId: 'crash-view', actionId: 'crash-action'
      };
      const updateResponse = await executeWorkerCommandForUnit({
        id: 'rum-crash-error-counter',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE,
        priority: 7,
        createdAt: Date.now(),
        payload: update as Object as SDKWorkerPayload
      });
      expect(updateResponse.ok).assertTrue();

      const flushResponse = await executeWorkerCommandForUnit({
        id: 'rum-crash-error-counter-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      expect(flushResponse.ok).assertTrue();
      expect(getPayloadString(flushResponse.payload, 'needsRumDataGenerate')).assertEqual('true');
      const deltas = getPayloadArray(flushResponse.payload, 'deltas');
      expect(deltas.length).assertEqual(2);
      const view = deltas[0] as Record<string, object>;
      const action = deltas[1] as Record<string, object>;
      expect(String(view['viewId'])).assertEqual('crash-view');
      expect(String(view['viewErrorDelta'])).assertEqual('1');
      expect(String(view['viewUpdateTimeDelta'])).assertEqual('1');
      expect(String(action['actionId'])).assertEqual('crash-action');
      expect(String(action['actionErrorDelta'])).assertEqual('1');
    });

    it('rumDtoTracksActionAndResourceState', 0, async () => {
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
      const snapshot = await getRumWorkerSnapshotForUnit('rum-resource-state-key-snapshot');
      expect(getPayloadString(snapshot.payload, 'activeResourceStateKeyCount')).assertEqual('0');
    });

    it('rumWorkerNormalizeRawErrorProperties', 0, async () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'error-session',
        viewId: 'error-view',
        viewName: 'ErrorView',
        viewReferrer: 'root',
        actionId: 'error-action',
        actionName: 'tap',
        rumAppId: 'gc_app_harmonyos_demo',
        hasReplay: true
      };
      const errorProperty = new Object() as SDKPropertyRecord;
      const customReplayFlag: SDKCompletedActionPropertyTestValue = { value: 'false' };
      errorProperty['session_has_replay'] = customReplayFlag;
      const customError = new Object() as SDKCompletedActionPropertyTestValue;
      customError.value = 'normalized';
      errorProperty['custom_error'] = customError;
      const customNested = new Object() as SDKCompletedActionPropertyTestValue;
      customNested.nested = 'yes';
      errorProperty['custom_nested'] = customNested;
      const foregroundCrashFree = new Object() as SDKCompletedActionPropertyTestValue;
      foregroundCrashFree.value = 123;
      errorProperty['foreground_crash_free_duration'] = foregroundCrashFree;
      const backgroundCrashFree = new Object() as SDKCompletedActionPropertyTestValue;
      backgroundCrashFree.value = 456;
      errorProperty['background_crash_free_duration'] = backgroundCrashFree;
      const errorCommand = new Object() as SDKRumErrorCommandDTO;
      errorCommand.context = context;
      errorCommand.log = 'stack-line';
      errorCommand.message = 'worker-error';
      errorCommand.errorType = 'TypeError';
      errorCommand.errorSource = 'logger';
      errorCommand.appState = 'run';
      errorCommand.property = errorProperty;
      errorCommand.deviceTags = new Object() as SDKStringRecord;
      errorCommand.deviceTags['memory_total'] = '8GB';
      errorCommand.deviceTags['locale'] = 'zh-Hans-CN';
      errorCommand.time = 500;
      const lineContext = createRumWorkerLineContext();
      lineContext.rumStaticFields['session_has_replay'] = 'false';
      const batch: SDKRumErrorCommandBatchDTO = {
        lineContext,
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
      expect(getPayloadString(response.payload, 'errorTimeLine')).assertEqual('500');
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(2);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
      expect(line.includes('app_id=gc_app_harmonyos_demo')).assertTrue();
      expect(line.includes('error_type=TypeError')).assertTrue();
      expect(line.includes('memory_total=8GB')).assertTrue();
      expect(line.includes('locale=zh-Hans-CN')).assertTrue();
      expect(line.includes('custom_error="normalized"')).assertTrue();
      expect(line.includes('custom_nested=')).assertTrue();
      expect(line.includes('foreground_crash_free_duration=123i')).assertTrue();
      expect(line.includes('background_crash_free_duration=456i')).assertTrue();
      expect(line.includes('stack-line')).assertTrue();
      expect(line.includes('session_has_replay=true')).assertTrue();
      expect(line.includes('session_has_replay="true"')).assertFalse();
      expect(getPayloadArray(response.payload, 'rawEvents').length).assertEqual(0);

      // Without shared context, preserve the error timeline and counters while
      // leaving both context enrichment and callbacks to the Host.
      errorCommand.uuid = 'raw-error-uuid';
      errorCommand.customDataType = 'rum_app_error_sampled';
      errorCommand.counterFlushMaxEvents = 1;
      const laterError: SDKRumErrorCommandDTO = {
        uuid: 'later-raw-error-uuid', context, log: 'later-stack', message: 'later-error',
        errorType: 'ANR', errorSource: 'logger', appState: 'run',
        property: errorProperty, time: 700, counterFlushMaxEvents: 1
      };
      const rawBatch: SDKRumErrorCommandBatchDTO = { commands: [laterError, errorCommand] };
      for (let replay = 0; replay < 2; replay++) {
        const rawResponse = handleSDKWorkerRequest({
          id: `raw-error-replay-${replay}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH,
          priority: 7, createdAt: 1,
          payload: rawBatch as Object as SDKWorkerPayload
        }, createSDKWorkerRuntimeStateWithBackend(
          SDKDedicatedPoolType.EVENT_CONSUMER, 'RawErrorWorker', 'unit-worker'));
        expect(rawResponse.ok).assertTrue();
        expect(getPayloadArray(rawResponse.payload, 'syncDrafts').length).assertEqual(0);
        expect(getPayloadString(rawResponse.payload, 'errorTimeLine')).assertEqual('700');
        const events = getPayloadArray(rawResponse.payload, 'rawEvents') as Object as SDKRumEventDTO[];
        expect(events.length).assertEqual(2);
        expect(events[0].uuid).assertEqual('raw-error-uuid');
        expect(events[0].time).assertEqual(500);
        expect(events[0].customDataType).assertEqual('rum_app_error_sampled');
        expect(events[0].tags?.['memory_total']).assertEqual('8GB');
        expect(events[0].fields?.['custom_error']).assertEqual('normalized');
        expect(events[0].fields?.['session_has_replay']).assertEqual('true');
        expect(events[0].fields?.['foreground_crash_free_duration']).assertEqual('123');
        expect(events[0].fields?.['background_crash_free_duration']).assertEqual('456');
        expect(events[1].uuid).assertEqual('later-raw-error-uuid');
        expect(events[1].time).assertEqual(700);
        const deltas = getPayloadArray(rawResponse.payload, 'deltas') as Object as SDKRumCounterDeltaDTO[];
        let viewErrors = 0;
        let actionErrors = 0;
        for (const delta of deltas) {
          if (delta.viewId === context.viewId) viewErrors += delta.viewErrorDelta;
          if (delta.actionId === context.actionId) actionErrors += delta.actionErrorDelta;
        }
        expect(viewErrors).assertEqual(2);
        expect(actionErrors).assertEqual(2);
      }

      // Custom context cannot create availability without committed Replay.
      context.hasReplay = false;
      customReplayFlag.value = 'true';
      lineContext.rumStaticFields['session_has_replay'] = 'true';
      const unavailableResponse = handleSDKWorkerRequest({
        id: 'error-without-committed-replay',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH,
        priority: 7, createdAt: 1,
        payload: batch as Object as SDKWorkerPayload
      }, createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'UnavailableErrorReplayWorker', 'unit-worker'));
      expect(unavailableResponse.ok).assertTrue();
      const unavailableDrafts = getPayloadArray(unavailableResponse.payload, 'syncDrafts');
      expect(unavailableDrafts.length).assertEqual(2);
      for (const draft of unavailableDrafts) {
        const unavailableLine = String((draft as Record<string, object>)['dataString']);
        expect(unavailableLine.includes('session_has_replay=')).assertFalse();
      }
    });

    it('rumWorkerEmitsCrashFreeDurationsOnlyForCrashErrorLineProtocolFields', 0, async () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'crash-free-session',
        viewId: 'crash-free-view',
        viewName: 'CrashFreeView',
        viewReferrer: 'root',
        actionId: 'crash-free-action',
        actionName: 'tap',
        rumAppId: 'gc_app_harmonyos_demo'
      };
      const crashCases: SDKCrashFreeDurationTestCase[] = [
        new SDKCrashFreeDurationTestCase('js-foreground-crash', 'js_crash', 80, 50),
        new SDKCrashFreeDurationTestCase('js-background-crash', 'js_crash', 40, 70),
        new SDKCrashFreeDurationTestCase('native-foreground-crash', 'native_crash', 30000030, 20),
        new SDKCrashFreeDurationTestCase('native-background-crash', 'native_crash', 30, 30000020)
      ];
      const nonCrashCases: SDKNonCrashErrorTestCase[] = [
        new SDKNonCrashErrorTestCase('custom-error', 'custom'),
        new SDKNonCrashErrorTestCase('network-error', 'network_error'),
        new SDKNonCrashErrorTestCase('anr-error', 'anr_error')
      ];
      const commands: SDKRumErrorCommandDTO[] = [];

      for (const crashCase of crashCases) {
        const property = new Object() as SDKPropertyRecord;
        const foregroundDuration = new Object() as SDKCompletedActionPropertyTestValue;
        foregroundDuration.value = crashCase.foregroundNs;
        property['foreground_crash_free_duration'] = foregroundDuration;
        const backgroundDuration = new Object() as SDKCompletedActionPropertyTestValue;
        backgroundDuration.value = crashCase.backgroundNs;
        property['background_crash_free_duration'] = backgroundDuration;
        commands.push({
          context,
          log: `stack-${crashCase.marker}`,
          message: crashCase.marker,
          errorType: crashCase.errorType,
          errorSource: 'logger',
          appState: crashCase.marker.includes('background') ? 'background' : 'run',
          property,
          time: 1000 + commands.length
        });
      }
      for (const nonCrashCase of nonCrashCases) {
        commands.push({
          context,
          log: `stack-${nonCrashCase.marker}`,
          message: nonCrashCase.marker,
          errorType: nonCrashCase.errorType,
          errorSource: 'logger',
          appState: 'run',
          property: new Object() as SDKPropertyRecord,
          time: 1000 + commands.length
        });
      }

      const batch = new Object() as SDKRumErrorCommandBatchDTO;
      batch.lineContext = createRumWorkerLineContext();
      batch.commands = commands;
      const request = new Object() as SDKWorkerRequest;
      request.id = 'rum-crash-free-error-lines';
      request.pool = SDKDedicatedPoolType.EVENT_CONSUMER;
      request.command = SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH;
      request.priority = 7;
      request.createdAt = Date.now();
      request.payload = batch as Object as SDKWorkerPayload;
      const response = await executeWorkerCommandForUnit(request);

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(crashCases.length + nonCrashCases.length);
      for (const crashCase of crashCases) {
        let line = '';
        for (const draft of drafts) {
          const candidate = String((draft as Record<string, object>)['dataString']);
          if (candidate.includes(crashCase.marker)) {
            line = candidate;
            break;
          }
        }
        const foregroundField = `foreground_crash_free_duration=${crashCase.foregroundNs}i`;
        const backgroundField = `background_crash_free_duration=${crashCase.backgroundNs}i`;
        expect(line.length > 0).assertTrue();
        expect(line.includes(`error_type=${crashCase.errorType}`)).assertTrue();
        expect(line.includes(foregroundField)).assertTrue();
        expect(line.includes(backgroundField)).assertTrue();
        // The first space separates Line Protocol tags from fields. Both
        // crash-free values must remain numeric fields, never tags.
        const firstFieldOffset = line.indexOf(' ');
        expect(line.indexOf(foregroundField) > firstFieldOffset).assertTrue();
        expect(line.indexOf(backgroundField) > firstFieldOffset).assertTrue();
      }
      for (const nonCrashCase of nonCrashCases) {
        let line = '';
        for (const draft of drafts) {
          const candidate = String((draft as Record<string, object>)['dataString']);
          if (candidate.includes(nonCrashCase.marker)) {
            line = candidate;
            break;
          }
        }
        expect(line.length > 0).assertTrue();
        expect(line.includes(`error_type=${nonCrashCase.errorType}`)).assertTrue();
        expect(line.includes('foreground_crash_free_duration=')).assertFalse();
        expect(line.includes('background_crash_free_duration=')).assertFalse();
      }
    });

    it('rumWorkerNormalizesResourceCommands', 0, async () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'resource-session',
        viewId: 'resource-view',
        viewName: 'ResourceView',
        viewReferrer: 'root',
        actionId: 'resource-action',
        actionName: 'load',
        rumAppId: 'gc_app_harmonyos_demo'
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
        lineContext: createRumWorkerLineContext(),
        commands: [stop, network, content, content, start, start]
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
      expect(String((drafts[0] as Record<string, object>)['dataString']).includes(
        'app_id=gc_app_harmonyos_demo')).assertTrue();
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.startsWith('resource,')).assertTrue();
      expect(line.includes('resource_url_host=example.com')).assertTrue();
      expect(line.includes('resource_url_path_group=/users/?/profile')).assertTrue();
      expect(line.includes('custom_resource="normalized"')).assertTrue();
      expect(line.includes('resource_dns=12i')).assertTrue();
      expect(line.includes('duration=50i')).assertTrue();
      expect(Number((drafts[0] as Record<string, object>)['time'])).assertEqual(10);
      expect(line.trim().endsWith(' 10')).assertTrue();
      const snapshot = await getRumWorkerSnapshotForUnit('rum-resource-command-state-key-snapshot');
      expect(getPayloadString(snapshot.payload, 'rumResourceStateKeyCount')).assertEqual('0');
      const counterFlush = await executeWorkerCommandForUnit({
        id: 'rum-resource-duplicate-start-counter-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: Date.now()
      });
      const counterDeltas = getPayloadArray(response.payload, 'deltas');
      expect(getPayloadArray(counterFlush.payload, 'deltas').length).assertEqual(0);
      let actionPendingDelta = 0;
      let actionResourceDelta = 0;
      for (let i = 0; i < counterDeltas.length; i++) {
        const delta = counterDeltas[i] as Record<string, object>;
        if (String(delta['actionId']) === 'resource-action') {
          actionPendingDelta = Number(delta['actionPendingDelta']);
          actionResourceDelta = Number(delta['actionResourceDelta']);
        }
      }
      expect(actionPendingDelta).assertEqual(0);
      expect(actionResourceDelta).assertEqual(1);
    });

    it('resourceTransportFieldsShouldRejectCustomAndGlobalOverrides', 0, async () => {
      for (const known of [true, false]) {
        for (const mode of ['line', 'raw']) {
          const metrics: SDKRumResourceTransportMetricsDTO = {
            requestBodySize: 8, requestBodySizeSource: 'integration', requestHeaderSize: 20,
            requestHeaderSizeSource: 'integration', requestSize: -1,
            httpProtocol: 'HTTP/2.0', httpProtocolSource: 'platform',
            connectionReuse: false, connectionReuseSource: 'integration'
          };
          const id = `transport-protected-${known}-${mode}`;
          const commands = createTransportResourceCommandsForUnit(id, known ? metrics : undefined);
          for (const command of commands) {
            command.context!.dynamicTags = {
              resource_request_size: '999', resource_http_protocol: 'wrong', resource_connection_reuse: 'true'
            };
            command.property = {
              resource_request_size: '999', resource_http_protocol: 'wrong', resource_connection_reuse: 'true',
              transport_marker: 'kept'
            };
          }
          const batch: SDKRumResourceCommandBatchDTO = { commands };
          if (mode === 'line') {
            batch.lineContext = createRumWorkerLineContext();
            batch.lineContext.dynamicRumTags = commands[0].context!.dynamicTags!;
            batch.lineContext.rumStaticFields = commands[0].context!.dynamicTags!;
          }
          const response = await executeWorkerCommandForUnit({
            id, pool: SDKDedicatedPoolType.EVENT_CONSUMER,
            command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
            payload: batch as Object as SDKWorkerPayload
          });
          if (mode === 'line') {
            const drafts = getPayloadArray(response.payload, 'syncDrafts');
            expect(drafts.length).assertEqual(1);
            const line = String((drafts[0] as Record<string, object>)['dataString']);
            for (const key of ['resource_request_size', 'resource_http_protocol', 'resource_connection_reuse']) {
              expect(line.split(' ')[0].includes(`${key}=`)).assertFalse();
              expect(line.includes(`${key}=`)).assertEqual(known);
            }
            if (known) {
              expect(line.includes('resource_request_size=28i')).assertTrue();
              expect(line.includes('resource_http_protocol="h2"')).assertTrue();
              expect(line.includes('resource_connection_reuse=false')).assertTrue();
            }
            expect(line.includes('transport_marker="kept"')).assertTrue();
          } else {
            const events = getPayloadArray(response.payload, 'rawEvents');
            expect(events.length).assertEqual(1);
            const event = events[0] as Object as SDKRumEventDTO;
            expect(event.tags['resource_http_protocol'] === undefined).assertTrue();
            expect(event.fields['resource_request_size']).assertEqual(known ? '28' : undefined);
            expect(event.fields['resource_http_protocol']).assertEqual(known ? 'h2' : undefined);
            expect(event.fields['resource_connection_reuse']).assertEqual(known ? 'false' : undefined);
          }
        }
      }
    });

    it('resourceTransportShouldMergeDeferredValuesAfterSerializationWithoutMixingSameUrl', 0, async () => {
      const initial: SDKRumResourceTransportMetricsDTO = {
        requestBodySize: 20, requestBodySizeSource: 'integration', requestHeaderSize: 20,
        requestHeaderSizeSource: 'integration', requestSize: 40, requestSizeSource: 'integration',
        httpProtocol: 'http/1.1', httpProtocolSource: 'integration'
      };
      const platform: SDKRumResourceTransportMetricsDTO = {
        requestBodySize: 30, requestBodySizeSource: 'platform', requestHeaderSize: 50,
        requestHeaderSizeSource: 'platform', requestSize: -1, httpProtocol: 'HTTP/2', httpProtocolSource: 'platform',
        connectionReuse: false, connectionReuseSource: 'platform'
      };
      const one = createTransportResourceCommandsForUnit('transport-one', initial, platform);
      const two = createTransportResourceCommandsForUnit('transport-two', initial);
      const serialized = JSON.stringify([one[0], two[0], one[1], two[1], two[2], one[2], two[3], one[3], one[3]]);
      const commands = JSON.parse(serialized) as SDKRumResourceCommandDTO[];
      const batch: SDKRumResourceCommandBatchDTO = { commands, lineContext: createRumWorkerLineContext() };
      const response = await executeWorkerCommandForUnit({
        id: 'transport-concurrent', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(2);
      const secondLine = String((drafts[0] as Record<string, object>)['dataString']);
      const firstLine = String((drafts[1] as Record<string, object>)['dataString']);
      expect(secondLine.includes('resource_id=transport-two')).assertTrue();
      expect(secondLine.includes('resource_request_size=40i')).assertTrue();
      expect(secondLine.includes('resource_http_protocol="http/1.1"')).assertTrue();
      expect(secondLine.includes('resource_connection_reuse=')).assertFalse();
      expect(firstLine.includes('resource_id=transport-one')).assertTrue();
      expect(firstLine.includes('resource_request_size=80i')).assertTrue();
      expect(firstLine.includes('resource_http_protocol="h2"')).assertTrue();
      expect(firstLine.includes('resource_connection_reuse=false')).assertTrue();
      expect(firstLine.includes('action_id=transport-action')).assertTrue();
      expect(firstLine.endsWith(' 100')).assertTrue();
    });

    it('resourceTransportShouldOmitInvalidRecoveredBytesAndProtocol', 0, async () => {
      for (const invalid of [-1, 1.5, Number.MAX_SAFE_INTEGER + 1, Infinity]) {
        const metrics: SDKRumResourceTransportMetricsDTO = {
          requestBodySize: invalid, requestBodySizeSource: 'platform', requestHeaderSize: 8,
          requestHeaderSizeSource: 'header', requestSize: invalid, requestSizeSource: 'platform',
          httpProtocol: 'Unknown/Non-HTTP', httpProtocolSource: 'platform'
        };
        const batch: SDKRumResourceCommandBatchDTO = {
          commands: createTransportResourceCommandsForUnit(`invalid-${invalid}`, metrics),
          lineContext: createRumWorkerLineContext()
        };
        const response = await executeWorkerCommandForUnit({
          id: `invalid-${invalid}`, pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
          payload: batch as Object as SDKWorkerPayload
        });
        const drafts = getPayloadArray(response.payload, 'syncDrafts');
        expect(drafts.length).assertEqual(1);
        const line = String((drafts[0] as Record<string, object>)['dataString']);
        expect(line.includes('resource_request_size=')).assertFalse();
        expect(line.includes('resource_http_protocol=')).assertFalse();
        expect(line.includes('resource_connection_reuse=')).assertFalse();
      }
    });

    it('resourceNetworkSnapshotUsesStartContextAndOmitsUnknownMetrics', 0, async () => {
      const startOnlineContext: SDKRumResourceContextDTO = {
        sessionId: 'network-snapshot-session', viewId: 'network-snapshot-view', viewName: 'NetworkSnapshotView',
        viewReferrer: 'root', actionId: 'network-snapshot-action', actionName: 'request',
        networkSnapshot: {
          available: true, validated: true, downlinkKbps: 1500, uplinkKbps: 800, signalStrength: 0
        }
      };
      const laterOfflineContext: SDKRumResourceContextDTO = {
        sessionId: 'later-session', viewId: 'later-view', viewName: 'LaterView', viewReferrer: 'root',
        actionId: 'later-action', actionName: 'later', networkSnapshot: { available: false }
      };
      const params: SDKRumResourceParamsDTO = {
        url: 'https://example.com/network-snapshot', requestHeader: '', responseHeader: '', responseConnection: '',
        responseContentType: '', responseContentEncoding: '', responseContentLength: 0, resourceMethod: 'GET',
        responseBody: '', resourceStatus: 200, resourceType: 'network', requestErrorStack: '', requestErrorMsg: '',
        property: new Object() as SDKPropertyRecord
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 0, dnsStartTime: 0, tcpTime: 0, tcpStartTime: 0, sslTime: 0, sslStartTime: 0,
        ttfbTime: 0, responseTime: 0, firstByteTime: 0, firstByteStartTime: 0, downloadTime: 0,
        downloadStartTime: 0, holeRequestTime: 10, resourceHostIP: ''
      };
      const onlineBatch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'start', resourceId: 'network-snapshot-online', context: startOnlineContext, startTime: 10
        }, {
          commandType: 'setContent', resourceId: 'network-snapshot-online', context: laterOfflineContext,
          params, eventTime: 20
        }, {
          commandType: 'setNetState', resourceId: 'network-snapshot-online', context: laterOfflineContext,
          netStatus, eventTime: 30
        }, {
          commandType: 'stop', resourceId: 'network-snapshot-online', context: laterOfflineContext, endTime: 40
        }]
      };
      const onlineResponse = await executeWorkerCommandForUnit({
        id: 'resource-network-snapshot-online', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
        payload: onlineBatch as Object as SDKWorkerPayload
      });
      const onlineDrafts = getPayloadArray(onlineResponse.payload, 'syncDrafts');
      expect(onlineDrafts.length).assertEqual(1);
      const onlineLine = String((onlineDrafts[0] as Record<string, object>)['dataString']);
      expect(onlineLine.includes('network_available=true')).assertTrue();
      expect(onlineLine.includes('network_validated=true')).assertTrue();
      expect(onlineLine.includes('network_downlink_kbps=1500i')).assertTrue();
      expect(onlineLine.includes('network_uplink_kbps=800i')).assertTrue();
      // Zero is emitted only for a platform-provided signal reading.
      expect(onlineLine.includes('network_signal_strength=0i')).assertTrue();
      expect(onlineLine.includes('network_available=false')).assertFalse();

      const offlineStartContext: SDKRumResourceContextDTO = {
        sessionId: 'offline-session', viewId: 'offline-view', viewName: 'OfflineView', viewReferrer: 'root',
        actionId: 'offline-action', actionName: 'request', networkSnapshot: { available: false }
      };
      const laterOnlineContext: SDKRumResourceContextDTO = {
        sessionId: 'online-session', viewId: 'online-view', viewName: 'OnlineView', viewReferrer: 'root',
        actionId: 'online-action', actionName: 'later',
        networkSnapshot: { available: true, validated: true, downlinkKbps: 1, uplinkKbps: 1, signalStrength: 1 }
      };
      const offlineBatch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'start', resourceId: 'network-snapshot-offline', context: offlineStartContext, startTime: 50
        }, {
          commandType: 'setContent', resourceId: 'network-snapshot-offline', context: laterOnlineContext,
          params, eventTime: 60
        }, {
          commandType: 'setNetState', resourceId: 'network-snapshot-offline', context: laterOnlineContext,
          netStatus, eventTime: 70
        }, {
          commandType: 'stop', resourceId: 'network-snapshot-offline', context: laterOnlineContext, endTime: 80
        }]
      };
      const offlineResponse = await executeWorkerCommandForUnit({
        id: 'resource-network-snapshot-offline', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
        payload: offlineBatch as Object as SDKWorkerPayload
      });
      const offlineDrafts = getPayloadArray(offlineResponse.payload, 'syncDrafts');
      expect(offlineDrafts.length).assertEqual(1);
      const offlineLine = String((offlineDrafts[0] as Record<string, object>)['dataString']);
      expect(offlineLine.includes('network_available=false')).assertTrue();
      expect(offlineLine.includes('network_validated=')).assertFalse();
      expect(offlineLine.includes('network_downlink_kbps=')).assertFalse();
      expect(offlineLine.includes('network_uplink_kbps=')).assertFalse();
      expect(offlineLine.includes('network_signal_strength=')).assertFalse();
    });

    it('resourceNetworkSnapshotShouldRejectCustomAndGlobalOverrides', 0, async () => {
      const snapshots: Array<SDKRumResourceNetworkSnapshotDTO | undefined> = [
        { available: false }, { available: true },
        { available: true, validated: false, downlinkKbps: 1200, uplinkKbps: 600, signalStrength: 0 },
        undefined
      ];
      const keys: string[] = ['network_available', 'network_validated', 'network_downlink_kbps',
        'network_uplink_kbps', 'network_signal_strength'];
      for (let index = 0; index < snapshots.length; index++) {
        for (const mode of ['line', 'raw']) {
          const snapshot = snapshots[index];
          const resourceId = `protected-network-${index}-${mode}`;
          const context: SDKRumResourceContextDTO = {
            sessionId: 'protected-network-session', viewId: 'protected-network-view', viewName: 'NetworkView',
            viewReferrer: '', actionId: '', actionName: '', networkSnapshot: snapshot,
            dynamicTags: { network_available: 'fake-tag', network_signal_strength: 'fake-tag' }
          };
          const property = new Object() as SDKPropertyRecord;
          for (const key of keys) {
            const value: SDKCompletedActionPropertyTestValue = { value: '999' };
            property[key] = value;
          }
          const marker: SDKCompletedActionPropertyTestValue = { value: 'kept' };
          property['snapshot_custom_marker'] = marker;
          const params: SDKRumResourceParamsDTO = {
            url: 'https://example.com/protected-snapshot', requestHeader: '', responseHeader: '',
            responseConnection: '', responseContentType: '', responseContentEncoding: '',
            responseContentLength: 0, resourceMethod: 'GET', responseBody: '', resourceStatus: 200,
            resourceType: 'network', requestErrorStack: '', requestErrorMsg: '', property
          };
          const batch: SDKRumResourceCommandBatchDTO = {
            commands: [{ commandType: 'start', resourceId, context, property, startTime: 10 },
              { commandType: 'setContent', resourceId, context, params, eventTime: 20 },
              { commandType: 'setNetState', resourceId, context,
                netStatus: { holeRequestTime: 10 } as SDKRumResourceNetStatusDTO, eventTime: 20 },
              { commandType: 'stop', resourceId, context, property, endTime: 20 }]
          };
          if (mode === 'line') {
            batch.lineContext = createRumWorkerLineContext();
            for (const key of keys) {
              batch.lineContext.dynamicRumTags[key] = 'fake-tag';
              batch.lineContext.rumStaticFields[key] = '999';
            }
          }
          const response = await executeWorkerCommandForUnit({
            id: resourceId, pool: SDKDedicatedPoolType.EVENT_CONSUMER,
            command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
            payload: batch as Object as SDKWorkerPayload
          });
          if (mode === 'line') {
            const drafts = getPayloadArray(response.payload, 'syncDrafts');
            expect(drafts.length).assertEqual(1);
            const line = String((drafts[0] as Record<string, object>)['dataString']);
            const tags = line.split(' ')[0];
            for (const key of keys) expect(tags.includes(`${key}=`)).assertFalse();
            expect(line.includes('snapshot_custom_marker="kept"')).assertTrue();
            for (const key of keys) expect(line.includes(`${key}=999`)).assertFalse();
            if (snapshot) expect(line.includes(`network_available=${snapshot.available}`)).assertTrue();
            else expect(line.includes('network_available=')).assertFalse();
            if (index === 2) {
              expect(line.includes('network_validated=false')).assertTrue();
              expect(line.includes('network_downlink_kbps=1200i')).assertTrue();
              expect(line.includes('network_uplink_kbps=600i')).assertTrue();
              expect(line.includes('network_signal_strength=0i')).assertTrue();
            } else {
              for (const key of keys.slice(1)) expect(line.includes(`${key}=`)).assertFalse();
            }
          } else {
            const events = getPayloadArray(response.payload, 'rawEvents');
            expect(events.length).assertEqual(1);
            const event = events[0] as Object as SDKRumEventDTO;
            expect(event.fields['snapshot_custom_marker']).assertEqual('kept');
            for (const key of keys) expect(event.tags[key] === undefined).assertTrue();
            if (snapshot) expect(event.fields['network_available']).assertEqual(String(snapshot.available));
            else expect(event.fields['network_available'] === undefined).assertTrue();
            if (index !== 2) {
              for (const key of keys.slice(1)) expect(event.fields[key] === undefined).assertTrue();
            }
          }
        }
      }
    });

    it('suppressedLocalResourceShouldKeepResourceWithoutErrorSideEffects', 0, async () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'suppressed-session',
        viewId: 'suppressed-view',
        viewName: 'SuppressedView',
        viewReferrer: 'root',
        actionId: 'suppressed-action',
        actionName: 'load',
        rumAppId: 'gc_app_harmonyos_demo'
      };
      const params: SDKRumResourceParamsDTO = {
        url: 'https://offline.example.com',
        requestHeader: '',
        responseHeader: '',
        responseConnection: '',
        responseContentType: '',
        responseContentEncoding: '',
        responseContentLength: 0,
        resourceMethod: 'GET',
        responseBody: '',
        resourceStatus: 0,
        resourceType: 'network',
        requestErrorStack: 'timeout stack',
        requestErrorMsg: 'timeout',
        suppressNetworkError: true,
        property: new Object() as SDKPropertyRecord
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 0, dnsStartTime: 0, tcpTime: 0, tcpStartTime: 0,
        sslTime: 0, sslStartTime: 0, ttfbTime: 0, responseTime: 0,
        firstByteTime: 0, firstByteStartTime: 0, downloadTime: 0,
        downloadStartTime: 0, holeRequestTime: 10, resourceHostIP: ''
      };
      const batch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'start', resourceId: 'suppressed-resource', context, startTime: 10
        }, {
          commandType: 'setContent', resourceId: 'suppressed-resource', context, params, eventTime: 20
        }, {
          commandType: 'setNetState', resourceId: 'suppressed-resource', context, netStatus, eventTime: 30
        }, {
          commandType: 'stop', resourceId: 'suppressed-resource', context, endTime: 40
        }]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'rum-suppressed-local-resource',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      expect(String((drafts[0] as Record<string, object>)['dataString']).startsWith('resource,')).assertTrue();
      const deltas = getPayloadArray(response.payload, 'deltas');
      for (let i = 0; i < deltas.length; i++) {
        const delta = deltas[i] as Record<string, object>;
        if (String(delta['actionId']) === 'suppressed-action') {
          expect(Number(delta['actionErrorDelta'])).assertEqual(0);
          expect(Number(delta['actionResourceDelta'])).assertEqual(1);
        }
      }

      const httpErrorParams: SDKRumResourceParamsDTO = {
        url: 'https://offline.example.com',
        requestHeader: '',
        responseHeader: '',
        responseConnection: '',
        responseContentType: '',
        responseContentEncoding: '',
        responseContentLength: 0,
        resourceMethod: 'GET',
        responseBody: 'HTTP 500',
        resourceStatus: 500,
        resourceType: 'network',
        requestErrorStack: 'server response stack',
        requestErrorMsg: 'server error',
        suppressNetworkError: true,
        property: new Object() as SDKPropertyRecord
      };
      const httpBatch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'start', resourceId: 'http-error-resource', context, startTime: 50
        }, {
          commandType: 'setContent', resourceId: 'http-error-resource', context, params: httpErrorParams, eventTime: 60
        }, {
          commandType: 'setNetState', resourceId: 'http-error-resource', context, netStatus, eventTime: 70
        }, {
          commandType: 'stop', resourceId: 'http-error-resource', context, endTime: 80
        }]
      };
      const httpResponse = await executeWorkerCommandForUnit({
        id: 'rum-http-resource-must-still-error',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: httpBatch as Object as SDKWorkerPayload
      });
      expect(httpResponse.ok).assertTrue();
      expect(getPayloadArray(httpResponse.payload, 'syncDrafts').length).assertEqual(2);
    });

    it('resourceRecoveredWithoutStartCommandUsesRestoredStartTime', 0, async () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'recovered-session', viewId: 'recovered-view', viewName: 'RecoveredView', viewReferrer: '',
        actionId: 'original-action', actionName: 'request'
      };
      const params: SDKRumResourceParamsDTO = {
        url: 'https://example.com/recovered', requestHeader: '', responseHeader: '', responseConnection: '',
        responseContentType: '', responseContentEncoding: '', responseContentLength: 0,
        resourceMethod: 'GET', responseBody: '', resourceStatus: 200, resourceType: 'network',
        requestErrorStack: '', requestErrorMsg: '', property: new Object() as SDKPropertyRecord
      };
      const netStatus = new Object() as SDKRumResourceNetStatusDTO;
      const batch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [
          { commandType: 'setContent', resourceId: 'recovered-resource', context, params, eventTime: 200 },
          { commandType: 'setNetState', resourceId: 'recovered-resource', context, netStatus, eventTime: 300,
            startTime: 100 },
          { commandType: 'stop', resourceId: 'recovered-resource', context, endTime: 400 }
        ]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'recovered-resource-start-time', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });
      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(1);
      const draft = drafts[0] as Record<string, object>;
      expect(Number(draft['time'])).assertEqual(100);
      const line = String(draft['dataString']);
      expect(line.trim().endsWith(' 100')).assertTrue();
      expect(line.includes('action_id=original-action')).assertTrue();

      const missingStartBatch: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'add', resourceId: 'resource-without-start', context, params, netStatus,
          eventTime: 500
        }]
      };
      const missingStartResponse = await executeWorkerCommandForUnit({
        id: 'resource-without-start-time', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: Date.now(),
        payload: missingStartBatch as Object as SDKWorkerPayload
      });
      const fallbackDraft = getPayloadArray(missingStartResponse.payload, 'syncDrafts')[0] as Record<string, object>;
      expect(Number(fallbackDraft['time'])).assertEqual(500);
      expect(String(fallbackDraft['dataString']).trim().endsWith(' 500')).assertTrue();
    });

    it('resourceCompletionKeepsStopPropertiesWhenAddArrivesFirst', 0, () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'lifecycle-session', viewId: 'lifecycle-view', viewName: 'LifecycleView', viewReferrer: 'root',
        actionId: 'lifecycle-action', actionName: 'load', rumAppId: 'gc_app_harmonyos_demo'
      };
      const startProperty = new Object() as SDKPropertyRecord;
      const startValue = new Object() as SDKCompletedActionPropertyTestValue;
      startValue.value = 'start';
      startProperty['lifecycle_start'] = startValue;
      const sharedStartValue = new Object() as SDKCompletedActionPropertyTestValue;
      sharedStartValue.value = 'start';
      startProperty['lifecycle_shared'] = sharedStartValue;

      const stopProperty = new Object() as SDKPropertyRecord;
      const stopValue = new Object() as SDKCompletedActionPropertyTestValue;
      stopValue.value = 'stop';
      stopProperty['lifecycle_stop'] = stopValue;
      const sharedStopValue = new Object() as SDKCompletedActionPropertyTestValue;
      sharedStopValue.value = 'stop';
      stopProperty['lifecycle_shared'] = sharedStopValue;

      const addProperty = new Object() as SDKPropertyRecord;
      const addValue = new Object() as SDKCompletedActionPropertyTestValue;
      addValue.value = 'add';
      addProperty['lifecycle_add'] = addValue;
      const sharedAddValue = new Object() as SDKCompletedActionPropertyTestValue;
      sharedAddValue.value = 'add';
      addProperty['lifecycle_shared'] = sharedAddValue;
      const params: SDKRumResourceParamsDTO = {
        url: 'https://example.com/lifecycle-order', requestHeader: '', responseHeader: '', responseConnection: '',
        responseContentType: '', responseContentEncoding: '', responseContentLength: 0, resourceMethod: 'GET',
        responseBody: '', resourceStatus: 200, resourceType: 'network', requestErrorStack: '', requestErrorMsg: '',
        property: addProperty
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 0, dnsStartTime: 0, tcpTime: 0, tcpStartTime: 0, sslTime: 0, sslStartTime: 0,
        ttfbTime: 0, responseTime: 0, firstByteTime: 0, firstByteStartTime: 0, downloadTime: 0,
        downloadStartTime: 0, holeRequestTime: 30, resourceHostIP: ''
      };
      const workerState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'LifecycleOrderWorker', 'unit-worker');
      const partial: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'start', resourceId: 'lifecycle-order', context, property: startProperty, startTime: 10
        }, {
          // The Host accepted stopResource first, but addResource reached the
          // Worker first after a transport boundary.
          commandType: 'add', resourceId: 'lifecycle-order', context, params, netStatus, eventTime: 30,
          awaitStopCommand: true
        }]
      };
      const partialResponse = handleSDKWorkerRequest({
        id: 'lifecycle-order-partial', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: 1,
        payload: partial as Object as SDKWorkerPayload
      }, workerState);
      expect(getPayloadArray(partialResponse.payload, 'syncDrafts').length).assertEqual(0);

      const completion: SDKRumResourceCommandBatchDTO = {
        lineContext: createRumWorkerLineContext(),
        commands: [{
          commandType: 'stop', resourceId: 'lifecycle-order', context, property: stopProperty, endTime: 20
        }]
      };
      const completionResponse = handleSDKWorkerRequest({
        id: 'lifecycle-order-completion', pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH, priority: 7, createdAt: 2,
        payload: completion as Object as SDKWorkerPayload
      }, workerState);
      const drafts = getPayloadArray(completionResponse.payload, 'syncDrafts');

      expect(drafts.length).assertEqual(1);
      const line = String((drafts[0] as Record<string, object>)['dataString']);
      expect(line.includes('lifecycle_start="start"')).assertTrue();
      expect(line.includes('lifecycle_stop="stop"')).assertTrue();
      expect(line.includes('lifecycle_add="add"')).assertTrue();
      expect(line.includes('lifecycle_shared="add"')).assertTrue();
    });

    it('resourceFinalProtocolPreservesZeroAndHttpStatuses', 0, async () => {
      const statuses = [0, 200, 204, 302, 404, 500, 0, 0];
      for (let index = 0; index < statuses.length; index++) {
        const status = statuses[index];
        const id = `status-contract-${index}`;
        const dynamicTags = new Object() as SDKStringRecord;
        dynamicTags['resource_status'] = '599';
        dynamicTags['resource_status_group'] = '5xx';
        const context: SDKRumResourceContextDTO = {
          sessionId: 'status-session', viewId: 'status-view', viewName: 'StatusView', viewReferrer: 'root',
          actionId: 'status-action', actionName: 'request', rumAppId: 'gc_app_harmonyos_demo',
          dynamicTags
        };
        const params: SDKRumResourceParamsDTO = {
          url: 'https://example.com/api/users/123/profile?from=status-test',
          requestHeader: '', responseHeader: '', responseConnection: '', responseContentType: '',
          responseContentEncoding: '', responseContentLength: 0, resourceMethod: 'GET', responseBody: '',
          resourceStatus: status, resourceType: 'network', requestErrorStack: index === 0 ? 'timeout stack' : '',
          requestErrorMsg: index === 0 || index === 7 ? 'Timeout was reached' : '',
          property: new Object() as SDKPropertyRecord
        };
        const netStatus: SDKRumResourceNetStatusDTO = {
          dnsTime: 0, dnsStartTime: 0, tcpTime: 0, tcpStartTime: 0, sslTime: 0, sslStartTime: 0,
          ttfbTime: 0, responseTime: 0, firstByteTime: 0, firstByteStartTime: 0, downloadTime: 0,
          downloadStartTime: 0, holeRequestTime: index === 7 ? 0 : 100, resourceHostIP: ''
        };
        const start: SDKRumResourceCommandDTO = {
          commandType: 'start', resourceId: id, draftUuid: id, errorDraftUuid: `${id}-error`, context, startTime: 10
        };
        const content: SDKRumResourceCommandDTO = {
          commandType: 'setContent', resourceId: id, context, params, eventTime: 20
        };
        const network: SDKRumResourceCommandDTO = {
          commandType: 'setNetState', resourceId: id, context, netStatus, eventTime: 30
        };
        const stop: SDKRumResourceCommandDTO = {
          commandType: 'stop', resourceId: id, context, endTime: index === 7 ? 10 : 110
        };
        const batch: SDKRumResourceCommandBatchDTO = {
          lineContext: createRumWorkerLineContext(), commands: [stop, network, content, content, start, start]
        };
        const response = await executeWorkerCommandForUnit({
          id, pool: SDKDedicatedPoolType.EVENT_CONSUMER, command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
          priority: 7, createdAt: Date.now(), payload: batch as Object as SDKWorkerPayload
        });
        expect(response.ok).assertTrue();
        const drafts = getPayloadArray(response.payload, 'syncDrafts');
        const hasError = status >= 400 || index === 0;
        expect(drafts.length).assertEqual(hasError ? 2 : 1);
        for (const draft of drafts) {
          const line = String((draft as Record<string, object>)['dataString']);
          expect(line.includes(`resource_status=${status},`)).assertTrue();
          expect(line.includes('resource_url_path=/api/users/123/profile,')).assertTrue();
          expect(/resource_url_path_group=\/api\/users\/\?\/profile[, ]/.test(line)).assertTrue();
          expect(line.includes(`resource_id=${id},`)).assertTrue();
          if (index === 7 && line.startsWith('resource,')) {
            expect(line.includes('duration=0i')).assertTrue();
          }
          if (status === 0) {
            expect(line.includes('resource_status_group=')).assertFalse();
          } else {
            expect(line.includes(`resource_status_group=${Math.floor(status / 100)}xx,`)).assertTrue();
          }
          if (index === 0 && line.startsWith('error,')) {
            expect(line.includes('Timeout was reached')).assertTrue();
            expect(line.includes('error_stack="timeout stack"')).assertTrue();
          }
        }
        const snapshot = await getRumWorkerSnapshotForUnit(`${id}-snapshot`);
        expect(getPayloadString(snapshot.payload, 'rumResourceStateKeyCount')).assertEqual('0');
        const flush = await executeWorkerCommandForUnit({
          id: `${id}-flush`, pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH, priority: 7, createdAt: Date.now()
        });
        expect(getPayloadString(response.payload, 'needsRumDataGenerate')).assertEqual('true');
        expect(getPayloadArray(flush.payload, 'deltas').length).assertEqual(0);
        const deltas = getPayloadArray(response.payload, 'deltas');
        expect(deltas.length).assertEqual(2);
        const delta = deltas[0] as Record<string, object>;
        expect(String(delta['viewId'])).assertEqual('status-view');
        expect(Number(delta['viewResourceDelta'])).assertEqual(1);
        expect(Number(delta['viewErrorDelta'])).assertEqual(hasError ? 1 : 0);
        expect(Number(delta['viewPendingDelta'])).assertEqual(0);
      }
    });

    it('resourceAndErrorKeepStartActionContext', 0, async () => {
      const startContext: SDKRumResourceContextDTO = {
        sessionId: 'session-first-action',
        viewId: 'view-first-action',
        viewName: 'FirstActionView',
        viewReferrer: 'root',
        actionId: 'action-first',
        actionName: 'first tap',
        rumAppId: 'gc_app_harmonyos_demo',
        hasReplay: true
      };
      const laterContext: SDKRumResourceContextDTO = {
        sessionId: 'session-later-action',
        viewId: 'view-later-action',
        viewName: 'LaterActionView',
        viewReferrer: 'FirstActionView',
        actionId: 'action-later',
        actionName: 'later tap',
        rumAppId: 'gc_app_harmonyos_demo',
        hasReplay: false
      };
      const resourceProperty = new Object() as SDKPropertyRecord;
      const customReplayFlag: SDKCompletedActionPropertyTestValue = { value: 'false' };
      resourceProperty['session_has_replay'] = customReplayFlag;
      const params: SDKRumResourceParamsDTO = {
        url: 'https://example.com/late-response',
        requestHeader: '',
        responseHeader: '',
        responseConnection: '',
        responseContentType: '',
        responseContentEncoding: '',
        responseContentLength: 0,
        resourceMethod: 'GET',
        responseBody: 'HTTP 500',
        resourceStatus: 500,
        resourceType: 'network',
        requestErrorStack: '',
        requestErrorMsg: '',
        property: resourceProperty
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 0,
        dnsStartTime: 0,
        tcpTime: 0,
        tcpStartTime: 0,
        sslTime: 0,
        sslStartTime: 0,
        ttfbTime: 0,
        responseTime: 0,
        firstByteTime: 0,
        firstByteStartTime: 0,
        downloadTime: 0,
        downloadStartTime: 0,
        holeRequestTime: 10,
        resourceHostIP: ''
      };
      const lineContext = createRumWorkerLineContext();
      lineContext.rumStaticFields['session_has_replay'] = 'false';
      const batch: SDKRumResourceCommandBatchDTO = {
        lineContext,
        commands: [{
          commandType: 'start',
          resourceId: 'late-resource',
          draftUuid: 'late-resource-draft',
          errorDraftUuid: 'late-resource-error-draft',
          context: startContext,
          startTime: 10
        }, {
          // This mirrors a request completing after a second click. The host
          // normally reuses startContext; the Worker also keeps it authoritative.
          commandType: 'add',
          resourceId: 'late-resource',
          draftUuid: 'late-resource-draft',
          errorDraftUuid: 'late-resource-error-draft',
          context: laterContext,
          params,
          netStatus,
          eventTime: 20
        }]
      };
      const response = await executeWorkerCommandForUnit({
        id: 'rum-resource-keeps-start-action',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const drafts = getPayloadArray(response.payload, 'syncDrafts');
      expect(drafts.length).assertEqual(2);
      let resourceLine = '';
      let errorLine = '';
      for (let i = 0; i < drafts.length; i++) {
        const draft = drafts[i] as Record<string, object>;
        const uuid = String(draft['uuid']);
        if (uuid === 'late-resource-draft') {
          resourceLine = String(draft['dataString']);
        } else if (uuid === 'late-resource-error-draft') {
          errorLine = String(draft['dataString']);
        }
      }
      expect(resourceLine.includes('action_id=action-first')).assertTrue();
      expect(resourceLine.includes('action_id=action-later')).assertFalse();
      expect(errorLine.includes('action_id=action-first')).assertTrue();
      expect(errorLine.includes('action_id=action-later')).assertFalse();
      expect(errorLine.includes('memory_total=8GB')).assertFalse();
      expect(errorLine.includes('locale=zh-Hans-CN')).assertFalse();
      expect(errorLine.includes('memory_use="51.25"')).assertFalse();
      expect(errorLine.includes('cpu_use="12.5"')).assertFalse();
      expect(errorLine.includes('battery_use="80"')).assertFalse();
      expect(resourceLine.includes('memory_total=8GB')).assertFalse();
      expect(resourceLine.includes('locale=zh-Hans-CN')).assertFalse();
      for (const line of [resourceLine, errorLine]) {
        expect(line.includes('session_has_replay=true')).assertTrue();
        expect(line.includes('session_has_replay="true"')).assertFalse();
      }
      expect(getPayloadArray(response.payload, 'rawEvents').length).assertEqual(0);

      // A custom LineDataModifier disables the line context. Both events must
      // reach the Host unformatted, with stable IDs even after Worker replay.
      const rawBatch: SDKRumResourceCommandBatchDTO = { commands: batch.commands };
      rawBatch.commands[1].customDataType = 'rum_app_error_sampled';
      for (let replay = 0; replay < 2; replay++) {
        const state = createSDKWorkerRuntimeStateWithBackend(
          SDKDedicatedPoolType.EVENT_CONSUMER, 'ResourceFallbackWorker', 'unit-worker');
        const rawResponse = handleSDKWorkerRequest({
          id: `resource-host-preparation-${replay}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
          priority: 7,
          createdAt: 1,
          payload: rawBatch as Object as SDKWorkerPayload
        }, state);
        expect(rawResponse.ok).assertTrue();
        expect(getPayloadArray(rawResponse.payload, 'syncDrafts').length).assertEqual(0);
        const events = getPayloadArray(rawResponse.payload, 'rawEvents') as Object as SDKRumEventDTO[];
        expect(events.length).assertEqual(2);
        expect(events[0].measurement).assertEqual('resource');
        expect(events[1].measurement).assertEqual('error');
        expect(events[0].uuid).assertEqual('late-resource-draft');
        expect(events[1].uuid).assertEqual('late-resource-error-draft');
        for (const event of events) {
          expect(event.tags?.['resource_id']).assertEqual('late-resource-draft');
          expect(event.tags?.['action_id']).assertEqual('action-first');
          expect(event.fields?.['session_has_replay']).assertEqual('true');
          expect(event.customDataType).assertEqual('rum_app_error_sampled');
          expect(event.time).assertEqual(event.measurement === 'resource' ? 10 : 20);
        }
        expect(getPayloadArray(rawResponse.payload, 'completedResourceIds')[0]).assertEqual('late-resource');
        expect(state.rumResources.size).assertEqual(0);
      }

      // Only the original View can promote a request after its first frame.
      startContext.hasReplay = false;
      laterContext.hasReplay = true;
      customReplayFlag.value = 'true';
      lineContext.rumStaticFields['session_has_replay'] = 'true';
      for (let matchesOriginalView = 0; matchesOriginalView < 2; matchesOriginalView++) {
        if (matchesOriginalView === 1) {
          laterContext.sessionId = startContext.sessionId;
          laterContext.viewId = startContext.viewId;
        }
        const lateReplayResponse = handleSDKWorkerRequest({
          id: `resource-late-replay-${matchesOriginalView}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
          priority: 7, createdAt: 1,
          payload: batch as Object as SDKWorkerPayload
        }, createSDKWorkerRuntimeStateWithBackend(
          SDKDedicatedPoolType.EVENT_CONSUMER, 'LateResourceReplayWorker', 'unit-worker'));
        expect(lateReplayResponse.ok).assertTrue();
        const lateReplayDrafts = getPayloadArray(lateReplayResponse.payload, 'syncDrafts');
        expect(lateReplayDrafts.length).assertEqual(2);
        for (const draft of lateReplayDrafts) {
          const lateReplayLine = String((draft as Record<string, object>)['dataString']);
          expect(lateReplayLine.includes('session_has_replay=')).assertEqual(matchesOriginalView === 1);
          expect(lateReplayLine.includes('action_id=action-first')).assertTrue();
        }
      }

      rawBatch.commands[1].shouldCollect = false;
      const droppedResponse = handleSDKWorkerRequest({
        id: 'resource-host-preparation-dropped',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: 1,
        payload: rawBatch as Object as SDKWorkerPayload
      }, createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'DroppedResourceWorker', 'unit-worker'));
      expect(droppedResponse.ok).assertTrue();
      expect(getPayloadArray(droppedResponse.payload, 'syncDrafts').length).assertEqual(0);
      expect(getPayloadArray(droppedResponse.payload, 'rawEvents').length).assertEqual(0);
    });

    it('workerRestartReplaysResourceCounters', 0, () => {
      const context: SDKRumResourceContextDTO = {
        sessionId: 'restart-session',
        viewId: 'restart-view',
        viewName: 'RestartView',
        viewReferrer: 'root',
        actionId: 'restart-action',
        actionName: 'load'
      };
      const params: SDKRumResourceParamsDTO = {
        url: 'https://restart.test/resource',
        requestHeader: '',
        responseHeader: 'content-type: text/plain',
        responseConnection: '',
        responseContentType: 'text/plain',
        responseContentEncoding: '',
        responseContentLength: 2,
        resourceMethod: 'GET',
        responseBody: 'ok',
        resourceStatus: 200,
        resourceType: 'network',
        requestErrorStack: '',
        requestErrorMsg: '',
        property: new Object() as SDKPropertyRecord
      };
      const netStatus: SDKRumResourceNetStatusDTO = {
        dnsTime: 1,
        dnsStartTime: 0,
        tcpTime: 1,
        tcpStartTime: 1,
        sslTime: 1,
        sslStartTime: 2,
        ttfbTime: 1,
        responseTime: 2,
        firstByteTime: 1,
        firstByteStartTime: 3,
        downloadTime: 1,
        downloadStartTime: 4,
        holeRequestTime: 5,
        resourceHostIP: '127.0.0.1'
      };
      const firstBatch: SDKRumResourceCommandBatchDTO = {
        commands: [{
          commandType: 'start',
          resourceId: 'restart-resource',
          draftUuid: 'restart-resource-draft',
          errorDraftUuid: 'restart-error-draft',
          context,
          startTime: 10
        }, {
          commandType: 'setContent',
          resourceId: 'restart-resource',
          draftUuid: 'restart-resource-draft',
          errorDraftUuid: 'restart-error-draft',
          context,
          params,
          eventTime: 20
        }]
      };
      const secondBatch: SDKRumResourceCommandBatchDTO = {
        commands: [{
          commandType: 'stop',
          resourceId: 'restart-resource',
          draftUuid: 'restart-resource-draft',
          errorDraftUuid: 'restart-error-draft',
          context,
          endTime: 30
        }, {
          commandType: 'setNetState',
          resourceId: 'restart-resource',
          draftUuid: 'restart-resource-draft',
          errorDraftUuid: 'restart-error-draft',
          context,
          netStatus,
          eventTime: 30
        }]
      };

      const runLifecycle = (state: SDKWorkerRuntimeState, suffix: string): SDKWorkerResponse[] => {
        handleSDKWorkerRequest({
          id: `restart-context-${suffix}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
          priority: 7,
          createdAt: 1,
          payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
        }, state);
        handleSDKWorkerRequest({
          id: `restart-first-${suffix}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
          priority: 7,
          createdAt: 2,
          payload: firstBatch as Object as SDKWorkerPayload
        }, state);
        const completed = handleSDKWorkerRequest({
          id: `restart-second-${suffix}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
          priority: 7,
          createdAt: 3,
          payload: secondBatch as Object as SDKWorkerPayload
        }, state);
        const flushed = handleSDKWorkerRequest({
          id: `restart-flush-${suffix}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
          priority: 7,
          createdAt: 4
        }, state);
        return [completed, flushed];
      };

      const originalState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'OriginalEventWorker', 'unit-worker');
      const restartedState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'RestartedEventWorker', 'unit-worker');
      const original = runLifecycle(originalState, 'original');
      const restarted = runLifecycle(restartedState, 'restarted');
      const originalDrafts = getPayloadArray(original[0].payload, 'syncDrafts');
      const restartedDrafts = getPayloadArray(restarted[0].payload, 'syncDrafts');
      const originalDeltas = getPayloadArray(original[0].payload, 'deltas');
      const restartedDeltas = getPayloadArray(restarted[0].payload, 'deltas');

      expect(originalDrafts.length).assertEqual(1);
      expect(restartedDrafts.length).assertEqual(1);
      expect(String((originalDrafts[0] as Record<string, Object>)['uuid'])).assertEqual('restart-resource-draft');
      expect(String((restartedDrafts[0] as Record<string, Object>)['uuid'])).assertEqual('restart-resource-draft');
      expect(String((originalDrafts[0] as Record<string, Object>)['dataString'])).assertEqual(
        String((restartedDrafts[0] as Record<string, Object>)['dataString']));
      expect(originalDeltas.length).assertEqual(2);
      expect(restartedDeltas.length).assertEqual(2);
      expect(JSON.stringify(originalDeltas)).assertEqual(JSON.stringify(restartedDeltas));
      // Resource completion must carry its counter mutation in the same
      // response. A subsequent periodic flush therefore has nothing left.
      expect(getPayloadArray(original[1].payload, 'deltas').length).assertEqual(0);
      expect(getPayloadArray(restarted[1].payload, 'deltas').length).assertEqual(0);
      expect(originalState.rumResources.size).assertEqual(0);
      expect(restartedState.rumResources.size).assertEqual(0);

      const checkpointRestoredState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.EVENT_CONSUMER, 'CheckpointRestoredEventWorker', 'unit-worker');
      handleSDKWorkerRequest({
        id: 'restart-context-checkpoint',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.LINE_CONTEXT_UPDATE,
        priority: 7,
        createdAt: 1,
        payload: createRumWorkerLineContext() as Object as SDKWorkerPayload
      }, checkpointRestoredState);
      const stateOnlyStart: SDKRumResourceCommandBatchDTO = {
        commands: [firstBatch.commands[0]],
        stateRecoveryOnly: true
      };
      handleSDKWorkerRequest({
        id: 'restart-state-only-start',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: 2,
        payload: stateOnlyStart as Object as SDKWorkerPayload
      }, checkpointRestoredState);
      const stateOnlyFlush = handleSDKWorkerRequest({
        id: 'restart-state-only-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: 3
      }, checkpointRestoredState);
      const completionBatch: SDKRumResourceCommandBatchDTO = {
        commands: [firstBatch.commands[1], secondBatch.commands[0], secondBatch.commands[1]]
      };
      const checkpointCompletion = handleSDKWorkerRequest({
        id: 'restart-checkpoint-completion',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH,
        priority: 7,
        createdAt: 4,
        payload: completionBatch as Object as SDKWorkerPayload
      }, checkpointRestoredState);
      const checkpointFlush = handleSDKWorkerRequest({
        id: 'restart-checkpoint-flush',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH,
        priority: 7,
        createdAt: 5
      }, checkpointRestoredState);
      const stateOnlyDeltas = getPayloadArray(stateOnlyFlush.payload, 'deltas');
      const checkpointDrafts = getPayloadArray(checkpointCompletion.payload, 'syncDrafts');
      const checkpointCompletedIds = getPayloadArray(checkpointCompletion.payload, 'completedResourceIds');
      const checkpointDeltas = getPayloadArray(checkpointCompletion.payload, 'deltas');
      const checkpointViewDelta = checkpointDeltas[0] as Record<string, Object>;
      const checkpointActionDelta = checkpointDeltas[1] as Record<string, Object>;

      expect(stateOnlyDeltas.length).assertEqual(0);
      expect(checkpointDrafts.length).assertEqual(1);
      expect(String(checkpointCompletedIds[0])).assertEqual('restart-resource');
      expect(checkpointDeltas.length).assertEqual(2);
      expect(Number(checkpointViewDelta['viewResourceDelta'])).assertEqual(1);
      // The Host releases durable pending Resource references after persisting
      // the completed draft; the Worker must not decrement them here.
      expect(Number(checkpointViewDelta['viewPendingDelta'])).assertEqual(0);
      expect(Number(checkpointActionDelta['actionResourceDelta'])).assertEqual(1);
      expect(Number(checkpointActionDelta['actionPendingDelta'])).assertEqual(0);
      expect(getPayloadArray(checkpointFlush.payload, 'deltas').length).assertEqual(0);
      expect(checkpointRestoredState.rumResources.size).assertEqual(0);
    });

    it('completedActionBuildLineInputFromDto', 0, async () => {
      const customText: SDKCompletedActionPropertyTestValue = { value: 'fast' };
      const customJson: SDKCompletedActionPropertyTestValue = { nested: 'yes' };
      const properties = new Object() as Record<string, object>;
      properties['custom_text'] = customText;
      properties['custom_json'] = customJson;
      const customReplayFlag: SDKCompletedActionPropertyTestValue = { value: 'false' };
      properties['session_has_replay'] = customReplayFlag;
      properties['duration'] = new String('must-not-override-sdk-duration');
      const launchType: SDKCompletedActionPropertyTestValue = { value: 'foreground' };
      properties['app_launch_type'] = launchType;
      const launchPhase: SDKCompletedActionLaunchPhaseTestValue = { start: 0, duration: 20 };
      properties['app_pre_application_init_time'] = launchPhase;
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
      completedAction.actionType = 'launch_cold';
      completedAction.rumAppId = 'gc_app_harmonyos_demo';
      completedAction.sessionId = 'session-1';
      completedAction.viewId = 'view-1';
      completedAction.viewName = 'Home';
      completedAction.viewReferrer = 'Launcher';
      completedAction.duration = 42;
      completedAction.errorCount = 1;
      completedAction.longTaskCount = 2;
      completedAction.resourceCount = 3;
      completedAction.hasReplay = true;
      completedAction.properties = properties;

      const batch: SDKRumCompletedActionBatchDTO = {
        actions: [completedAction]
      };
      const lineContext = createRumWorkerLineContext();
      lineContext.rumStaticFields['duration'] = 'must-not-override-sdk-duration-from-context';
      lineContext.rumStaticFields['app_launch_type'] = 'must-not-override-cold-launch-type';
      lineContext.rumStaticFields['session_has_replay'] = 'false';
      batch.lineContext = lineContext;
      const response = await executeWorkerCommandForUnit({
        id: 'rum-completed-action',
        pool: SDKDedicatedPoolType.EVENT_CONSUMER,
        command: SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH,
        priority: 7,
        createdAt: Date.now(),
        payload: batch as Object as SDKWorkerPayload
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
      expect(String(tags['action_type'])).assertEqual('launch_cold');
      expect(String(tags['app_id'])).assertEqual('gc_app_harmonyos_demo');
      expect(String(tags['view_id'])).assertEqual('view-1');
      expect(String(fields['duration'])).assertEqual('42');
      expect(String(fields['action_error_count'])).assertEqual('1');
      expect(String(fields['action_long_task_count'])).assertEqual('2');
      expect(String(fields['action_resource_count'])).assertEqual('3');
      expect(String(fields['custom_text'])).assertEqual('fast');
      expect(String(fields['session_has_replay'])).assertEqual('true');
      expect(String(fields['has_replay'])).assertEqual('true');
      expect(String(fields['custom_json']).includes('nested')).assertTrue();
      expect(String(fields['app_launch_type'])).assertEqual('foreground');
      expect(String(fields['app_pre_application_init_time'])).assertEqual('{"start":0,"duration":20}');
      const syncDrafts = getPayloadArray(response.payload, 'syncDrafts');
      const lineProtocol = String((syncDrafts[0] as Record<string, object>)['dataString']);
      expect(lineProtocol.includes('app_launch_type="foreground"')).assertTrue();
      expect(lineProtocol.includes('session_has_replay=true')).assertTrue();
      expect(lineProtocol.includes('session_has_replay="true"')).assertFalse();
      expect(getPayloadArray(response.payload, 'rawEvents').length).assertEqual(0);

      completedAction.customDataType = 'rum_app_error_sampled';
      completedAction.countViewAction = true;
      completedAction.counterFlushMaxEvents = 1;
      const rawBatch: SDKRumCompletedActionBatchDTO = { actions: [completedAction] };
      for (let replay = 0; replay < 2; replay++) {
        const rawResponse = handleSDKWorkerRequest({
          id: `raw-action-replay-${replay}`,
          pool: SDKDedicatedPoolType.EVENT_CONSUMER,
          command: SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH,
          priority: 7, createdAt: 1,
          payload: rawBatch as Object as SDKWorkerPayload
        }, createSDKWorkerRuntimeStateWithBackend(
          SDKDedicatedPoolType.EVENT_CONSUMER, 'RawActionWorker', 'unit-worker'));
        expect(rawResponse.ok).assertTrue();
        expect(getPayloadArray(rawResponse.payload, 'syncDrafts').length).assertEqual(0);
        const events = getPayloadArray(rawResponse.payload, 'rawEvents') as Object as SDKRumEventDTO[];
        expect(events.length).assertEqual(1);
        expect(events[0].uuid).assertEqual('action-sync-uuid');
        expect(events[0].time).assertEqual(12345);
        expect(events[0].customDataType).assertEqual('rum_app_error_sampled');
        expect(events[0].tags?.['action_id']).assertEqual('action-1');
        expect(events[0].tags?.['env']).assertEqual('test');
        expect(events[0].fields?.['duration']).assertEqual('42');
        expect(events[0].fields?.['session_has_replay']).assertEqual('true');
        expect(events[0].fields?.['app_launch_type']).assertEqual('foreground');
        expect(events[0].fields?.['app_pre_application_init_time']).assertEqual('{"start":0,"duration":20}');
        const deltas = getPayloadArray(rawResponse.payload, 'deltas') as Object as SDKRumCounterDeltaDTO[];
        expect(deltas.length).assertEqual(1);
        expect(deltas[0].viewActionDelta).assertEqual(1);
      }
    });

    it('uploadKeepDataIdStableInsideUploadPool', 0, async () => {
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
      expect(body.includes('sdk_data_id=pkg-1.uuid-1')).assertTrue();
      expect(body.includes('message=\"hello\"')).assertTrue();
    });

    it('uploadPrefixesMatchingResourceIds', 0, async () => {
      const resourceUuid = '64697047c13d4ac8ae1a64aa1d364d39';
      const row: SDKUploadRowDTO = {
        id: 2,
        dataType: 'rum_app',
        dataString: `resource,resource_id=${resourceUuid},sdk_data_id=${resourceUuid} status=404i 123`,
        uuid: resourceUuid,
        time: 123
      };
      const page: SDKUploadPageDTO = {
        dataType: 'rum_app',
        rows: [row],
        packageId: 'pkg-2'
      };
      const response = await executeWorkerCommandForUnit({
        id: 'upload-resource-id',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_FORMAT_BODY,
        priority: 5,
        createdAt: Date.now(),
        payload: page as Object as SDKWorkerPayload
      });

      expect(response.ok).assertTrue();
      const body = getPayloadString(response.payload, 'body');
      expect(body.includes(`resource_id=${resourceUuid}`)).assertTrue();
      expect(body.includes(`sdk_data_id=pkg-2.${resourceUuid}`)).assertTrue();
      expect(body.includes(`resource_id=pkg-2.${resourceUuid}`)).assertFalse();
    });

    it('softTimeoutDestroysStalledRequest', 0, async () => {
      let destroyCount = 0;
      const stalledRequest = new Promise<SDKUploadHttpResultDTO>((_resolve: (value: SDKUploadHttpResultDTO) => void) => {
      });
      const result = await awaitDataUploadHttpResult(
        stalledRequest,
        20,
        () => {
          destroyCount++;
        },
        () => {
          return {
            code: NetCodeStatus.FILE_TIMEOUT_CODE,
            message: 'injected soft timeout',
            errorCode: String(NetCodeStatus.FILE_TIMEOUT_CODE),
            elapsedMs: 20,
            softTimedOut: true
          };
        }
      );

      expect(destroyCount).assertEqual(1);
      expect(result.code).assertEqual(NetCodeStatus.FILE_TIMEOUT_CODE);
      expect(result.softTimedOut).assertTrue();
    });

    it('softTimeoutRetriesWithoutAckOnDbFailure', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'SoftTimeoutWorker', 'unit-worker');
      const startPayload: SDKUploadRoundStartDTO = {
        ownerId: 'soft-timeout-owner',
        taskName: 'soft-timeout-round',
        pageSize: 1,
        syncSleepTime: 0
      };
      const startResponse = handleSDKWorkerRequest({
        id: 'soft-timeout-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const executePayload: SDKUploadExecutePageDTO = {
        roundId: start.roundId,
        dataType: 'log',
        rows: [{
          id: 61,
          dataType: 'log',
          dataString: 'df_rum_harmonyos_log,sdk_data_id=soft-timeout value=1i 100',
          uuid: 'soft-timeout',
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
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
        }
      };
      const timeoutExecutor = new RetryUploadHttpExecutor(NetCodeStatus.FILE_TIMEOUT_CODE, true);
      const executeResponse = await handleSDKDataUploadWorkerRequest({
        id: 'soft-timeout-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, state, timeoutExecutor);
      const executed = executeResponse.payload as Object as SDKUploadExecutePageResultDTO;

      expect(executed.httpResult.softTimedOut).assertTrue();
      expect(executed.dbAction).assertEqual(SDKUploadDbActionDTO.REINSERT);
      expect(executed.reInsertRows.length).assertEqual(1);
      expect(executed.retryCount).assertEqual(1);
      expect(state.uploadCheckpointVersion).assertEqual(0);
      expect(state.uploadPendingPage !== null).assertTrue();

      const commitResponse = handleSDKWorkerRequest({
        id: 'soft-timeout-db-failed',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          attemptId: executed.attemptId,
          dbSucceeded: false
        } as SDKUploadCommitPageDTO as Object as SDKWorkerPayload
      }, state);
      const committed = commitResponse.payload as Object as SDKUploadCommitPageResultDTO;

      expect(state.uploadCheckpointVersion).assertEqual(0);
      expect(state.uploadPendingPage === null).assertTrue();
      expect(committed.roundHasMoreData).assertTrue();
      expect(committed.delayMs >= 500).assertTrue();
    });

    it('uploadDeflatesBeforeHttp', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'DeflateUploadWorker', 'unit-worker');
      const startResponse = handleSDKWorkerRequest({
        id: 'deflate-upload-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId: 'deflate-upload-owner',
          taskName: 'deflate-upload-round',
          pageSize: 1,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const httpExecutor = new RetryUploadHttpExecutor(200);
      const compressor = new FixedPayloadCompressor();
      setDataUploadPayloadCompressorInternal(compressor);
      const executeResponse = await handleSDKDataUploadWorkerRequest({
        id: 'deflate-upload-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: [{
            id: 81,
            dataType: 'log',
            dataString: 'df_rum_harmonyos_log,sdk_data_id=deflate message="deflate-测试" 100',
            uuid: 'deflate-upload',
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
            softTimeoutMs: 125_000,
            compressIntakeRequests: true
          }
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, state, httpExecutor);
      const executed = executeResponse.payload as Object as SDKUploadExecutePageResultDTO;
      const sentRequest = httpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(executeResponse.ok).assertTrue();
      expect(executed.successfulResponse).assertTrue();
      expect(compressor.lastBody).assertEqual(sentRequest.body);
      expect(sentRequest.contentEncoding).assertEqual('deflate');
      expect(sentRequest.compressedBody !== undefined).assertTrue();

      const compressedBody = sentRequest.compressedBody as ArrayBuffer;
      const uploadHeaders = createDataUploadHeaders(sentRequest);
      const uploadBody = getDataUploadRequestBody(sentRequest);
      expect(uploadHeaders['Content-Encoding']).assertEqual('deflate');
      expect(uploadBody === compressedBody).assertTrue();
      expect(compressedBody.byteLength).assertEqual(4);
      expect(new Uint8Array(compressedBody)[0]).assertEqual(0x78);
      expect(new Uint8Array(compressedBody)[1]).assertEqual(0x9c);
    });

    it('uploadAppliesProxyAndDns', 0, () => {
      const request: SDKUploadHttpRequestDTO = {
        datakitUrl: 'https://localhost',
        datawayUrl: '',
        clientToken: '',
        model: 'logging_v1',
        deviceTimeMs: 100,
        connectTimeoutMs: 10_000,
        readTimeoutMs: 20_000,
        softTimeoutMs: 30_000,
        compressIntakeRequests: false,
        proxy: {
          host: 'proxy.example.com',
          port: 8080,
          exclusionList: ['localhost'],
          username: 'proxy-user',
          password: 'proxy-password'
        },
        dnsServers: ['1.1.1.1', '8.8.8.8', '9.9.9.9', '208.67.222.222'],
        dnsOverHttps: 'https://dns.example.com/dns-query',
        body: 'upload-body',
        packageId: 'network-options'
      };

      const options = createDataUploadNetworkOptions(request);
      const proxy = options.usingProxy as Object as SDKUploadHttpProxyDTO;
      expect(proxy.host).assertEqual('proxy.example.com');
      expect(proxy.port).assertEqual(8080);
      expect(proxy.exclusionList[0]).assertEqual('localhost');
      expect(proxy.username).assertEqual('proxy-user');
      expect(proxy.password).assertEqual('proxy-password');
      expect((options.dnsServers as string[]).length).assertEqual(3);
      expect((options.dnsServers as string[])[2]).assertEqual('9.9.9.9');
      expect(options.dnsOverHttps).assertEqual('https://dns.example.com/dns-query');
    });

    it('deflateFailureUsesPlaintext', 0, async () => {
      class FailingPayloadCompressor implements DataUploadPayloadCompressor {
        async compress(_body: string): Promise<ArrayBuffer> {
          throw new Error('deflate unavailable');
        }
      }

      setDataUploadPayloadCompressorInternal(new FailingPayloadCompressor());
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'PlaintextFallbackUploadWorker', 'unit-worker');
      const startResponse = handleSDKWorkerRequest({
        id: 'plaintext-fallback-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId: 'plaintext-fallback-owner',
          taskName: 'plaintext-fallback-round',
          pageSize: 1,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const httpExecutor = new RetryUploadHttpExecutor(200);
      await handleSDKDataUploadWorkerRequest({
        id: 'plaintext-fallback-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: [{
            id: 82,
            dataType: 'log',
            dataString: 'df_rum_harmonyos_log,sdk_data_id=fallback value=1i 100',
            uuid: 'plaintext-fallback',
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
            softTimeoutMs: 125_000,
            compressIntakeRequests: true
          }
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, state, httpExecutor);
      const sentRequest = httpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(sentRequest.compressedBody === undefined).assertTrue();
      expect(sentRequest.contentEncoding === undefined).assertTrue();
      expect(sentRequest.body.includes(`sdk_data_id=${sentRequest.packageId}.fallback`)).assertTrue();
      expect(createDataUploadHeaders(sentRequest)['Content-Encoding'] === undefined).assertTrue();
      expect(getDataUploadRequestBody(sentRequest)).assertEqual(sentRequest.body);
    });

    it('uploadOwnsBatchAndRetryState', 0, async () => {
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

      const fullBodyMessage = 'x'.repeat(600);
      const row: SDKUploadRowDTO = {
        id: 1,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=retry-uuid message=\"' + fullBodyMessage + '\" 123',
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
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
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
      expect(executed.bodyPreview.includes(fullBodyMessage)).assertTrue();
      expect(httpExecutor.lastRequest !== null).assertTrue();
      expect((httpExecutor.lastRequest as SDKUploadHttpRequestDTO).body.includes(
        `${executed.packageId}.retry-uuid`)).assertTrue();
      expect(createDataUploadHeaders(httpExecutor.lastRequest as SDKUploadHttpRequestDTO)['X-Pkg-Id']).assertEqual(
        `rumm-${executed.packageId}`);
      expect(executed.dbAction).assertEqual(SDKUploadDbActionDTO.REINSERT);
      expect(executed.reInsertRows.length).assertEqual(1);
      expect(executed.reInsertRows[0].uuid).assertEqual(row.uuid);
      expect(executed.reInsertRows[0].dataString.includes(
        `sdk_data_id=${executed.packageId}.retry-uuid`)).assertTrue();
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

      const retryExecutePayload: SDKUploadExecutePageDTO = {
        roundId: start.roundId,
        dataType: 'log',
        rows: executed.reInsertRows,
        httpConfig: executePayload.httpConfig
      };
      const retryExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'upload-retry-execute-page',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: retryExecutePayload as Object as SDKWorkerPayload
      }, unitWorkerStates[SDKDedicatedPoolType.DATA_UPLOAD], httpExecutor);
      expect(retryExecuteResponse.ok).assertTrue();
      const retried = retryExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      expect(retried.bodyPreview.includes(`sdk_data_id=${executed.packageId}.retry-uuid`)).assertTrue();
      expect(retried.packageId).assertEqual(executed.packageId);
      expect(retried.bodyPreview).assertEqual(executed.bodyPreview);

      const retryCommitPayload: SDKUploadCommitPageDTO = {
        roundId: start.roundId,
        attemptId: retried.attemptId,
        dbSucceeded: true
      };
      const retryCommitResponse = await executeWorkerCommandForUnit({
        id: 'upload-retry-commit-page',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: retryCommitPayload as Object as SDKWorkerPayload
      });
      expect(retryCommitResponse.ok).assertTrue();
      const retryCommitted = retryCommitResponse.payload as Object as SDKUploadCommitPageResultDTO;
      expect(retryCommitted.checkpoint.version).assertEqual(2);
      expect(retryCommitted.errorCount).assertEqual(2);
      expect(retryCommitted.delayMs).assertEqual(1000);

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
      // Both attempts failed and retained the record. Only committed deletes
      // count as consumed rows; retries must not report cached data as consumed.
      expect(finished.consumedRows).assertEqual(0);
      expect(finished.hasMoreData).assertTrue();
      expect(finished.errorCount).assertEqual(2);
    });

    it('httpRestartReusesPersistedPackage', 0, async () => {
      const ownerId = 'persisted-package-restart-owner';
      const rawRow: SDKUploadRowDTO = {
        id: 91,
        dataType: 'log',
        dataString: 'df_rum_harmonyos_log,sdk_data_id=restart-uuid value=1i 100',
        uuid: 'restart-uuid',
        time: 100
      };
      const httpConfig: SDKUploadHttpConfigDTO = {
        datakitUrl: 'https://localhost',
        datawayUrl: '',
        clientToken: '',
        model: 'logging_v1',
        deviceTimeMs: 100,
        connectTimeoutMs: 60_000,
        readTimeoutMs: 60_000,
        softTimeoutMs: 125_000,
        compressIntakeRequests: false
      };
      const firstState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'PersistedPackageFirstWorker', 'unit-worker');
      const firstStartResponse = handleSDKWorkerRequest({
        id: 'persisted-package-first-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId,
          taskName: 'persisted-package-first-round',
          pageSize: 3,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, firstState);
      const firstStart = firstStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const firstPrepareResponse = handleSDKWorkerRequest({
        id: 'persisted-package-first-prepare',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: firstStart.roundId,
          dataType: 'log',
          rows: [rawRow]
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, firstState);
      const firstPrepared = firstPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;

      expect(firstPrepareResponse.ok).assertTrue();
      expect(firstPrepared.needsPersistence).assertTrue();
      expect(firstPrepared.packageId.length > 0).assertTrue();
      expect(firstPrepared.rows[0].dataString.includes(
        `sdk_data_id=${firstPrepared.packageId}.restart-uuid`)).assertTrue();

      // The Host persists firstPrepared.rows atomically before this request.
      // Do not ACK the result: this models a process death after HTTP started.
      const firstHttpExecutor = new RetryUploadHttpExecutor(500);
      const firstExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'persisted-package-first-http',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: firstStart.roundId,
          dataType: 'log',
          rows: firstPrepared.rows,
          packageId: firstPrepared.packageId,
          sdkDataIdPersisted: true,
          httpConfig
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, firstState, firstHttpExecutor);
      const firstExecuted = firstExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      const firstRequest = firstHttpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(firstExecuteResponse.ok).assertTrue();
      expect(firstExecuted.dbAction).assertEqual(SDKUploadDbActionDTO.NONE);
      expect(createDataUploadHeaders(firstRequest)['X-Pkg-Id']).assertEqual(`rumm-${firstPrepared.packageId}`);
      expect(firstRequest.body.includes(`sdk_data_id=${firstPrepared.packageId}.restart-uuid`)).assertTrue();

      const restartedState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'PersistedPackageRestartedWorker', 'unit-worker');
      const restartedStartResponse = handleSDKWorkerRequest({
        id: 'persisted-package-restart-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId,
          taskName: 'persisted-package-restart-round',
          pageSize: 3,
          syncSleepTime: 0,
          checkpoint: firstStart.checkpoint
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, restartedState);
      const restartedStart = restartedStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const restartedPrepareResponse = handleSDKWorkerRequest({
        id: 'persisted-package-restart-prepare',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: restartedStart.roundId,
          dataType: 'log',
          // This represents the durable cache after the first pre-HTTP write.
          rows: firstPrepared.rows
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, restartedState);
      const restartedPrepared = restartedPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;
      const restartedHttpExecutor = new RetryUploadHttpExecutor(200);
      const restartedExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'persisted-package-restart-http',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: restartedStart.roundId,
          dataType: 'log',
          rows: restartedPrepared.rows,
          packageId: restartedPrepared.packageId,
          sdkDataIdPersisted: true,
          httpConfig
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, restartedState, restartedHttpExecutor);
      const restartedRequest = restartedHttpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(restartedPrepareResponse.ok).assertTrue();
      expect(restartedPrepared.needsPersistence).assertFalse();
      expect(restartedPrepared.packageId).assertEqual(firstPrepared.packageId);
      expect(restartedExecuteResponse.ok).assertTrue();
      expect(createDataUploadHeaders(restartedRequest)['X-Pkg-Id']).assertEqual(`rumm-${firstPrepared.packageId}`);
      expect(restartedRequest.body.includes(`sdk_data_id=${firstPrepared.packageId}.restart-uuid`)).assertTrue();
    });

    it('uploadUseDataIdWhenLegacyRowUuidDiffers', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'LegacySdkDataIdWorker', 'unit-worker');
      const httpConfig: SDKUploadHttpConfigDTO = {
        datakitUrl: 'https://localhost',
        datawayUrl: '',
        clientToken: '',
        model: 'logging_v1',
        deviceTimeMs: 100,
        connectTimeoutMs: 60_000,
        readTimeoutMs: 60_000,
        softTimeoutMs: 125_000,
        compressIntakeRequests: false
      };
      const startResponse = handleSDKWorkerRequest({
        id: 'legacy-sdk-data-id-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId: 'legacy-sdk-data-id-owner',
          taskName: 'legacy-sdk-data-id-round',
          pageSize: 1,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const prepareResponse = handleSDKWorkerRequest({
        id: 'legacy-sdk-data-id-prepare',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: [{
            id: 92,
            dataType: 'log',
            dataString: 'df_rum_harmonyos_log,sdk_data_id=line-uuid value=1i 100',
            // Legacy rows can carry an RDB UUID different from the line tag.
            uuid: 'rdb-uuid',
            time: 100
          }]
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, state);
      const prepared = prepareResponse.payload as Object as SDKUploadPreparePageResultDTO;
      const httpExecutor = new RetryUploadHttpExecutor(200);
      const executeResponse = await handleSDKDataUploadWorkerRequest({
        id: 'legacy-sdk-data-id-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: prepared.rows,
          packageId: prepared.packageId,
          sdkDataIdPersisted: true,
          httpConfig
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, state, httpExecutor);
      const executed = executeResponse.payload as Object as SDKUploadExecutePageResultDTO;
      const commitResponse = handleSDKWorkerRequest({
        id: 'legacy-sdk-data-id-commit',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_COMMIT_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          attemptId: executed.attemptId,
          dbSucceeded: true
        } as SDKUploadCommitPageDTO as Object as SDKWorkerPayload
      }, state);

      expect(prepareResponse.ok).assertTrue();
      expect(prepared.needsPersistence).assertTrue();
      expect(prepared.rows[0].dataString.includes(`sdk_data_id=${prepared.packageId}.line-uuid`)).assertTrue();
      expect(executeResponse.ok).assertTrue();
      expect(executed.attemptId.length > 0).assertTrue();
      const retryRequest = httpExecutor.lastRequest as SDKUploadHttpRequestDTO;
      expect(retryRequest.body.includes(`sdk_data_id=${prepared.packageId}.line-uuid`)).assertTrue();
      expect(commitResponse.ok).assertTrue();
    });

    it('uploadWrapNonStandardSdkDataIdOnlyOnce', 0, async () => {
      const ownerId = 'non-standard-sdk-data-id-owner';
      const legacyRow: SDKUploadRowDTO = {
        id: 93,
        dataType: 'log',
        // This old raw value contains dots, but is not a standard P prefix.
        dataString: 'df_rum_harmonyos_log,sdk_data_id=legacy.prefix.legacy-uuid value=1i 100',
        uuid: 'legacy-uuid',
        time: 100
      };
      const httpConfig: SDKUploadHttpConfigDTO = {
        datakitUrl: 'https://localhost',
        datawayUrl: '',
        clientToken: '',
        model: 'logging_v1',
        deviceTimeMs: 100,
        connectTimeoutMs: 60_000,
        readTimeoutMs: 60_000,
        softTimeoutMs: 125_000,
        compressIntakeRequests: false
      };
      const firstState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'NonStandardSdkDataIdFirstWorker', 'unit-worker');
      const firstStartResponse = handleSDKWorkerRequest({
        id: 'non-standard-sdk-data-id-first-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId,
          taskName: 'non-standard-sdk-data-id-first-round',
          pageSize: 1,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, firstState);
      const firstStart = firstStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const firstPrepareResponse = handleSDKWorkerRequest({
        id: 'non-standard-sdk-data-id-first-prepare',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: firstStart.roundId,
          dataType: 'log',
          rows: [legacyRow]
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, firstState);
      const firstPrepared = firstPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;
      const expectedSdkDataId = `${firstPrepared.packageId}.legacy.prefix.legacy-uuid`;

      expect(firstPrepareResponse.ok).assertTrue();
      expect(firstPrepared.needsPersistence).assertTrue();
      expect(firstPrepared.rows[0].dataString.includes(`sdk_data_id=${expectedSdkDataId}`)).assertTrue();

      const firstHttpExecutor = new RetryUploadHttpExecutor(200);
      const firstExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'non-standard-sdk-data-id-first-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: firstStart.roundId,
          dataType: 'log',
          rows: firstPrepared.rows,
          packageId: firstPrepared.packageId,
          sdkDataIdPersisted: true,
          httpConfig
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, firstState, firstHttpExecutor);
      const firstExecuted = firstExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      const firstRequest = firstHttpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(firstExecuteResponse.ok).assertTrue();
      expect(firstExecuted.attemptId.length > 0).assertTrue();
      expect(createDataUploadHeaders(firstRequest)['X-Pkg-Id']).assertEqual(`rumm-${firstPrepared.packageId}`);
      expect(firstRequest.body.includes(`sdk_data_id=${expectedSdkDataId}`)).assertTrue();

      // The persisted first-attempt value must survive a process restart
      // without another package prefix being appended.
      const restartedState = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'NonStandardSdkDataIdRestartedWorker', 'unit-worker');
      const restartedStartResponse = handleSDKWorkerRequest({
        id: 'non-standard-sdk-data-id-restart-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId,
          taskName: 'non-standard-sdk-data-id-restart-round',
          pageSize: 1,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, restartedState);
      const restartedStart = restartedStartResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const restartedPrepareResponse = handleSDKWorkerRequest({
        id: 'non-standard-sdk-data-id-restart-prepare',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: restartedStart.roundId,
          dataType: 'log',
          rows: firstPrepared.rows
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, restartedState);
      const restartedPrepared = restartedPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;
      const restartedHttpExecutor = new RetryUploadHttpExecutor(200);
      const restartedExecuteResponse = await handleSDKDataUploadWorkerRequest({
        id: 'non-standard-sdk-data-id-restart-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: restartedStart.roundId,
          dataType: 'log',
          rows: restartedPrepared.rows,
          packageId: restartedPrepared.packageId,
          sdkDataIdPersisted: true,
          httpConfig
        } as SDKUploadExecutePageDTO as Object as SDKWorkerPayload
      }, restartedState, restartedHttpExecutor);
      const restartedExecuted = restartedExecuteResponse.payload as Object as SDKUploadExecutePageResultDTO;
      const restartedRequest = restartedHttpExecutor.lastRequest as SDKUploadHttpRequestDTO;

      expect(restartedPrepareResponse.ok).assertTrue();
      expect(restartedPrepared.needsPersistence).assertFalse();
      expect(restartedPrepared.packageId).assertEqual(firstPrepared.packageId);
      expect(restartedPrepared.rows[0].dataString.includes(`sdk_data_id=${expectedSdkDataId}`)).assertTrue();
      expect(restartedExecuteResponse.ok).assertTrue();
      expect(restartedExecuted.attemptId.length > 0).assertTrue();
      expect(createDataUploadHeaders(restartedRequest)['X-Pkg-Id']).assertEqual(`rumm-${firstPrepared.packageId}`);
      expect(restartedRequest.body.includes(`sdk_data_id=${expectedSdkDataId}`)).assertTrue();
    });

    it('uploadSeparatesPackagesAndRawRows', 0, () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'UploadPackageGroupingWorker', 'unit-worker');
      const startResponse = handleSDKWorkerRequest({
        id: 'upload-package-grouping-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          ownerId: 'upload-package-grouping-owner',
          taskName: 'upload-package-grouping-round',
          pageSize: 3,
          syncSleepTime: 0
        } as SDKUploadRoundStartDTO as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const packageOne = '0.first.1.persistedOne';
      const packageTwo = '0.second.1.persistedTwo';
      const firstPrepareResponse = handleSDKWorkerRequest({
        id: 'upload-package-grouping-first',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: [
            {
              id: 101,
              dataType: 'log',
              dataString: `df_rum_harmonyos_log,sdk_data_id=${packageOne}.persisted-one value=1i 100`,
              uuid: 'persisted-one',
              time: 100
            },
            {
              id: 102,
              dataType: 'log',
              dataString: `df_rum_harmonyos_log,sdk_data_id=${packageTwo}.persisted-two value=1i 101`,
              uuid: 'persisted-two',
              time: 101
            },
            {
              id: 103,
              dataType: 'log',
              dataString: 'df_rum_harmonyos_log,sdk_data_id=raw-three value=1i 102',
              uuid: 'raw-three',
              time: 102
            }
          ]
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, state);
      const firstPrepared = firstPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;

      expect(firstPrepareResponse.ok).assertTrue();
      expect(firstPrepared.packageId).assertEqual(packageOne);
      expect(firstPrepared.rows.length).assertEqual(1);
      expect(firstPrepared.needsPersistence).assertFalse();
      expect(firstPrepared.deferredRows).assertEqual(2);
      expect(firstPrepared.bodyPreview.includes(`sdk_data_id=${packageOne}.persisted-one`)).assertTrue();
      expect(firstPrepared.bodyPreview.includes(packageTwo)).assertFalse();
      expect(firstPrepared.bodyPreview.includes('raw-three')).assertFalse();

      const rawPrepareResponse = handleSDKWorkerRequest({
        id: 'upload-package-grouping-raw',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_PREPARE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: {
          roundId: start.roundId,
          dataType: 'log',
          rows: [{
            id: 103,
            dataType: 'log',
            dataString: 'df_rum_harmonyos_log,sdk_data_id=raw-three value=1i 102',
            uuid: 'raw-three',
            time: 102
          }]
        } as SDKUploadPreparePageDTO as Object as SDKWorkerPayload
      }, state);
      const rawPrepared = rawPrepareResponse.payload as Object as SDKUploadPreparePageResultDTO;

      expect(rawPrepareResponse.ok).assertTrue();
      expect(rawPrepared.packageId === packageOne).assertFalse();
      expect(rawPrepared.packageId === packageTwo).assertFalse();
      expect(rawPrepared.needsPersistence).assertTrue();
      expect(rawPrepared.bodyPreview.includes(`sdk_data_id=${rawPrepared.packageId}.raw-three`)).assertTrue();
    });

    it('uploadStopAutoRetryAfterConfiguredLimit', 0, async () => {
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
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
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

    it('uploadBoundsPageAndUtf8Body', 0, async () => {
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

      const largeMessage = 'x'.repeat(Math.floor(DATA_UPLOAD_BODY_TARGET_BYTES * 0.6));
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
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
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
      expect(executed.bodyBytes <= DATA_UPLOAD_BODY_TARGET_BYTES).assertTrue();
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

    it('uploadSendsSingleRowBeyondBodyTarget', 0, async () => {
      const state = createSDKWorkerRuntimeStateWithBackend(
        SDKDedicatedPoolType.DATA_UPLOAD, 'OversizedRowWorker', 'unit-worker');
      const startPayload: SDKUploadRoundStartDTO = {
        ownerId: 'oversized-owner',
        taskName: 'oversized-row',
        pageSize: 1,
        syncSleepTime: 0
      };
      const startResponse = handleSDKWorkerRequest({
        id: 'oversized-start',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_CONSUME,
        priority: 5,
        createdAt: Date.now(),
        payload: startPayload as Object as SDKWorkerPayload
      }, state);
      const start = startResponse.payload as Object as SDKUploadRoundStartResultDTO;
      const row: SDKUploadRowDTO = {
        id: 51,
        dataType: 'log',
        dataString: `df_rum_harmonyos_log,sdk_data_id=oversized message="${
          'x'.repeat(DATA_UPLOAD_BODY_TARGET_BYTES + 1024)}" 100`,
        uuid: 'oversized',
        time: 100
      };
      const executePayload: SDKUploadExecutePageDTO = {
        roundId: start.roundId,
        dataType: 'log',
        rows: [row],
        queryHasMore: false,
        transportLimitReached: false,
        httpConfig: {
          datakitUrl: 'https://localhost',
          datawayUrl: '',
          clientToken: '',
          model: 'logging_v1',
          deviceTimeMs: 100,
          connectTimeoutMs: 60_000,
          readTimeoutMs: 60_000,
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
        }
      };
      const httpExecutor = new RetryUploadHttpExecutor(200);
      const response = await handleSDKDataUploadWorkerRequest({
        id: 'oversized-execute',
        pool: SDKDedicatedPoolType.DATA_UPLOAD,
        command: SDKWorkerCommand.UPLOAD_EXECUTE_PAGE,
        priority: 5,
        createdAt: Date.now(),
        payload: executePayload as Object as SDKWorkerPayload
      }, state, httpExecutor);
      const result = response.payload as Object as SDKUploadExecutePageResultDTO;

      expect(result.acceptedRows).assertEqual(1);
      expect(result.rows.length).assertEqual(1);
      expect(result.attemptId.length > 0).assertTrue();
      expect(result.dbAction === SDKUploadDbActionDTO.NONE).assertFalse();
      expect(result.bodyBytes > DATA_UPLOAD_BODY_TARGET_BYTES).assertTrue();
      expect(result.bodyLimitReached).assertTrue();
      expect(result.transportLimitReached).assertFalse();
      // A full page keeps the next round eligible in case another row exists.
      expect(result.roundHasMoreData).assertTrue();
      expect((httpExecutor.lastRequest as SDKUploadHttpRequestDTO).body.length > DATA_UPLOAD_BODY_TARGET_BYTES).assertTrue();
    });

    it('ackWindowRestartRestoresCheckpoint', 0, async () => {
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
          softTimeoutMs: 125_000,
          compressIntakeRequests: false
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
