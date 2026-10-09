import { FrameNode } from '@kit.ArkUI';
import { ReplayWireframeClip } from './SessionReplayProtocol';

/** Window-space vp bounds; scene records use an origin relative to these bounds. */
export interface ArkUIReplaySceneBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** UI-only references, never sent to the Worker or persisted. */
export interface ArkUIReplayScenePage {
  key: string;
  rootId: string;
  root: FrameNode | null;
  retained: boolean;
  parentKey?: string;
  paintOrder?: number;
}

/** UI-thread handoff; opaque Inspector values are privacy-filtered by the Worker before persistence. */
export interface ArkUIReplayLightNode {
  id: number;
  x: number;
  y: number;
  width: number;
  height: number;
  componentId: string;
  nodeType: string;
  inspectorInfo: Object | null;
  shouldCaptureAsText: boolean;
  isRoot: boolean;
  usedTransformedPosition: boolean;
  opacity?: number;
  clip?: ReplayWireframeClip;
  sceneLayer?: number;
  isPageSurface?: boolean;
}

export interface ArkUIReplayLightSnapshot {
  timestamp: number;
  vpToPxScale: number;
  nodes: Array<ArkUIReplayLightNode>;
}

/** Progress is supplied by the actual animation callback, never a guessed duration. */
export interface ArkUIReplayPageTransition {
  entering: boolean;
  progress: number;
  slide?: SlideEffect;
  opacity?: number;
}

export interface ArkUIReplaySceneFrame {
  key: string;
  bounds: ArkUIReplaySceneBounds;
  nativeX: number;
  nativeY: number;
  nodes: Array<ArkUIReplayLightNode>;
}

interface SceneMovement {
  x: number;
  y: number;
  opacity: number;
}

/** Bounded detached UI data for pages whose native node disappears before exit completes. */
export class SessionReplayScene {
  private readonly frames: Map<string, ArkUIReplaySceneFrame> = new Map();
  private readonly slideBounds: Map<string, ArkUIReplaySceneBounds> = new Map();
  private readonly pageLayers: Map<string, number> = new Map();

  public clear(): void {
    this.frames.clear();
    this.slideBounds.clear();
    this.pageLayers.clear();
  }

