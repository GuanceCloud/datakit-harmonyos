import hilog from '@ohos.hilog';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { systemDateTime } from '@kit.BasicServicesKit';

export const STRESS_REAL_LOG_DOMAIN = 0xD003;
export const STRESS_REAL_LOG_TAG = 'FTStressRealLog';
export const STRESS_REAL_LOG_PREFIX = 'STRESS_REAL_RUNTIME';
export const STRESS_REAL_LOG_FILTER =
  "{ log_source = 'hilog' and tag = 'FTStressRealLog' and domain = '53251' " +
  "and message match ['^STRESS_REAL_RUNTIME'] }";
export const DEFAULT_REAL_LONG_TASK_DURATION_MS = 600;
// A cold AppService start has no foreground UI until EntryAbility says otherwise.
let collectionInForeground: boolean = false;

export function setStressCollectionForeground(inForeground: boolean): void {
  collectionInForeground = inForeground;
}

export function isStressCollectionForeground(): boolean {
  return collectionInForeground;
}

export function normalizeRealLongTaskDuration(value: number = DEFAULT_REAL_LONG_TASK_DURATION_MS): number {
  return Number.isFinite(value) ? Math.min(2000, Math.max(350, Math.floor(value))) :
    DEFAULT_REAL_LONG_TASK_DURATION_MS;
}

/** Real application output; the Hvigor plugin collects this HiLog call. */
export function emitStressRuntimeLog(index: number, startedAtMs: number): void {
  let heapKb = -1;
  try {
    heapKb = Number(hidebug.getAppVMMemoryInfo().totalHeap);
  } catch (error) {
    // Keep the real log output available on devices without VM diagnostics.
  }
  hilog.info(STRESS_REAL_LOG_DOMAIN, STRESS_REAL_LOG_TAG, '%{public}s',
    `${STRESS_REAL_LOG_PREFIX} index=${index} elapsed_ms=${Date.now() - startedAtMs} vm_heap_kb=${heapKb}`);
}

/** Exercise a failing runtime operation and preserve its actual exception stack. */
export function captureStressRuntimeError(index: number): Error {
  try {
    JSON.parse(`{"stress_error_index":${index},}`);
  } catch (error) {
    return error as Error;
  }
  throw new Error('Invalid stress JSON unexpectedly parsed');
}

/** Each invocation occupies one main-thread turn. SDK system observers report jank separately. */
export function runStressMainThreadBlock(durationMs: number): number {
  const startedAtMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  const targetDurationMs = normalizeRealLongTaskDuration(durationMs);
  let elapsedMs = 0;
  while (elapsedMs < targetDurationMs) {
    elapsedMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false) - startedAtMs;
  }
  return elapsedMs;
}
