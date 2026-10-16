import worker, { MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  nextReplayUploadSchedule,
  ReplayUploadLane,
  ReplayUploadOutcome,
  ReplayUploadReady,
  ReplayUploadSchedule,
  ReplayUploadWorkerMessage
} from '../SessionReplayUploadQueue';
import { SessionReplayResourceStore } from '../SessionReplayResourceStore';
import { SessionReplayResourceUploader, SessionReplayResourceUploadResult } from '../SessionReplayResourceUploader';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from '../SessionReplaySegmentStore';
import { SessionReplayUploader, SessionReplayUploadResult } from '../SessionReplayUploader';
import { FTSessionReplayConfig } from '../FTSessionReplayConfig';
import { ReplayResourceCleanupResult, replayResourceCleanup } from '../ReplayResourceCleanup';
import { canStartReplayUpload } from '../SessionReplayUploadConditions';

interface ReplayUploadEvent { data: ReplayUploadWorkerMessage; }
interface UploadRequest { id: number; }

const port = worker.workerPort as ThreadWorkerGlobalScope;
let lane: ReplayUploadLane = 'record';
let segmentStore: SessionReplaySegmentStore | null = null;
let resourceStore: SessionReplayResourceStore | null = null;
let intervalMs: number = 0;
let drainOnly: boolean = false;
let scheduleVersion: number = 0;
let scheduleTimer: number = -1;
let retryCount: number = 0;
let running: boolean = false;
let nextScheduledId: number = -1;
const requests: Array<UploadRequest> = [];
let readyRequestId: number = 0;
let readyResolver: ((ready: ReplayUploadReady | null) => void) | null = null;
let deletionRequestId: number = 0;
let deletionResolver: ((deleted: boolean) => void) | null = null;
let resourceDeletionResolver: ((result: ReplayResourceCleanupResult | null) => void) | null = null;

port.onmessage = (event: MessageEvents): void => {
  const message = (event as Object as ReplayUploadEvent).data;
  if (message.phase === 'init') {
    try {
      lane = message.lane ?? 'record';
      if (lane === 'record') {
        segmentStore = new SessionReplaySegmentStore(message.filesDir!, message.maxBytes!,
          message.maxRecordsPerSegment!, 'segments', false);
        resourceStore = null;
      } else {
        resourceStore = new SessionReplayResourceStore(message.filesDir!, message.maxBytes!, 'resources', false);
        segmentStore = null;
      }
    } catch (error) {
      port.postMessage({ id: 0, phase: 'fatal', lane, error: String(error) } as ReplayUploadWorkerMessage);
    }
    return;
  }
  if (message.phase === 'schedule') {
    intervalMs = Math.max(0, message.intervalMs ?? 0);
    drainOnly = message.drainOnly ?? false;
    scheduleVersion = message.scheduleVersion ?? 0;
    retryCount = 0;
    if (intervalMs <= 0) stopSchedule();
    else scheduleNext(intervalMs);
    return;
  }
  if (message.phase === 'flush') {
    requests.push({ id: message.id });
    runNext();
    return;
  }
  if (message.phase === 'wake') {
    if (intervalMs <= 0) return;
    stopSchedule();
    retryCount = 0;
    requests.push({ id: nextScheduledId-- });
    runNext();
    return;
  }
  if (message.phase === 'ready' && message.id === readyRequestId && readyResolver !== null) {
    const resolve = readyResolver;
    readyResolver = null;
    readyRequestId = 0;
    resolve(message.error === undefined ? (message.ready ?? null) : null);
    return;
  }
  if (message.phase === 'deleted' && message.id === deletionRequestId) {
    if (deletionResolver !== null) {
      const resolve = deletionResolver;
      deletionResolver = null;
      deletionRequestId = 0;
      resolve(message.deleted === true);
    } else if (resourceDeletionResolver !== null) {
      const resolve = resourceDeletionResolver;
      resourceDeletionResolver = null;
      deletionRequestId = 0;
      resolve(message.cleanup ?? null);
    }
  }
};

function scheduleNext(delayMs: number): void {
  stopSchedule();
  if (intervalMs <= 0) return;
  scheduleTimer = setTimeout((): void => {
    scheduleTimer = -1;
    requests.push({ id: nextScheduledId-- });
    runNext();
  }, Math.max(0, delayMs));
}

function stopSchedule(): void {
  if (scheduleTimer !== -1) clearTimeout(scheduleTimer);
  scheduleTimer = -1;
}

