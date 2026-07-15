import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import zlib from '@ohos.zlib';
import { SdkInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SdkInternalTestAccess';
import {
  SDKANRParseRequestDTO,
  SDKANRParseResultDTO,
  SDKBackgroundMetricsRequestDTO,
  SDKBackgroundMetricsResultDTO,
  SDKCrashFileDTO,
  SDKDedicatedPoolType,
  SDKNativeCrashLogBatchDTO,
  SDKTaskPriority,
  SDKWorkerCommand,
  SDKWorkerPayload,
  SDKWorkerResponse
} from '../../../main/ets/components/thread/SDKWorkerProtocol';
import { prepareDataUploadPayload } from '../../../main/ets/components/thread/workers/DataUploadCompression';

function getPayloadString(response: SDKWorkerResponse, key: string): string {
  const payload = response.payload as Record<string, object>;
  const value = payload ? payload[key] : undefined;
  return value === undefined || value === null ? '' : String(value);
}

function waitForDelay(delayMs: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), delayMs);
  });
}

interface DeviceANRTestParams {
  freeze_type: string;
  foreground: boolean;
  stack_trace: string;
}

export default function workerIntegrationDeviceTest() {
  describe('WorkerIntegrationDeviceTest', () => {
    it('dataUploadCompressionShouldDeflateAndRoundTripOnDevice', 0, async () => {
      const body = 'df_rum_harmonyos_log,sdk_data_id=device-deflate value=1i 100';
      const prepared = await prepareDataUploadPayload(body, true);

      expect(prepared.contentEncoding).assertEqual('deflate');
      expect(prepared.compressedBody !== undefined).assertTrue();
      const compressedBody = prepared.compressedBody as ArrayBuffer;
      const originalBytes = util.TextEncoder.create('utf-8').encodeInto(body);
      const restoredBody = new ArrayBuffer(originalBytes.byteLength);
      const zip = zlib.createZipSync();
      const result = await zip.uncompress(restoredBody, compressedBody, compressedBody.byteLength);

      expect(result.status).assertEqual(zlib.ReturnStatus.OK);
      expect(result.destLen).assertEqual(originalBytes.byteLength);
      const restoredBytes = new Uint8Array(restoredBody, 0, result.destLen);
      for (let i = 0; i < originalBytes.byteLength; i++) {
        expect(restoredBytes[i]).assertEqual(originalBytes[i]);
      }
    });

    it('shouldLoadDedicatedWorkersFromHarPaths', 0, async () => {
      const responses = await SdkInternalTestAccess.probeDedicatedWorkers();
      expect(responses.length).assertEqual(6);

      const expectedPools: string[] = [
        SDKDedicatedPoolType.EVENT_CONSUMER,
        SDKDedicatedPoolType.LOG_CONSUMER,
        SDKDedicatedPoolType.DATA_PROCESS,
        SDKDedicatedPoolType.CRASH,
        SDKDedicatedPoolType.ANR,
        SDKDedicatedPoolType.DATA_UPLOAD
      ];
      const seen: Record<string, boolean> = {};
      for (let i = 0; i < responses.length; i++) {
        const response = responses[i];
        expect(response.ok).assertTrue();
        const pool = getPayloadString(response, 'pool');
        const backend = getPayloadString(response, 'backend');
        const workerName = getPayloadString(response, 'workerName');
        seen[pool] = true;
        expect(backend).assertEqual('thread-worker');
        expect(workerName.length > 0).assertTrue();
      }

      for (let i = 0; i < expectedPools.length; i++) {
        expect(seen[expectedPools[i]] === true).assertTrue();
      }

      const status = SdkInternalTestAccess.getDedicatedPoolStatus();
      for (let i = 0; i < expectedPools.length; i++) {
        const poolStatus = status.pools[expectedPools[i]];
        expect(poolStatus.backend).assertEqual('thread-worker');
        expect(poolStatus.workerPath.length > 0).assertTrue();
      }
    });

    it('shouldExecuteAnrAndMetricsProductionCommandsInThreadWorkers', 0, async () => {
      const anrParams: DeviceANRTestParams = {
        freeze_type: 'THREAD_BLOCK_6S',
        foreground: true,
        stack_trace: 'main thread blocked'
      };
      const anrPayload: SDKANRParseRequestDTO = {
        eventName: 'APP_FREEZE',
        params: anrParams as Object,
        dateline: 123456,
        systemLogDirs: []
      };
      const anrResponse = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
        id: 'device-anr-parse',
        pool: SDKDedicatedPoolType.ANR,
        command: SDKWorkerCommand.ANR_PARSE_EVENT,
        priority: SDKTaskPriority.CRITICAL,
        createdAt: Date.now(),
        payload: anrPayload as Object as SDKWorkerPayload
      });
      expect(anrResponse.ok).assertTrue();
      const anrResult = anrResponse.payload as Object as SDKANRParseResultDTO;
      expect(anrResult.stackTrace.includes('main thread blocked')).assertTrue();
      expect(anrResult.foreground).assertTrue();

      const metricsPayload: SDKBackgroundMetricsRequestDTO = {
        collectCpu: true,
        collectMemory: true,
        collectBattery: true,
        cpuCacheMs: 5000,
        memoryCacheMs: 3000
      };
      const metricsResponse = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
        id: 'device-background-metrics',
        pool: SDKDedicatedPoolType.DATA_PROCESS,
        command: SDKWorkerCommand.BACKGROUND_COLLECT_METRICS,
        priority: SDKTaskPriority.BACKGROUND,
        createdAt: Date.now(),
        payload: metricsPayload as Object as SDKWorkerPayload
      });
      expect(metricsResponse.ok).assertTrue();
      const metrics = metricsResponse.payload as Object as SDKBackgroundMetricsResultDTO;
      expect(metrics.collectedAt > 0).assertTrue();
      expect(metrics.cpuTickCount >= -1).assertTrue();
      expect(metrics.memoryUsageMB >= -1).assertTrue();
      expect(metrics.batteryCurrent === metrics.batteryCurrent).assertTrue();
    });

    it('crashWorkerShouldHandleCrashParsingAndNativeLogAppend', 0, async () => {
      const nativeLogPayload: SDKNativeCrashLogBatchDTO = { logs: [] };
      const nativeLogResponse = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
        id: `device-crash-native-log-${Date.now()}`,
        pool: SDKDedicatedPoolType.CRASH,
        command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
        priority: SDKTaskPriority.LOW,
        createdAt: Date.now(),
        payload: nativeLogPayload as Object as SDKWorkerPayload
      });
      expect(nativeLogResponse.ok).assertTrue();
      expect(getPayloadString(nativeLogResponse, 'accepted')).assertEqual('0');

      const crashContent = 'native crash stack';
      const crashPayload: SDKCrashFileDTO = {
        fileName: 'native-crash.log',
        content: crashContent,
        time: 123456,
        maxLength: 1024,
        dataType: 'RUM_APP',
        measurement: 'error',
        tags: {},
        fields: {},
        uuid: 'device-crash-worker'
      };
      const parseResponse = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
        id: `device-crash-parse-${Date.now()}`,
        pool: SDKDedicatedPoolType.CRASH,
        command: SDKWorkerCommand.DATA_PARSE_CRASH_TEXT,
        priority: SDKTaskPriority.CRITICAL,
        createdAt: Date.now(),
        payload: crashPayload as Object as SDKWorkerPayload
      });
      expect(parseResponse.ok).assertTrue();
      expect(getPayloadString(parseResponse, 'originalLength')).assertEqual(String(crashContent.length));
      expect(getPayloadString(parseResponse, 'trimmedLength')).assertEqual(String(crashContent.length));
    });

    it('crashWorkerShouldRecycleWithoutLosingNativeLogBuffer', 0, async () => {
      const pool = SDKDedicatedPoolType.CRASH;
      const firstMarker = `crash-idle-before-${Date.now()}`;
      const secondMarker = `crash-idle-after-${Date.now()}`;
      const canObserveNativeLogs = SdkInternalTestAccess.clearNativeCrashLogsForTest();
      SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 50);
      try {
        const firstPayload: SDKNativeCrashLogBatchDTO = {
          logs: [{ level: 'I', tag: 'CrashIdleTest', message: firstMarker }]
        };
        const firstResponse = await SdkInternalTestAccess.postDedicatedWorkerCommandAndWait({
          id: `device-crash-idle-first-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: firstPayload as Object as SDKWorkerPayload
        }, 8000);
        expect(firstResponse.ok).assertTrue();

        await waitForDelay(300);
        const idleStatus = SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool];
        expect(idleStatus.backend).assertEqual('thread-worker-idle');
        expect(idleStatus.idleRecycleCount >= 1).assertTrue();
        if (canObserveNativeLogs) {
          expect(SdkInternalTestAccess.getCollectedNativeCrashLogsForTest(20).includes(firstMarker))
            .assertTrue();
        }

        const secondPayload: SDKNativeCrashLogBatchDTO = {
          logs: [{ level: 'I', tag: 'CrashIdleTest', message: secondMarker }]
        };
        const secondResponse = await SdkInternalTestAccess.postDedicatedWorkerCommandAndWait({
          id: `device-crash-idle-second-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: secondPayload as Object as SDKWorkerPayload
        }, 8000);
        expect(secondResponse.ok).assertTrue();
        expect(SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool].backend ===
          'thread-worker-idle').assertFalse();
        if (canObserveNativeLogs) {
          const collectedLogs = SdkInternalTestAccess.getCollectedNativeCrashLogsForTest(20);
          expect(collectedLogs.includes(firstMarker)).assertTrue();
          expect(collectedLogs.includes(secondMarker)).assertTrue();
        }
      } finally {
        SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 120000);
        SdkInternalTestAccess.clearNativeCrashLogsForTest();
      }
    });

    it('workerRestartShouldReplayPendingMailboxPingExactlyOnce', 0, async () => {
      const pool = SDKDedicatedPoolType.EVENT_CONSUMER;
      const warmup = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
        id: 'device-worker-replay-warmup',
        pool,
        command: SDKWorkerCommand.PING,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: null
      });
      expect(warmup.ok).assertTrue();

      const requestId = `device-worker-replay-ping-${Date.now()}`;
      const pendingResponse = SdkInternalTestAccess.postDedicatedWorkerCommandAndWait({
        id: requestId,
        pool,
        command: SDKWorkerCommand.PING,
        priority: SDKTaskPriority.NORMAL,
        createdAt: Date.now(),
        payload: null
      }, 8000);
      const restarted = SdkInternalTestAccess.restartDedicatedWorker(pool);
      const response = await pendingResponse;
      const status = SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool];

      expect(restarted).assertTrue();
      expect(response.ok).assertTrue();
      expect(response.id).assertEqual(requestId);
      expect(status.restartCount >= 1).assertTrue();
      expect(status.mailboxReplayCount >= 1).assertTrue();
      expect(status.mailboxReplayPending).assertEqual(0);
    });

    it('anrWorkerShouldRecycleAfterIdleAndRestartOnDemand', 0, async () => {
      const pool = SDKDedicatedPoolType.ANR;
      SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 50);
      try {
        const first = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
          id: `device-anr-idle-first-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.PING,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: null
        });
        expect(first.ok).assertTrue();

        await waitForDelay(300);
        const idleStatus = SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool];
        expect(idleStatus.backend).assertEqual('thread-worker-idle');
        expect(idleStatus.idleRecycleCount >= 1).assertTrue();

        const second = await SdkInternalTestAccess.executeDedicatedWorkerCommand({
          id: `device-anr-idle-second-${Date.now()}`,
          pool,
          command: SDKWorkerCommand.PING,
          priority: SDKTaskPriority.LOW,
          createdAt: Date.now(),
          payload: null
        });
        expect(second.ok).assertTrue();
        expect(SdkInternalTestAccess.getDedicatedPoolStatus().pools[pool].backend)
          .assertEqual('thread-worker');
      } finally {
        SdkInternalTestAccess.configureDedicatedWorkerIdleTimeout(pool, 90000);
      }
    });
  });
}
