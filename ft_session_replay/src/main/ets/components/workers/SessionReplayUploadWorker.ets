import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import { FTSessionReplayConfig } from '../FTSessionReplayConfig';
import { SessionReplayResourceStore } from '../SessionReplayResourceStore';
import { SessionReplayResourceUploader, SessionReplayResourceUploadResult } from '../SessionReplayResourceUploader';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from '../SessionReplaySegmentStore';
import {
  nextReplayUploadSchedule, ReplayUploadReady, ReplayUploadSchedule, ReplayUploadWorkerMessage
} from '../SessionReplayUploadQueue';
import { SessionReplayUploader, SessionReplayUploadResult } from '../SessionReplayUploader';

interface ReplayUploadEvent {
  data: ReplayUploadWorkerMessage;
}

interface UploadRequest {
  id: number;
  resourceOnly: boolean;
}

const port: ThreadWorkerGlobalScope = worker.workerPort;
const requests: Array<UploadRequest> = [];
let segmentStore: SessionReplaySegmentStore | null = null;
let resourceStore: SessionReplayResourceStore | null = null;
let running: boolean = false;
let scheduleTimer: number = -1;
let intervalMs: number = 0;
let retryCount: number = 0;
let nextScheduledId: number = -1;
let readyResolver: ((ready: ReplayUploadReady) => void) | null = null;
let readyRejecter: ((reason: Error) => void) | null = null;
let deletionResolver: ((success: boolean) => void) | null = null;
let readyRequestId: number = 0;
let deletionRequestId: number = 0;
let nextDeletionRequestId: number = 1_000_000;

port.onmessage = (event: MessageEvents): void => {
  const message = (event as Object as ReplayUploadEvent).data;
  try {
    if (message.phase === 'init') {
      segmentStore = new SessionReplaySegmentStore(message.filesDir!, message.maxBytes!,
        message.maxRecordsPerSegment!, 'segments', false);
      resourceStore = new SessionReplayResourceStore(message.filesDir!, message.maxBytes!, 'resources', false);
      return;
    }
    if (message.phase === 'schedule') {
      intervalMs = Math.max(0, message.intervalMs ?? 0);
      if (intervalMs === 0) {
        for (let index = requests.length - 1; index >= 0; index--) {
          if (requests[index].id < 0) requests.splice(index, 1);
        }
      }
      scheduleNext(intervalMs);
      return;
    }
    if (message.phase === 'flush') {
      requests.push({ id: message.id, resourceOnly: message.resourceOnly ?? false });
      runNext();
      return;
    }
    if (message.phase === 'ready') {
      if (message.id !== readyRequestId) return;
      const resolve = readyResolver;
      const reject = readyRejecter;
      readyResolver = null;
      readyRejecter = null;
      if (message.ready !== undefined) resolve?.(message.ready);
      else reject?.(new Error(message.error ?? 'Replay upload preparation failed.'));
      return;
    }
    if (message.phase === 'deleted') {
      if (message.id !== deletionRequestId) return;
      const resolve = deletionResolver;
      deletionResolver = null;
      resolve?.(message.deleted ?? false);
    }
  } catch (error) {
    port.postMessage({ id: message.id, phase: message.phase === 'init' ? 'fatal' : 'done',
      error: String(error) } as ReplayUploadWorkerMessage);
  }
};

port.onmessageerror = (_event: MessageEvents): void => {};
port.onerror = (_event: ErrorEvent): void => {};

function scheduleNext(delayMs: number): void {
  if (scheduleTimer !== -1) {
    clearTimeout(scheduleTimer);
    scheduleTimer = -1;
  }
  if (intervalMs <= 0) return;
  scheduleTimer = setTimeout((): void => {
    scheduleTimer = -1;
    requests.push({ id: nextScheduledId--, resourceOnly: false });
    runNext();
  }, Math.max(0, delayMs));
}

