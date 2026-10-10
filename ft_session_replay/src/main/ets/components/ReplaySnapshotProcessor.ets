import { copyReplayValue, copyReplayWireframe, replayValuesEqual } from './ReplayWireframeValues';
import {
  FullSnapshotData,
  ReplayFocusData,
  ReplayImageWireframe,
  ReplayMetaData,
  ReplayMutationAdd,
  ReplayMutationData,
  ReplayMutationRemove,
  ReplayPointerInteractionData,
  ReplayRecordType,
  ReplayShapeWireframe,
  ReplayTextWireframe,
  ReplayViewportData,
  ReplayViewportResizeData,
  ReplayViewEndData,
  ReplayWireframe,
  ReplayWireframeClip,
  ReplayWireframeUpdate,
  SessionReplayRecord
} from './SessionReplayProtocol';

/**
 * Converts privacy-safe ArkUI wireframes into the Android mobile record grammar.
 * The recorder and Worker advance this baseline only along their ordered
 * record stream; a reset requires a Full Snapshot before another mutation.
 */
export class ReplaySnapshotProcessor {
  private previousWireframes: Array<ReplayWireframe> = [];
  private baselineAvailable: boolean = false;

  public reset(): void {
    this.previousWireframes = [];
    this.baselineAvailable = false;
  }

  public hasBaseline(): boolean {
    return this.baselineAvailable;
  }

  /**
   * Makes an externally emitted Full Snapshot the next mutation baseline.
   * Without this, a forced snapshot at a context boundary could be followed by
   * mutations diffed against the older pre-boundary tree.
   */
  public setFullSnapshotBaseline(fullSnapshot: SessionReplayRecord): void {
    const data = fullSnapshot.data as FullSnapshotData;
    this.previousWireframes = data.wireframes.map((frame: ReplayWireframe): ReplayWireframe => copyReplayWireframe(frame));
    this.baselineAvailable = true;
  }

  /** Lazily advance the synchronous API's shadow from already emitted records. */
  public applyCommittedRecords(records: Array<SessionReplayRecord>): void {
    for (const record of records) {
      if (record.slotId !== undefined) continue;
      if (record.type === ReplayRecordType.FULL_SNAPSHOT) this.setFullSnapshotBaseline(record);
      else if (record.type === ReplayRecordType.INCREMENTAL_SNAPSHOT && this.baselineAvailable) {
        const mutation = record.data as ReplayMutationData;
        if (mutation.source !== 0) continue;
        for (const remove of mutation.removes) {
          this.previousWireframes = this.previousWireframes.filter((frame: ReplayWireframe): boolean => frame.id !== remove.id);
        }
        for (const add of mutation.adds) {
          const index = add.previousId === undefined ? -1 :
            this.previousWireframes.findIndex((frame: ReplayWireframe): boolean => frame.id === add.previousId);
          this.previousWireframes.splice(index + 1, 0, copyReplayWireframe(add.wireframe));
        }
        for (const update of mutation.updates) {
          const frame = this.previousWireframes.find((candidate: ReplayWireframe): boolean => candidate.id === update.id);
          if (frame === undefined) continue;
          const copy = copyReplayValue(update) as ReplayWireframeUpdate;
          if (copy.x !== undefined) frame.x = copy.x;
          if (copy.y !== undefined) frame.y = copy.y;
          if (copy.width !== undefined) frame.width = copy.width;
          if (copy.height !== undefined) frame.height = copy.height;
          if (copy.clip !== undefined) frame.clip = copy.clip;
          if (copy.zIndex !== undefined) frame.zIndex = copy.zIndex;
          if (frame.type === 'shape' || frame.type === 'text' || frame.type === 'image') {
            if (copy.shapeStyle !== undefined) frame.shapeStyle = copy.shapeStyle;
            if (copy.border !== undefined) frame.border = copy.border;
          }
          if (frame.type === 'text') {
            if (copy.text !== undefined) frame.text = copy.text;
            if (copy.textStyle !== undefined) frame.textStyle = copy.textStyle;
            if (copy.textPosition !== undefined) frame.textPosition = copy.textPosition;
          } else if (frame.type === 'image') {
            if (copy.resourceId !== undefined) frame.resourceId = copy.resourceId;
            if (copy.base64 !== undefined) frame.base64 = copy.base64;
            if (copy.mimeType !== undefined) frame.mimeType = copy.mimeType;
            if (copy.isEmpty !== undefined) frame.isEmpty = copy.isEmpty;
            if (copy.imageStyle !== undefined) frame.imageStyle = copy.imageStyle;
          } else if (frame.type === 'placeholder' && copy.label !== undefined) frame.label = copy.label;
        }
      }
    }
  }

