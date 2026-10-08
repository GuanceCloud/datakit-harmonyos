import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse } from './FTDBTaskPoolExecutor';
import { ViewBeanJSON } from './bean/ViewBean';
import { ActionBeanJSON } from './bean/ActionBean';
import { Constants } from '../Constants';
import { parseCollectType } from '../rum/enum/RUMEnums';

export interface FTRumStoreAccess {
  read(kind: string, id: string): string | null;
  list(kind: string): string[];
  path(kind: string, id: string): string;
  commit(changes: FTCacheMutation[]): Promise<boolean>;
}

/** Implements the same aggregate command contract as SQLite, including cleanup and close. */
export class FTRumFileStore {
  private access: FTRumStoreAccess;
  constructor(access: FTRumStoreAccess) { this.access = access; }

  static handles(command: string): boolean {
    return ['cleanupExpiredRumView', 'cleanupExpiredRumAction', 'upsertRumView', 'updateRumView',
      'closeRumView', 'updateRumViewReplay', 'updateViewUploadTime', 'increaseViewAction', 'getRumPendingResource',
      'forceClearRumPendingResource', 'getActionInfo', 'applyRumCounterDeltas', 'updateViewUpdateTime',
      'setViewLongTaskDuration',
      'insertRumAction', 'closeRumAction', 'querySumAction', 'getActionCounts', 'querySumView',
      'queryRumViewById', 'cleanCloseActionData', 'cleanCloseViewData', 'closeAllActionAndView',
      'exportRumState', 'acknowledgeView'].includes(command);
  }