async function runNext(): Promise<void> {
  if (running || requests.length === 0) return;
  const request = requests.shift();
  if (request === undefined) return;
  if (scheduleTimer !== -1) {
    clearTimeout(scheduleTimer);
    scheduleTimer = -1;
  }
  running = true;
  let result: SessionReplayUploadResult | null = null;
  let resourceResult: SessionReplayResourceUploadResult | null = null;
  try {
    if (segmentStore === null || resourceStore === null) throw new Error('Replay upload Worker is not initialized.');
    const ready = await requestReady(request.id);
    const resources = new SessionReplayResourceUploader(resourceStore, ready.route,
      (ids: Array<string>): Promise<boolean> => requestDeleteResources(ids, ready.resourceTouchEpoch));
    resourceResult = await resources.uploadPending();
    if (request.resourceOnly) {
      result = null;
    } else if (!resourceResult.success) {
      result = {
        success: false, code: resourceResult.code, message: resourceResult.message,
        retryable: resourceResult.retryable, endpointBlocked: resourceResult.endpointBlocked,
        attemptedSegments: 0, uploadedSegments: 0, remainingSegments: segmentStore.list().length
      };
    } else {
      const allowed = ready.segmentIds === null ? null : new Set<string>(ready.segmentIds);
      const pending = segmentStore.list().filter((segment: SessionReplayStoredSegment): boolean =>
        allowed === null || allowed.has(segment.id));
      const uploader = new SessionReplayUploader(segmentStore, new FTSessionReplayConfig(),
        (ids: Array<string>): Promise<boolean> => requestDelete(request.id, ids[0]), ready.route);
      result = await uploader.uploadPending(pending);
    }
  } catch (error) {
    const message = String(error);
    if (request.resourceOnly) resourceResult = failedResource(message);
    else result = failedSegment(message);
  }
  port.postMessage({
    id: request.id, phase: 'done', result: result ?? undefined,
    resourceResult: resourceResult ?? undefined
  } as ReplayUploadWorkerMessage);
  running = false;
  if (intervalMs > 0 && requests.length === 0) {
    const schedule: ReplayUploadSchedule = nextReplayUploadSchedule(intervalMs, retryCount, result);
    retryCount = schedule.retryCount;
    scheduleNext(schedule.delayMs);
  }
  runNext();
}

function requestReady(id: number): Promise<ReplayUploadReady> {
  return new Promise<ReplayUploadReady>((resolve: (ready: ReplayUploadReady) => void,
    reject: (reason: Error) => void): void => {
    readyRequestId = id;
    const timer = setTimeout((): void => {
      if (readyRequestId !== id || readyResolver === null) return;
      readyResolver = null;
      readyRejecter = null;
      reject(new Error('Replay upload preparation timed out.'));
    }, 30_000);
    readyResolver = (ready: ReplayUploadReady): void => {
      clearTimeout(timer);
      resolve(ready);
    };
    readyRejecter = (reason: Error): void => {
      clearTimeout(timer);
      reject(reason);
    };
    port.postMessage({ id, phase: 'prepare' } as ReplayUploadWorkerMessage);
  });
}

function requestDelete(_id: number, segmentId: string): Promise<boolean> {
  return new Promise<boolean>((resolve: (success: boolean) => void): void => {
    const commandId = ++nextDeletionRequestId;
    deletionRequestId = commandId;
    const timer = setTimeout((): void => {
      if (deletionRequestId !== commandId || deletionResolver === null) return;
      deletionResolver = null;
      resolve(false);
    }, 30_000);
    deletionResolver = (success: boolean): void => {
      clearTimeout(timer);
      resolve(success);
    };
    port.postMessage({ id: commandId, phase: 'delete', segmentId } as ReplayUploadWorkerMessage);
  });
}

function requestDeleteResources(resourceIds: Array<string>, resourceTouchEpoch: number): Promise<boolean> {
  return new Promise<boolean>((resolve: (success: boolean) => void): void => {
    const commandId = ++nextDeletionRequestId;
    deletionRequestId = commandId;
    const timer = setTimeout((): void => {
      if (deletionRequestId !== commandId || deletionResolver === null) return;
      deletionResolver = null;
      resolve(false);
    }, 30_000);
    deletionResolver = (success: boolean): void => {
      clearTimeout(timer);
      resolve(success);
    };
    port.postMessage({ id: commandId, phase: 'deleteResource', resourceIds,
      resourceTouchEpoch } as ReplayUploadWorkerMessage);
  });
}

function failedSegment(message: string): SessionReplayUploadResult {
  return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
    attemptedSegments: 0, uploadedSegments: 0, remainingSegments: segmentStore?.list().length ?? 0 };
}

function failedResource(message: string): SessionReplayResourceUploadResult {
  return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
    attemptedResources: 0, uploadedResources: 0, remainingResources: resourceStore?.list().length ?? 0 };
}
