import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import { ArkUIReplayLightSnapshot } from '../ArkUIReplayCollector';
import { SessionReplayWorkerOperations } from '../SessionReplayWorkerOperations';
import {
  isReplaySnapshotExpired,
  REPLAY_STALE_QUEUE_REASON,
  ReplayWorkerCommit,
  ReplayWorkerMessage
} from '../SessionReplayWorkQueue';

const port: ThreadWorkerGlobalScope = worker.workerPort;
let operations: SessionReplayWorkerOperations | null = null;

interface ReplayWorkerEvent {
  data: ReplayWorkerMessage;
}

port.onmessage = (event: MessageEvents): void => {
  const message = (event as Object as ReplayWorkerEvent).data;
  try {
    if (message.phase === 'init') {
      operations = new SessionReplayWorkerOperations(message.options!);
      return;
    }
    if (operations === null) throw new Error('Session Replay Worker is not initialized.');
    if (message.phase === 'addImage') {
      operations.registerImageAsset(message.componentId!, message.bytes!, message.mimeType!);
      return;
    }
    if (message.phase === 'removeImage') {
      operations.unregisterImageAsset(message.componentId!);
      return;
    }
    if (message.phase === 'materialize') {
      if (!message.draining && isReplaySnapshotExpired(message.queuedAt ?? 0, Date.now())) {
        port.postMessage({ id: message.id, phase: 'error', error: REPLAY_STALE_QUEUE_REASON } as ReplayWorkerMessage);
        return;
      }
      const materialized = operations.materialize(message.snapshot as ArkUIReplayLightSnapshot);
      port.postMessage({
        id: message.id,
        phase: 'materialized',
        snapshot: materialized.record,
        resources: materialized.resources
      } as ReplayWorkerMessage);
      return;
    }
    if (message.phase === 'process') {
      const result = operations.process(message.kind!, message.commit as ReplayWorkerCommit);
      port.postMessage({ id: message.id, phase: 'done', result } as ReplayWorkerMessage);
      return;
    }
    if (message.phase === 'records') {
      const success = operations.appendRecords(message.context!, message.records!, message.storeKind!,
        message.requiresStart ?? false);
      port.postMessage({ id: message.id, phase: 'done', success,
        error: success ? '' : operations.getLastWriteError() } as ReplayWorkerMessage);
      return;
    }
    if (message.phase === 'promote') {
      const success = operations.promote(message.sessionId!, message.timestamp!);
      port.postMessage({ id: message.id, phase: 'done', success,
        error: success ? '' : 'Session Replay error window promotion failed.' } as ReplayWorkerMessage);
      return;
    }
    if (message.phase === 'remove') {
      const success = operations.remove(message.storeKind!, message.segmentIds!);
      port.postMessage({ id: message.id, phase: 'done', success,
        error: success ? '' : 'Session Replay segment deletion failed.' } as ReplayWorkerMessage);
      return;
    }
    if (message.phase === 'list') {
      port.postMessage({ id: message.id, phase: 'done', success: true,
        segmentIds: operations.listPendingIds() } as ReplayWorkerMessage);
    }
  } catch (error) {
    port.postMessage({ id: message.id, phase: 'error', error: String(error) } as ReplayWorkerMessage);
  }
};

port.onmessageerror = (_event: MessageEvents): void => {};
port.onerror = (_event: ErrorEvent): void => {};