  async execute(request: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> {
    const changes: FTCacheMutation[] = [];
    const response: FTDBTaskPoolResponse = { ok: true };
    const view = this.view(request.viewId || '');
    const action = this.action(request.actionId || '');
    const now = request.now || Date.now();
    switch (request.command) {
      case 'upsertRumView':
      case 'updateRumView':
        response.value = !!request.view && (request.command === 'upsertRumView' || !!this.view(request.view!.id));
        if (response.value && request.view) { this.put(changes, 'view', request.view.id, request.view); }
        break;
      case 'insertRumAction': {
        const actionBean = request.actionBean;
        const actionView = actionBean && actionBean.viewId ? this.view(actionBean.viewId) : null;
        response.value = !!actionBean && !this.action(actionBean!.id);
        // Match SQLite's all-or-nothing contract: an Action that names a
        // View is not durable unless that View's action count advances too.
        if (response.value && actionBean && actionBean.viewId && !actionView) {
          response.value = false;
        }
        if (response.value && actionBean) {
          this.put(changes, 'action', actionBean.id, actionBean);
          if (actionView) {
            actionView.actionCount++;
            actionView.viewUpdateTime++;
            actionView.dataUpdateTime = Math.max(
              now,
              actionView.dataUpdateTime + 1,
              actionView.dataUploadTime + 1
            );
            this.put(changes, 'view', actionView.id, actionView);
          }
        }
        break;
      }
      case 'closeRumView':
        response.value = view !== null;
        if (view) {
          view.isClose = true; view.viewLoadTime = request.loadTime || 0;
          view.timeSpent = request.timeSpent || 0; view.dataUpdateTime = now;
          if (request.newSessionId) { view.sessionId = request.newSessionId; }
          if (request.attr) { this.applyAttr(view, request.attr); }
          this.put(changes, 'view', view.id, view);
        }
        break;
      case 'updateRumViewReplay': {
        const metadata = request.replayMetadata;
        response.value = false;
        if (view && view.sessionId === request.replaySessionId && metadata && metadata.hasReplay &&
          Number.isFinite(metadata.recordsCount) && metadata.recordsCount > 0) {
          const count = Math.max(view.recordsCount || 0, Math.floor(metadata.recordsCount));
          const sampledOnError = view.sampledOnReplayError === true || metadata.sampledOnError;
          if (view.hasReplay !== true || count !== view.recordsCount || sampledOnError !== view.sampledOnReplayError) {
            view.hasReplay = true;
            view.recordsCount = count;
            view.sampledOnReplayError = sampledOnError;
            view.viewUpdateTime++;
            view.dataUpdateTime = Math.max(now, view.dataUpdateTime + 1, view.dataUploadTime + 1);
            this.put(changes, 'view', view.id, view);
            response.value = true;
          }
        }
        break;
      }
      case 'closeRumAction':
        response.closeAction = { wasClosed: false, hadPendingResource: !!action && action.pendingResource > 0 };
        if (action && (request.force || action.pendingResource <= 0)) {
          action.isClose = true; action.actionDuration = request.duration || 0;
          response.closeAction.wasClosed = true;
          this.put(changes, 'action', action.id, action);
        }
        break;
      case 'updateViewUploadTime':
      case 'updateViewUpdateTime':
      case 'increaseViewAction':
        if (request.command === 'increaseViewAction') { response.count = view ? 1 : 0; }
        else { response.value = view !== null; }
        if (view) {
          if (request.command === 'updateViewUploadTime') { view.dataUploadTime = request.dateTime || 0; }
          else if (request.command === 'updateViewUpdateTime') { view.dataUpdateTime = now; }
          else { view.actionCount++; }
          if (request.command !== 'increaseViewAction') { view.viewUpdateTime++; }
          this.put(changes, 'view', view.id, view);
        }
        break;
      case 'setViewLongTaskDuration':
        response.value = view !== null;
        if (view) {
          const extraAttr = view.extraAttr || {};
          const stored = extraAttr[Constants.KEY_RUM_VIEW_LONG_TASK_DURATION] as Record<string, string>;
          const previous = stored ? Number(stored['value']) : 0;
          const duration = Math.max(Number.isFinite(previous) ? previous : 0, request.duration || 0);
          const durationAttr: Record<string, string> = {};
          durationAttr['value'] = String(duration);
          extraAttr[Constants.KEY_RUM_VIEW_LONG_TASK_DURATION] = durationAttr;
          view.extraAttr = extraAttr;
          view.viewUpdateTime++;
          view.dataUpdateTime = Math.max(now, view.dataUpdateTime + 1, view.dataUploadTime + 1);
          this.put(changes, 'view', view.id, view);
        }
        break;
      case 'acknowledgeView':
        response.value = this.acknowledgeView(request.view, changes, request.keepClosedView === true);
        break;
      case 'getActionInfo': response.actionInfo = action ? { startTime: action.startTime } : null; break;
      case 'getActionCounts':
        response.actionCounts = action ? {
          errorCount: action.errorCount, longTaskCount: action.longTaskCount, resourceCount: action.resourceCount
        } : null;
        break;
      case 'queryRumViewById': response.view = view; break;
      case 'getRumPendingResource':
      case 'forceClearRumPendingResource': {
        const id = (request.ids || [])[0] || '';
        const kind = request.target === 'action' ? 'action' : 'view';
        const target = kind === 'action' ? this.action(id) : this.view(id);
        response.count = target ? target.pendingResource : 0;
        if (request.command === 'forceClearRumPendingResource' && target) {
          target.pendingResource = 0;
          this.put(changes, kind, id, target); response.count = 1;
        }
        break;
      }
      case 'applyRumCounterDeltas':
        response.count = this.applyDeltas(request, changes, now);
        break;
      case 'querySumView':
        response.views = this.views().filter((v: ViewBeanJSON) => !v.isClose || v.dataUploadTime === 0 ||
          v.dataUploadTime < v.dataUpdateTime).sort((a: ViewBeanJSON, b: ViewBeanJSON) => a.startTime - b.startTime)
          .slice(0, request.limit || 50);
        break;
      case 'querySumAction':
        response.actions = this.actions().filter((a: ActionBeanJSON) => a.isClose)
          .sort((a: ActionBeanJSON, b: ActionBeanJSON) => a.startTime - b.startTime).slice(0, request.limit || 50);
        break;
      case 'exportRumState': response.views = this.views(); response.actions = this.actions(); break;
      case 'cleanCloseActionData':
        for (const id of request.ids || []) {
          const candidate = this.action(id);
          if (candidate && candidate.isClose) { changes.push({ path: this.access.path('action', id), body: null }); }
        }
        response.count = changes.length;
        break;
      case 'cleanCloseViewData':
        for (const candidate of this.views()) {
          if (request.ids && request.ids.length > 0 && !request.ids.includes(candidate.id)) { continue; }
          // Never delete an aggregate version that has not reached the durable sync queue.
          if (candidate.isClose && candidate.dataUploadTime >= candidate.dataUpdateTime && candidate.dataUploadTime > 0 &&
            (candidate.pendingResource <= 0 || candidate.dataUpdateTime <= now - 5 * 60 * 1000)) {
            changes.push({ path: this.access.path('view', candidate.id), body: null });
          }
        }
        response.count = changes.length;
        break;
      case 'cleanupExpiredRumView':
      case 'cleanupExpiredRumAction': {
        const kind = request.command === 'cleanupExpiredRumView' ? 'view' : 'action';
        const ids = this.access.list(kind);
        for (const id of ids) {
          const candidate = kind === 'view' ? this.view(id) : this.action(id);
          if (candidate && candidate.startTime < (request.cutoffTime || 0)) {
            changes.push({ path: this.access.path(kind, id), body: null });
          }
        }
        response.count = changes.length;
        break;
      }
      case 'closeAllActionAndView':
        for (const candidate of this.views()) {
          candidate.isClose = true; candidate.pendingResource = 0; candidate.dataUpdateTime = now;
          this.put(changes, 'view', candidate.id, candidate);
        }
        for (const candidate of this.actions()) {
          candidate.isClose = true; candidate.pendingResource = 0;
          this.put(changes, 'action', candidate.id, candidate);
        }
        response.count = changes.length;
        break;
      default: throw new Error(`Unsupported aggregate command: ${request.command}`);
    }
    if (changes.length > 0 && !await this.access.commit(changes)) { throw new Error('CACHE_AGGREGATE_CAPACITY'); }
    return response;
  }

  private view(id: string): ViewBeanJSON | null {
    const body = id ? this.access.read('view', id) : null;
    return body === null ? null : JSON.parse(body) as ViewBeanJSON;
  }

  private action(id: string): ActionBeanJSON | null {
    const body = id ? this.access.read('action', id) : null;
    return body === null ? null : JSON.parse(body) as ActionBeanJSON;
  }

  private views(): ViewBeanJSON[] {
    const result: ViewBeanJSON[] = [];
    for (const id of this.access.list('view')) { const row = this.view(id); if (row) { result.push(row); } }
    return result;
  }

  private actions(): ActionBeanJSON[] {
    const result: ActionBeanJSON[] = [];
    for (const id of this.access.list('action')) { const row = this.action(id); if (row) { result.push(row); } }
    return result;
  }

  private put(changes: FTCacheMutation[], kind: string, id: string, value: Object): void {
    const path = this.access.path(kind, id);
    const existing = changes.find((c: FTCacheMutation) => c.path === path);
    if (existing) { existing.body = JSON.stringify(value); }
    else { changes.push({ path, body: JSON.stringify(value) }); }
  }

  private applyDeltas(request: FTDBTaskPoolRequest, changes: FTCacheMutation[], now: number): number {
    const views = new Map<string, ViewBeanJSON>();
    const actions = new Map<string, ActionBeanJSON>();
    for (const d of request.counterDeltas || []) {
      const v = views.get(d.viewId) || this.view(d.viewId);
      if (v) {
        v.actionCount += Math.max(0, Math.floor(d.viewActionDelta));
        v.errorCount += Math.max(0, Math.floor(d.viewErrorDelta));
        v.resourceCount += Math.max(0, Math.floor(d.viewResourceDelta));
        v.longTaskCount += Math.max(0, Math.floor(d.viewLongTaskDelta));
        v.pendingResource = Math.max(0, v.pendingResource + Math.floor(d.viewPendingDelta));
        if (d.viewUpdateTimeDelta > 0) { v.viewUpdateTime += Math.floor(d.viewUpdateTimeDelta); v.dataUpdateTime = now; }
        views.set(v.id, v);
      }
      const a = actions.get(d.actionId) || this.action(d.actionId);
      if (a) {
        a.errorCount += Math.max(0, Math.floor(d.actionErrorDelta));
        a.resourceCount += Math.max(0, Math.floor(d.actionResourceDelta));
        a.longTaskCount += Math.max(0, Math.floor(d.actionLongTaskDelta));
        a.pendingResource = Math.max(0, a.pendingResource + Math.floor(d.actionPendingDelta));
        actions.set(a.id, a);
      }
    }
    views.forEach((v: ViewBeanJSON) => this.put(changes, 'view', v.id, v));
    actions.forEach((a: ActionBeanJSON) => this.put(changes, 'action', a.id, a));
    return changes.length;
  }

  // Keep the acknowledgement conditional so a delayed upload completion cannot
  // overwrite or delete a newer View aggregate. This matches the SQLite
  // acknowledgement predicates and updates both fields atomically in one commit.
  private acknowledgeView(
    snapshot: ViewBeanJSON | undefined,
    changes: FTCacheMutation[],
    keepClosedView: boolean = false
  ): boolean {
    if (!snapshot || snapshot.id.length === 0) { return false; }
    const current = this.view(snapshot.id);
    if (!current || !this.matchesAcknowledgedView(current, snapshot)) { return false; }
    if (current.isClose && current.pendingResource <= 0 && !keepClosedView) {
      changes.push({ path: this.access.path('view', current.id), body: null });
      return true;
    }
    current.dataUploadTime = current.isClose && current.pendingResource > 0 ? 0 : current.dataUpdateTime;
    current.viewUpdateTime++;
    this.put(changes, 'view', current.id, current);
    return true;
  }

  private matchesAcknowledgedView(current: ViewBeanJSON, snapshot: ViewBeanJSON): boolean {
    return current.isClose === snapshot.isClose &&
      current.dataUpdateTime === snapshot.dataUpdateTime &&
      current.viewUpdateTime === snapshot.viewUpdateTime &&
      current.pendingResource === snapshot.pendingResource &&
      current.actionCount === snapshot.actionCount &&
      current.errorCount === snapshot.errorCount &&
      current.resourceCount === snapshot.resourceCount &&
      current.longTaskCount === snapshot.longTaskCount;
  }

  private applyAttr(view: ViewBeanJSON, attr: string): void {
    const source = JSON.parse(attr) as Record<string, object>;
    const extra: Record<string, object> = {};
    for (const key of Object.keys(source)) {
      if (key === Constants.KEY_RUM_PROPERTY) { view.property = source[key] as Record<string, object>; }
      else if (key === Constants.KEY_RUM_TAGS) { view.tags = source[key] as Record<string, string>; }
      else if (key === Constants.KEY_HAS_REPLAY) {
        const marker = source[key] as ReplayViewMarker;
        view.hasReplay = view.hasReplay === true || marker.value === true;
        const count = Number(marker.recordsCount);
        view.recordsCount = Math.max(view.recordsCount || 0, Number.isFinite(count) ? Math.floor(count) : 0);
        view.sampledOnReplayError = view.sampledOnReplayError === true || marker.sampledOnReplayError === true;
      }
      else if (key === Constants.KEY_RUM_COLLECT_TYPE) {
        view.collectType = parseCollectType(String(source[key]));
      } else { extra[key] = source[key]; }
    }
    view.extraAttr = extra;
  }
}

interface ReplayViewMarker {
  value: boolean;
  recordsCount: number;
  sampledOnReplayError: boolean;
}