  public compose(
    pages: Array<ArkUIReplayScenePage>, liveFrames: Array<ArkUIReplaySceneFrame>,
    viewport: ArkUIReplaySceneBounds, transitions: Map<string, ArkUIReplayPageTransition>,
    maxNodes: number
  ): Array<ArkUIReplayLightNode> {
    const requested = new Map<string, ArkUIReplayScenePage>();
    for (const page of pages) requested.set(page.key, page);
    this.pageLayers.forEach((_layer: number, key: string): void => {
      if (!requested.has(key)) this.pageLayers.delete(key);
    });
    this.assignPageLayers(pages, maxNodes);
    this.frames.forEach((_frame: ArkUIReplaySceneFrame, key: string): void => {
      if (!requested.has(key)) {
        this.frames.delete(key);
        this.slideBounds.delete(key);
      }
    });
    const live = new Set<string>();
    for (const frame of liveFrames) {
      live.add(frame.key);
      this.frames.set(frame.key, frame);
    }
    // A lifecycle grace period is not animation progress. Once a default
    // Router page becomes unreadable, repeating its last native transform
    // would freeze a half-exited page over its successor. Detached data is
    // reusable only while an actual exit callback supplies its progress.
    this.frames.forEach((_frame: ArkUIReplaySceneFrame, key: string): void => {
      if (live.has(key)) return;
      const page = requested.get(key);
      const transition = transitions.get(key) ?? transitions.get(page?.rootId ?? key);
      if (page?.retained !== true || transition === undefined || transition.entering || transition.progress >= 1) {
        this.frames.delete(key);
        this.slideBounds.delete(key);
      }
    });
    // Bound detached memory to the same node budget as an emitted scene.
    let cachedNodes = 0;
    for (let index = pages.length - 1; index >= 0; index--) {
      const frame = this.frames.get(pages[index].key);
      if (frame === undefined) continue;
      if (cachedNodes + frame.nodes.length > maxNodes && !live.has(frame.key)) {
        this.frames.delete(frame.key);
        this.slideBounds.delete(frame.key);
      } else cachedNodes += frame.nodes.length;
    }
    const result: Array<ArkUIReplayLightNode> = [];
    const seen = new Set<number>();
    const movements = new Map<string, SceneMovement>();
    for (const page of pages) {
      const frame = this.frames.get(page.key);
      if (frame === undefined || (!live.has(page.key) && !page.retained)) continue;
      if (page.parentKey !== undefined && !movements.has(page.parentKey)) continue;
      const transition = transitions.get(page.key) ?? transitions.get(page.rootId);
      const parent = page.parentKey === undefined ? undefined : movements.get(page.parentKey);
      const parentFrame = page.parentKey === undefined ? undefined : this.frames.get(page.parentKey);
      const parentNativeX = parentFrame?.nativeX ?? 0;
      const parentNativeY = parentFrame?.nativeY ?? 0;
      let dx = frame.nativeX - parentNativeX;
      let dy = frame.nativeY - parentNativeY;
      let opacity = parent?.opacity ?? 1;
      if (transition !== undefined) {
        const bounds = this.slideBounds.get(page.key) ?? frame.bounds;
        if (transition.progress < 1) this.slideBounds.set(page.key, bounds);
        const progress = transition.entering ? 1 - transition.progress : transition.progress;
        // Page slides are based on that page's original size, independent of
        // the moving union of incoming/outgoing roots and split-pane siblings.
        const slideX = transition.slide === SlideEffect.Left ? -bounds.width :
          transition.slide === SlideEffect.Right ? bounds.width : 0;
        const slideY = transition.slide === SlideEffect.Top ? -bounds.height :
          transition.slide === SlideEffect.Bottom ? bounds.height : 0;
        if (slideX !== 0 && (!live.has(page.key) || Math.abs(dx) < 0.5 || Math.abs(dx - slideX) < 0.5)) {
          dx = slideX * progress;
        }
        if (slideY !== 0 && (!live.has(page.key) || Math.abs(dy) < 0.5 || Math.abs(dy - slideY) < 0.5)) {
          dy = slideY * progress;
        }
        if (transition.opacity !== undefined) opacity *= 1 + (transition.opacity - 1) * progress;
        if (transition.progress >= 1) this.slideBounds.delete(page.key);
      } else {
        this.slideBounds.delete(page.key);
      }
      dx += parent?.x ?? 0;
      dy += parent?.y ?? 0;
      movements.set(page.key, { x: dx, y: dy, opacity });
      for (const source of frame.nodes) {
        if (result.length >= maxNodes) break;
        if (seen.has(source.id)) continue;
        seen.add(source.id);
        const x = this.round(source.x + dx - viewport.x);
        const y = this.round(source.y + dy - viewport.y);
        const clip: ReplayWireframeClip = {
          top: this.round(Math.max(source.clip?.top ?? 0, Math.min(source.height, Math.max(0, -y)))),
          right: this.round(Math.max(source.clip?.right ?? 0,
            Math.min(source.width, Math.max(0, x + source.width - viewport.width)))),
          bottom: this.round(Math.max(source.clip?.bottom ?? 0,
            Math.min(source.height, Math.max(0, y + source.height - viewport.height)))),
          left: this.round(Math.max(source.clip?.left ?? 0, Math.min(source.width, Math.max(0, -x))))
        };
        result.push({
          id: source.id, x, y, width: source.width, height: source.height,
          componentId: source.componentId, nodeType: source.nodeType, inspectorInfo: source.inspectorInfo,
          shouldCaptureAsText: source.shouldCaptureAsText, isRoot: source.isRoot,
          usedTransformedPosition: source.usedTransformedPosition,
          opacity: (source.opacity ?? 1) * opacity, clip,
          sceneLayer: this.pageLayers.get(page.key), isPageSurface: source.isPageSurface
        });
      }
    }
    return result;
  }

  /** Reserve gaps so a returning page can fit below the outgoing page without relayering it. */
  private assignPageLayers(pages: Array<ArkUIReplayScenePage>, maxNodes: number): void {
    const gap = Math.max(1, maxNodes + 1);
    const stride = gap * 1024;
    let previous = 0;
    for (let index = 0; index < pages.length; index++) {
      const key = pages[index].key;
      let layer = this.pageLayers.get(key);
      if (layer === undefined || layer - previous < gap) {
        let next: number | undefined = undefined;
        for (let ahead = index + 1; ahead < pages.length; ahead++) {
          const candidate = this.pageLayers.get(pages[ahead].key);
          if (candidate !== undefined && candidate - previous >= gap * 2) {
            next = candidate;
            break;
          }
        }
        layer = next === undefined ? previous + stride : Math.floor((previous + next) / 2);
        this.pageLayers.set(key, layer);
      }
      previous = layer;
    }
    // Keep explicit CSS z-index below its signed 32-bit range even after
    // thousands of successive routes in one recording.
    if (previous > 2_000_000_000 - gap) {
      const compactStride = Math.max(gap, Math.min(stride, Math.floor(2_000_000_000 / (pages.length + 1))));
      for (let index = 0; index < pages.length; index++) this.pageLayers.set(pages[index].key, (index + 1) * compactStride);
    }
  }

  private round(value: number): number {
    return Math.round(value * 100) / 100;
  }
}