  public createViewStartRecords(
    fullSnapshot: SessionReplayRecord,
    viewportWidth?: number,
    viewportHeight?: number
  ): Array<SessionReplayRecord> {
    const data = fullSnapshot.data as FullSnapshotData;
    const root = data.wireframes.length > 0 ? data.wireframes[0] : null;
    const hasExplicitViewport = viewportWidth !== undefined && viewportHeight !== undefined &&
      Number.isFinite(viewportWidth) && Number.isFinite(viewportHeight) &&
      viewportWidth > 0 && viewportHeight > 0;
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
    // A player can initialize its canvas from META, but the current visible
    // viewport must also be explicit. In particular, it keeps the initial
    // bounds in the same record family as later resize events.
    const viewportRecord = this.createViewportRecord(
      hasExplicitViewport ? viewportWidth : (root === null ? 0 : root.width),
      hasExplicitViewport ? viewportHeight : (root === null ? 0 : root.height),
      1,
      fullSnapshot.timestamp
    );
    this.setFullSnapshotBaseline(fullSnapshot);
    return [metaRecord, focusRecord, viewportRecord, fullSnapshot];
  }

  public createMutationRecord(fullSnapshot: SessionReplayRecord): SessionReplayRecord | null {
    const data = fullSnapshot.data as FullSnapshotData;
    const currentWireframes = data.wireframes;
    const previousById = new Map<number, ReplayWireframe>();
    const previousIndices = new Map<number, number>();
    const currentById = new Map<number, ReplayWireframe>();
    for (let index = 0; index < this.previousWireframes.length; index++) {
      const wireframe = this.previousWireframes[index];
      previousById.set(wireframe.id, wireframe);
      previousIndices.set(wireframe.id, index);
    }
    for (let index = 0; index < currentWireframes.length; index++) {
      const wireframe = currentWireframes[index];
      currentById.set(wireframe.id, wireframe);
    }

    const adds: Array<ReplayMutationAdd> = [];
    const removes: Array<ReplayMutationRemove> = [];
    const updates: Array<ReplayWireframeUpdate> = [];
    const retainedIds = this.findRetainedIds(currentWireframes, previousById, previousIndices);
    for (let index = 0; index < currentWireframes.length; index++) {
      const current = currentWireframes[index];
      const previous = previousById.get(current.id);
      if (previous === undefined) {
        const add: ReplayMutationAdd = { wireframe: current };
        if (index > 0) {
          add.previousId = currentWireframes[index - 1].id;
        }
        adds.push(add);
      } else if (!retainedIds.has(current.id)) {
        removes.push({ id: previous.id });
        const add: ReplayMutationAdd = { wireframe: current };
        if (index > 0) {
          add.previousId = currentWireframes[index - 1].id;
        }
        adds.push(add);
      } else {
        const update = this.createWireframeUpdate(previous, current);
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
    this.setFullSnapshotBaseline(fullSnapshot);
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

  /**
   * Keep the longest subsequence that already has the requested draw order.
   * A rotation [a,b,c,d] -> [d,a,b,c] then moves only d, rather than replacing
   * a, b and c. Nodes that require a visual replacement cannot be retained.
   */
  private findRetainedIds(
    currentWireframes: Array<ReplayWireframe>,
    previousById: Map<number, ReplayWireframe>,
    previousIndices: Map<number, number>
  ): Set<number> {
    const candidates: Array<ReplayWireframe> = [];
    const indices: Array<number> = [];
    const predecessors: Array<number> = [];
    const tails: Array<number> = [];
    for (const current of currentWireframes) {
      const previous = previousById.get(current.id);
      if (previous === undefined || this.needsWireframeReplacement(previous, current)) continue;
      const previousIndex = previousIndices.get(current.id)!;
      let low = 0;
      let high = tails.length;
      while (low < high) {
        const middle = Math.floor((low + high) / 2);
        if (indices[tails[middle]] < previousIndex) low = middle + 1;
        else high = middle;
      }
      const candidateIndex = candidates.length;
      candidates.push(current);
      indices.push(previousIndex);
      predecessors.push(low === 0 ? -1 : tails[low - 1]);
      tails[low] = candidateIndex;
    }
    const retained = new Set<number>();
    let cursor = tails.length === 0 ? -1 : tails[tails.length - 1];
    while (cursor !== -1) {
      retained.add(candidates[cursor].id);
      cursor = predecessors[cursor];
    }
    return retained;
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

  private createWireframeUpdate(
    previous: ReplayWireframe,
    current: ReplayWireframe
  ): ReplayWireframeUpdate | null {
    const update: ReplayWireframeUpdate = { id: current.id, type: current.type };
    if (previous.x !== current.x) update.x = current.x;
    if (previous.y !== current.y) update.y = current.y;
    if (previous.width !== current.width) update.width = current.width;
    if (previous.height !== current.height) update.height = current.height;
    if (!this.clipsEqual(previous.clip, current.clip)) {
      update.clip = {
        top: current.clip?.top ?? 0,
        right: current.clip?.right ?? 0,
        bottom: current.clip?.bottom ?? 0,
        left: current.clip?.left ?? 0
      };
    }
    if (previous.zIndex !== current.zIndex && current.zIndex !== undefined) update.zIndex = current.zIndex;
    if (current.type === 'placeholder' && previous.type === 'placeholder' && previous.label !== current.label) {
      update.label = current.label;
    }
    if (current.type === 'shape') {
      this.appendShapeUpdate(update, previous as ReplayShapeWireframe, current);
    } else if (current.type === 'text') {
      this.appendTextUpdate(update, previous as ReplayTextWireframe, current);
    } else if (current.type === 'image') {
      this.appendImageUpdate(update, previous as ReplayImageWireframe, current);
    }
    // Key ordering or equivalent zero clips can differ in serialized input
    // without changing any rendered property. Do not emit an id/type-only
    // update: existing mobile players may rebuild a node for every update.
    return Object.keys(update).length > 2 ? update : null;
  }

  private clipsEqual(previous: ReplayWireframeClip | undefined, current: ReplayWireframeClip | undefined): boolean {
    return (previous?.top ?? 0) === (current?.top ?? 0) &&
      (previous?.right ?? 0) === (current?.right ?? 0) &&
      (previous?.bottom ?? 0) === (current?.bottom ?? 0) &&
      (previous?.left ?? 0) === (current?.left ?? 0);
  }

  /**
   * Except for clip (which has an explicit zero reset), the protocol's update
   * grammar cannot remove an optional visual field. A remove/add pair is
   * therefore required when, for example, a node changes
   * from a resource-backed image to a privacy-masked image. This prevents a
   * player from retaining an obsolete colour, border, position, or image.
   */
  private needsWireframeReplacement(previous: ReplayWireframe, current: ReplayWireframe): boolean {
    if (previous.type !== current.type || previous.permanentId !== current.permanentId) {
      return true;
    }
    if (this.wasOptionalValueRemoved(previous.zIndex !== undefined, current.zIndex !== undefined)) {
      return true;
    }
    if (current.type === 'shape' && previous.type === 'shape') {
      return this.wasOptionalValueRemoved(previous.shapeStyle !== undefined, current.shapeStyle !== undefined) ||
        this.wasOptionalValueRemoved(previous.border !== undefined, current.border !== undefined);
    }
    if (current.type === 'text' && previous.type === 'text') {
      return this.wasOptionalValueRemoved(previous.shapeStyle !== undefined, current.shapeStyle !== undefined) ||
        this.wasOptionalValueRemoved(previous.border !== undefined, current.border !== undefined) ||
        this.wasOptionalValueRemoved(previous.textPosition !== undefined, current.textPosition !== undefined);
    }
    if (current.type === 'image' && previous.type === 'image') {
      return this.wasOptionalValueRemoved(previous.shapeStyle !== undefined, current.shapeStyle !== undefined) ||
        this.wasOptionalValueRemoved(previous.border !== undefined, current.border !== undefined) ||
        this.wasOptionalValueRemoved(previous.base64 !== undefined, current.base64 !== undefined) ||
        this.wasOptionalValueRemoved(previous.resourceId !== undefined, current.resourceId !== undefined) ||
        this.wasOptionalValueRemoved(previous.mimeType !== undefined, current.mimeType !== undefined) ||
        this.wasOptionalValueRemoved(previous.isEmpty !== undefined, current.isEmpty !== undefined) ||
        this.wasOptionalValueRemoved(previous.imageStyle !== undefined, current.imageStyle !== undefined);
    }
    return false;
  }

  private wasOptionalValueRemoved(previousPresent: boolean, currentPresent: boolean): boolean {
    return previousPresent && !currentPresent;
  }

  private appendShapeUpdate(
    update: ReplayWireframeUpdate,
    previous: ReplayShapeWireframe,
    current: ReplayShapeWireframe
  ): void {
    if (!replayValuesEqual(previous.shapeStyle, current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (!replayValuesEqual(previous.border, current.border) && current.border !== undefined) {
      update.border = current.border;
    }
  }

  private appendTextUpdate(
    update: ReplayWireframeUpdate,
    previous: ReplayTextWireframe,
    current: ReplayTextWireframe
  ): void {
    if (!replayValuesEqual(previous.shapeStyle, current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (!replayValuesEqual(previous.border, current.border) && current.border !== undefined) {
      update.border = current.border;
    }
    if (previous.text !== current.text) update.text = current.text;
    if (!replayValuesEqual(previous.textStyle, current.textStyle)) update.textStyle = current.textStyle;
    if (!replayValuesEqual(previous.textPosition, current.textPosition) && current.textPosition !== undefined) {
      update.textPosition = current.textPosition;
    }
  }

  private appendImageUpdate(
    update: ReplayWireframeUpdate,
    previous: ReplayImageWireframe,
    current: ReplayImageWireframe
  ): void {
    if (!replayValuesEqual(previous.shapeStyle, current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (!replayValuesEqual(previous.border, current.border) && current.border !== undefined) {
      update.border = current.border;
    }
    if (previous.base64 !== current.base64 && current.base64 !== undefined) update.base64 = current.base64;
    if (previous.resourceId !== current.resourceId && current.resourceId !== undefined) update.resourceId = current.resourceId;
    if (previous.mimeType !== current.mimeType && current.mimeType !== undefined) update.mimeType = current.mimeType;
    if (previous.isEmpty !== current.isEmpty && current.isEmpty !== undefined) update.isEmpty = current.isEmpty;
    if (!replayValuesEqual(previous.imageStyle, current.imageStyle) && current.imageStyle !== undefined) {
      update.imageStyle = current.imageStyle;
    }
  }
}