async function runNext(): Promise<void> {
  if (running || requests.length === 0) return;
  running = true;
  stopSchedule();
  const request = requests.shift()!;
  const requestScheduleVersion = scheduleVersion;
  let result: SessionReplayUploadResult | null = null;
  let resourceResult: SessionReplayResourceUploadResult | null = null;
  try {
    const ready = await requestReady(request.id);
    if (!canStartReplayUpload(ready.networkAvailable, ready.batteryHealthy)) {
      const reason = ready.networkAvailable === false
        ? 'Session Replay upload is paused while the network is unavailable.'
        : 'Session Replay upload is paused while battery power is low.';
      if (lane === 'record') result = blockedSegment(reason);
      else resourceResult = blockedResource(reason);
    } else if (lane === 'record') {
      if (segmentStore === null) throw new Error('Replay record upload Worker is not initialized.');
      const allowed = ready.segmentIds === null ? null : new Set<string>(ready.segmentIds);
      const pending = segmentStore.list().filter((segment: SessionReplayStoredSegment): boolean =>
        allowed === null || allowed.has(segment.id));
      const uploader = new SessionReplayUploader(segmentStore, new FTSessionReplayConfig(),
        (ids: Array<string>): Promise<boolean> => requestDelete(request.id, ids[0]), ready.route);
      result = await uploader.uploadPending(pending);
    } else {
      if (resourceStore === null) throw new Error('Replay resource upload Worker is not initialized.');
      const uploader = new SessionReplayResourceUploader(resourceStore, ready.route,
        (ids: Array<string>): Promise<ReplayResourceCleanupResult> =>
          requestDeleteResources(ids, ready.resourceTouchEpoch));
      resourceResult = await uploader.uploadPending();
    }
  } catch (error) {
    if (lane === 'record') result = failedSegment(String(error));
    else resourceResult = failedResource(String(error));
  }
  port.postMessage({ id: request.id, phase: 'done', lane, result: result ?? undefined,
    resourceResult: resourceResult ?? undefined, scheduleVersion: requestScheduleVersion } as ReplayUploadWorkerMessage);
  running = false;
  const drained = lane === 'record'
    ? result?.success === true && result.remainingSegments === 0
    : resourceResult?.success === true && resourceResult.remainingResources === 0;
  if (drainOnly && requestScheduleVersion === scheduleVersion && drained) intervalMs = 0;
  if (intervalMs > 0 && requests.length === 0) {
    let outcome: ReplayUploadOutcome | null = null;
    if (lane === 'record' && result !== null) {
      outcome = { success: result.success, retryable: result.retryable, endpointBlocked: result.endpointBlocked };
    } else if (lane === 'resource' && resourceResult !== null) {
      outcome = { success: resourceResult.success, retryable: resourceResult.retryable,
        endpointBlocked: resourceResult.endpointBlocked };
    }
    const schedule: ReplayUploadSchedule = nextReplayUploadSchedule(intervalMs, retryCount, outcome);
    retryCount = schedule.retryCount;
    scheduleNext(schedule.delayMs);
  }
  runNext();
}

function requestReady(id: number): Promise<ReplayUploadReady> {
  return new Promise<ReplayUploadReady>((resolve: (ready: ReplayUploadReady) => void,
    reject: (error: Error) => void): void => {
    readyRequestId = id;
    const timer = setTimeout((): void => {
      if (readyRequestId !== id || readyResolver === null) return;
      readyResolver = null;
      readyRequestId = 0;
      reject(new Error('Replay upload preparation timed out after 30 seconds.'));
    }, 30_000);
    readyResolver = (ready: ReplayUploadReady | null): void => {
      clearTimeout(timer);
      if (ready === null) reject(new Error('Replay upload preparation failed.'));
      else resolve(ready);
    };
    port.postMessage({ id, phase: 'prepare', lane } as ReplayUploadWorkerMessage);
  });
}

function requestDelete(id: number, segmentId: string): Promise<boolean> {
  return new Promise<boolean>((resolve: (deleted: boolean) => void): void => {
    const commandId = id * 1_000_000 - 1;
    deletionRequestId = commandId;
    const timer = setTimeout((): void => {
      if (deletionRequestId !== commandId || deletionResolver === null) return;
      deletionResolver = null;
      deletionRequestId = 0;
      resolve(false);
    }, 30_000);
    deletionResolver = (deleted: boolean): void => {
      clearTimeout(timer);
      resolve(deleted);
    };
    port.postMessage({ id: commandId, phase: 'delete', lane, segmentId } as ReplayUploadWorkerMessage);
  });
}

function requestDeleteResources(resourceIds: Array<string>, touchEpoch: number): Promise<ReplayResourceCleanupResult> {
  return new Promise<ReplayResourceCleanupResult>((resolve: (result: ReplayResourceCleanupResult) => void): void => {
    const commandId = nextScheduledId-- * 1_000_000 - 2;
    deletionRequestId = commandId;
    const timer = setTimeout((): void => {
      if (deletionRequestId !== commandId || resourceDeletionResolver === null) return;
      resourceDeletionResolver = null;
      deletionRequestId = 0;
      resolve(replayResourceCleanup(0, 0, resourceIds.length, 'Replay resource cleanup timed out after 30 seconds.'));
    }, 30_000);
    resourceDeletionResolver = (result: ReplayResourceCleanupResult | null): void => {
      clearTimeout(timer);
      resolve(result ?? replayResourceCleanup(0, 0, resourceIds.length, 'Replay resource cleanup returned no result.'));
    };
    port.postMessage({ id: commandId, phase: 'deleteResource', lane, resourceIds,
      resourceTouchEpoch: touchEpoch } as ReplayUploadWorkerMessage);
  });
}

function failedSegment(message: string): SessionReplayUploadResult {
  return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
    attemptedSegments: 0, uploadedSegments: 0, remainingSegments: segmentStore?.list().length ?? 0 };
}

function failedResource(message: string): SessionReplayResourceUploadResult {
  return { success: false, code: 0, message, retryable: true, endpointBlocked: false,
    attemptedResources: 0, uploadedResources: 0, remainingResources: resourceStore?.list().length ?? 0,
    cleanup: replayResourceCleanup() };
}

function blockedSegment(message: string): SessionReplayUploadResult {
  return { success: false, code: 0, message, retryable: false, endpointBlocked: false,
    attemptedSegments: 0, uploadedSegments: 0, remainingSegments: segmentStore?.listIds().length ?? 0 };
}

function blockedResource(message: string): SessionReplayResourceUploadResult {
  return { success: false, code: 0, message, retryable: false, endpointBlocked: false,
    attemptedResources: 0, uploadedResources: 0, remainingResources: resourceStore?.list().length ?? 0,
    cleanup: replayResourceCleanup() };
}
