import {
  FullSnapshotData,
  ReplayFocusData,
  ReplayMetaData,
  ReplayMutationAdd,
  ReplayMutationData,
  ReplayMutationRemove,
  ReplayPlaceholderUpdate,
  ReplayPointerInteractionData,
  ReplayRecordType,
  ReplayViewportData,
  ReplayViewportResizeData,
  ReplayViewEndData,
  ReplayWireframe,
  SessionReplayRecord
} from './SessionReplayProtocol';

/**
 * Converts privacy-safe ArkUI wireframes into the Android mobile record grammar.
 * It owns only an in-memory baseline; persistence and upload are deliberately
 * deferred to a later priority.
 */
export class ReplaySnapshotProcessor {
  private previousWireframes: Array<ReplayWireframe> = [];

  public reset(): void {
    this.previousWireframes = [];
  }

  /**
   * Makes an externally emitted Full Snapshot the next mutation baseline.
   * Without this, a forced snapshot at a context boundary could be followed by
   * mutations diffed against the older pre-boundary tree.
   */
  public setFullSnapshotBaseline(fullSnapshot: SessionReplayRecord): void {
    const data = fullSnapshot.data as FullSnapshotData;
    this.previousWireframes = data.wireframes.slice();
  }

  public createViewStartRecords(fullSnapshot: SessionReplayRecord): Array<SessionReplayRecord> {
    const data = fullSnapshot.data as FullSnapshotData;
    const root = data.wireframes.length > 0 ? data.wireframes[0] : null;
    const meta: ReplayMetaData = {
      width: root === null ? 0 : root.width,
      height: root === null ? 0 : root.height
    };
    const focus: ReplayFocusData = { has_focus: true };
    const metaRecord: SessionReplayRecord = {
      timestamp: fullSnapshot.timestamp,
      type: ReplayRecordType.META,
      data: meta
    };
    const focusRecord: SessionReplayRecord = {
      timestamp: fullSnapshot.timestamp,
      type: ReplayRecordType.FOCUS,
      data: focus
    };
    this.setFullSnapshotBaseline(fullSnapshot);
    return [metaRecord, focusRecord, fullSnapshot];
  }

  public createMutationRecord(fullSnapshot: SessionReplayRecord): SessionReplayRecord | null {
    const data = fullSnapshot.data as FullSnapshotData;
    const currentWireframes = data.wireframes;
    const previousById = new Map<number, ReplayWireframe>();
    const currentById = new Map<number, ReplayWireframe>();
    for (let index = 0; index < this.previousWireframes.length; index++) {
      const wireframe = this.previousWireframes[index];
      previousById.set(wireframe.id, wireframe);
    }
    for (let index = 0; index < currentWireframes.length; index++) {
      const wireframe = currentWireframes[index];
      currentById.set(wireframe.id, wireframe);
    }

    const adds: Array<ReplayMutationAdd> = [];
    const removes: Array<ReplayMutationRemove> = [];
    const updates: Array<ReplayPlaceholderUpdate> = [];
    for (let index = 0; index < currentWireframes.length; index++) {
      const current = currentWireframes[index];
      const previous = previousById.get(current.id);
      if (previous === undefined) {
        const add: ReplayMutationAdd = { wireframe: current };
        if (index > 0) {
          add.previousId = currentWireframes[index - 1].id;
        }
        adds.push(add);
      } else {
        const update = this.createPlaceholderUpdate(previous, current);
        if (update !== null) {
          updates.push(update);
        }
      }
    }
    for (let index = 0; index < this.previousWireframes.length; index++) {
      const previous = this.previousWireframes[index];
      if (!currentById.has(previous.id)) {
        removes.push({ id: previous.id });
      }
    }
    this.previousWireframes = currentWireframes.slice();
    if (adds.length === 0 && removes.length === 0 && updates.length === 0) {
      return null;
    }
    const mutation: ReplayMutationData = {
      source: 0,
      adds,
      removes,
      updates
    };
    return {
      timestamp: fullSnapshot.timestamp,
      type: ReplayRecordType.INCREMENTAL_SNAPSHOT,
      data: mutation
    };
  }

  public createFocusRecord(hasFocus: boolean, timestamp: number = Date.now()): SessionReplayRecord {
    const data: ReplayFocusData = { has_focus: hasFocus };
    return { timestamp, type: ReplayRecordType.FOCUS, data };
  }

  public createViewportRecord(
    width: number,
    height: number,
    scale: number = 1,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    const data: ReplayViewportData = {
      width,
      height,
      offsetLeft: 0,
      offsetTop: 0,
      pageLeft: 0,
      pageTop: 0,
      scale
    };
    return { timestamp, type: ReplayRecordType.VIEWPORT, data };
  }

  public createViewportResizeRecord(width: number, height: number, timestamp: number = Date.now()): SessionReplayRecord {
    const data: ReplayViewportResizeData = { source: 4, width, height };
    return { timestamp, type: ReplayRecordType.INCREMENTAL_SNAPSHOT, data };
  }

  public createPointerRecord(
    pointerEventType: 'down' | 'up' | 'move',
    pointerId: number,
    x: number,
    y: number,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    const data: ReplayPointerInteractionData = {
      source: 9,
      pointerEventType,
      pointerType: 'touch',
      pointerId,
      x,
      y
    };
    return { timestamp, type: ReplayRecordType.INCREMENTAL_SNAPSHOT, data };
  }

  public createViewEndRecord(timestamp: number = Date.now()): SessionReplayRecord {
    const data: ReplayViewEndData = {};
    return { timestamp, type: ReplayRecordType.VIEW_END, data };
  }

  private createPlaceholderUpdate(
    previous: ReplayWireframe,
    current: ReplayWireframe
  ): ReplayPlaceholderUpdate | null {
    if (previous.x === current.x && previous.y === current.y &&
      previous.width === current.width && previous.height === current.height &&
      previous.label === current.label) {
      return null;
    }
    const update: ReplayPlaceholderUpdate = { id: current.id, type: 'placeholder' };
    if (previous.x !== current.x) update.x = current.x;
    if (previous.y !== current.y) update.y = current.y;
    if (previous.width !== current.width) update.width = current.width;
    if (previous.height !== current.height) update.height = current.height;
    if (previous.label !== current.label) update.label = current.label;
    return update;
  }
}
