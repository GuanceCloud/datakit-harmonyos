import { ViewBeanJSON } from './bean/ViewBean';

export interface FTRumViewSnapshotResult {
  acknowledged: boolean;
  changed: boolean;
  remove: boolean;
}

/** Duration checkpoints contain elapsed nanoseconds, never wall-clock time. */
export function rumViewDuration(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

function markViewChanged(view: ViewBeanJSON, now: number): void {
  view.viewUpdateTime++;
  view.dataUpdateTime = Math.max(now, view.dataUpdateTime + 1, view.dataUploadTime + 1);
}

/** Apply a durable summary without allowing a delayed callback to replace newer counters. */
export function applyDurableRumViewSnapshot(
  current: ViewBeanJSON,
  snapshot: ViewBeanJSON,
  keepClosedView: boolean,
  now: number
): FTRumViewSnapshotResult {
  const result: FTRumViewSnapshotResult = { acknowledged: false, changed: false, remove: false };
  if (current.id !== snapshot.id || current.sessionId !== snapshot.sessionId ||
    current.startTime !== snapshot.startTime) return result;

  const previousDuration = rumViewDuration(current.timeSpent);
  const reportedDuration = rumViewDuration(snapshot.timeSpent);
  result.acknowledged = current.isClose === snapshot.isClose &&
    current.dataUpdateTime === snapshot.dataUpdateTime &&
    current.viewUpdateTime === snapshot.viewUpdateTime &&
    current.pendingResource === snapshot.pendingResource &&
    current.actionCount === snapshot.actionCount &&
    current.errorCount === snapshot.errorCount &&
    current.resourceCount === snapshot.resourceCount &&
    current.longTaskCount === snapshot.longTaskCount && reportedDuration >= previousDuration;

  // Even a superseded summary reached the durable sync queue. Retain its
  // elapsed-time checkpoint, but leave the newer aggregate unacknowledged.
  if (reportedDuration > previousDuration) {
    current.timeSpent = reportedDuration;
    result.changed = true;
    if (!result.acknowledged && current.isClose) markViewChanged(current, now);
  }
  if (result.acknowledged) {
    current.dataUploadTime = current.isClose && current.pendingResource > 0 ? 0 : snapshot.dataUpdateTime;
    current.viewUpdateTime++;
    result.changed = true;
    result.remove = current.isClose && current.pendingResource <= 0 && !keepClosedView;
  }
  return result;
}

/** Seal only unfinished predecessor Views; elapsed time must not include process downtime. */
export function recoverRumView(view: ViewBeanJSON, now: number): boolean {
  if (view.isClose && view.pendingResource <= 0) return false;
  view.isClose = true;
  view.pendingResource = 0;
  markViewChanged(view, now);
  return true;
}
