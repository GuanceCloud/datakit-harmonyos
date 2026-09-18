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
  ReplayWireframeUpdate,
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
    const updates: Array<ReplayWireframeUpdate> = [];
    for (let index = 0; index < currentWireframes.length; index++) {
      const current = currentWireframes[index];
      const previous = previousById.get(current.id);
      if (previous === undefined) {
        const add: ReplayMutationAdd = { wireframe: current };
        if (index > 0) {
          add.previousId = currentWireframes[index - 1].id;
        }
        adds.push(add);
      } else if (this.needsWireframeReplacement(previous, current)) {
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

  private createWireframeUpdate(
    previous: ReplayWireframe,
    current: ReplayWireframe
  ): ReplayWireframeUpdate | null {
    if (previous.x === current.x && previous.y === current.y &&
      previous.width === current.width && previous.height === current.height &&
      JSON.stringify(previous) === JSON.stringify(current)) {
      return null;
    }
    const update: ReplayWireframeUpdate = { id: current.id, type: current.type };
    if (previous.x !== current.x) update.x = current.x;
    if (previous.y !== current.y) update.y = current.y;
    if (previous.width !== current.width) update.width = current.width;
    if (previous.height !== current.height) update.height = current.height;
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
    return update;
  }

  /**
   * The protocol's update grammar cannot remove an optional visual field. A
   * remove/add pair is therefore required when, for example, a node changes
   * from a resource-backed image to a privacy-masked image. This prevents a
   * player from retaining an obsolete colour, border, position, or image.
   */
  private needsWireframeReplacement(previous: ReplayWireframe, current: ReplayWireframe): boolean {
    if (previous.type !== current.type) {
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
    if (JSON.stringify(previous.shapeStyle) !== JSON.stringify(current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (JSON.stringify(previous.border) !== JSON.stringify(current.border) && current.border !== undefined) {
      update.border = current.border;
    }
  }

  private appendTextUpdate(
    update: ReplayWireframeUpdate,
    previous: ReplayTextWireframe,
    current: ReplayTextWireframe
  ): void {
    if (JSON.stringify(previous.shapeStyle) !== JSON.stringify(current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (JSON.stringify(previous.border) !== JSON.stringify(current.border) && current.border !== undefined) {
      update.border = current.border;
    }
    if (previous.text !== current.text) update.text = current.text;
    if (JSON.stringify(previous.textStyle) !== JSON.stringify(current.textStyle)) update.textStyle = current.textStyle;
    if (JSON.stringify(previous.textPosition) !== JSON.stringify(current.textPosition) && current.textPosition !== undefined) {
      update.textPosition = current.textPosition;
    }
  }

  private appendImageUpdate(
    update: ReplayWireframeUpdate,
    previous: ReplayImageWireframe,
    current: ReplayImageWireframe
  ): void {
    if (JSON.stringify(previous.shapeStyle) !== JSON.stringify(current.shapeStyle) && current.shapeStyle !== undefined) {
      update.shapeStyle = current.shapeStyle;
    }
    if (JSON.stringify(previous.border) !== JSON.stringify(current.border) && current.border !== undefined) {
      update.border = current.border;
    }
    if (previous.base64 !== current.base64 && current.base64 !== undefined) update.base64 = current.base64;
    if (previous.resourceId !== current.resourceId && current.resourceId !== undefined) update.resourceId = current.resourceId;
    if (previous.mimeType !== current.mimeType && current.mimeType !== undefined) update.mimeType = current.mimeType;
    if (previous.isEmpty !== current.isEmpty && current.isEmpty !== undefined) update.isEmpty = current.isEmpty;
    if (JSON.stringify(previous.imageStyle) !== JSON.stringify(current.imageStyle) && current.imageStyle !== undefined) {
      update.imageStyle = current.imageStyle;
    }
  }
}
