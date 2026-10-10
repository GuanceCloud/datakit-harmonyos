import { copyReplayWireframe } from './ReplayWireframeValues';
import { FrameNode, UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy } from './FTSessionReplayConfig';
import {
  ArkUIReplayLightNode, ArkUIReplayLightSnapshot, ArkUIReplayPageTransition,
  ArkUIReplaySceneBounds, ArkUIReplaySceneFrame, ArkUIReplayScenePage, SessionReplayScene
} from './SessionReplayScene';
import {
  FullSnapshotData,
  ReplayGradient,
  ReplayImageWireframe,
  ReplayImageStyle,
  ReplayRecordType,
  ReplayShapeBorder,
  ReplayShapeStyle,
  ReplayShadow,
  ReplayTextPosition,
  ReplayShapeWireframe,
  ReplayTextStyle,
  ReplayTextWireframe,
  ReplayTransform,
  ReplayWireframe,
  ReplayWireframeClip,
  SessionReplayRecord
} from './SessionReplayProtocol';
export {
  ArkUIReplayLightNode, ArkUIReplayLightSnapshot, ArkUIReplayPageTransition,
  ArkUIReplaySceneBounds, ArkUIReplayScenePage
} from './SessionReplayScene';

const MAX_INSPECTOR_BYTES = 64 * 1024;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
const LARGE_IMAGE_PIXEL_COUNT = 100_000;
const DEFAULT_FONT_FAMILY = 'sans-serif';
const DEFAULT_TEXT_COLOR = '#1F2937FF';
const DEFAULT_PAGE_COLOR = '#FFFFFFFF';
const DEFAULT_BUTTON_COLOR = '#0A59F7FF';
const DEFAULT_IMAGE_COLOR = '#E2E8F0FF';
const DEFAULT_INPUT_BORDER_COLOR = '#CBD5E1FF';
const MAX_TEXT_DESCENDANT_SEARCH_DEPTH = 32;

interface RegisteredImageAsset {
  bytes: Uint8Array;
  mimeType: string;
}

interface CachedReplayProperties {
  inspector: string | null;
  signature: string;
  frame: ReplayWireframe;
}

interface ReplayInsets {
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

/**
 * Window-space clipping rectangle used while collecting a snapshot. It is
 * serialized as Android clipping insets, separately from each node's original
 * position and measured size.
 */
interface ReplayClipRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/**
 * One binary image discovered during a Full Snapshot. A recorder must persist
 * it before serializing its matching image wireframe, then replace `token`
 * with the content-addressed backend resource id.
 */
export interface CapturedReplayImageResource {
  token: string;
  bytes: Uint8Array;
  mimeType: string;
}

/**
 * Captures a privacy-filtered, visual ArkUI snapshot from a registered root.
 *
 * FrameNode deliberately exposes layout rather than pixels. This collector
 * maps the stable public fields into Android mobile `shape`, `text` and
 * `image` wireframes. The inspector is consulted only for a small, whitelisted
 * set of visual attributes; inspector JSON itself is never persisted or sent.
 */
export class ArkUIReplayCollector {
  private readonly maxNodes: number;
  private readonly config: FTSessionReplayConfig;
  private readonly registeredImageAssets: Map<string, RegisteredImageAsset> = new Map();
  private readonly parsedInspectorCache: Map<string, Record<string, Object>> = new Map();
  private readonly propertyCache: Map<number, CachedReplayProperties> = new Map();
  private propertyCacheChars: number = 0;
  private inspectorCacheChars: number = 0;
  private readonly decodedImages: Map<string, RegisteredImageAsset> = new Map();
  private decodedBytes: number = 0;
  private pendingImageResources: Array<CapturedReplayImageResource> = [];
  private rootEpoch: number = 1;
  private readonly scene: SessionReplayScene = new SessionReplayScene();

  constructor(maxNodes: number = 1500, config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
    this.maxNodes = Math.max(1, Math.floor(maxNodes));
    this.config = config;
  }

  /** Starts a new lifetime for a root that was reconstructed by ArkUI. */
  public renewRootEpoch(): void {
    this.rootEpoch++;
    this.propertyCache.clear();
    this.propertyCacheChars = 0;
    this.scene.clear();
  }

  public clearScene(): void {
    this.scene.clear();
  }

  /**
   * Registers bytes by an Image `.id()` value or a public Image source string.
   * ArkUI does not expose arbitrary Image pixels through FrameNode, so callers
   * that use bundle, file or network images provide decoded/original bytes
   * through this explicit boundary.
   */
  public registerImageAsset(componentId: string, data: ArrayBuffer | Uint8Array, mimeType: string = 'image/png'): boolean {
    const key = componentId.trim();
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (key.length === 0 || bytes.byteLength === 0 || bytes.byteLength > MAX_IMAGE_BYTES) {
      return false;
    }
    const normalizedMimeType = this.normalizeImageMimeType(mimeType);
    if (normalizedMimeType === null) {
      return false;
    }
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    this.propertyCache.clear();
    this.propertyCacheChars = 0;
    this.registeredImageAssets.set(key, { bytes: copy, mimeType: normalizedMimeType });
    return true;
  }

  public unregisterImageAsset(componentId: string): void {
    this.registeredImageAssets.delete(componentId.trim());
    this.propertyCache.clear();
    this.propertyCacheChars = 0;
  }

  /** Returns and clears resources produced by the immediately preceding capture. */
  public takeCapturedImageResources(copyBytes: boolean = true): Array<CapturedReplayImageResource> {
    const result: Array<CapturedReplayImageResource> = [];
    for (let index = 0; index < this.pendingImageResources.length; index++) {
      const resource = this.pendingImageResources[index];
      const bytes = copyBytes ? new Uint8Array(resource.bytes.byteLength) : resource.bytes;
      if (copyBytes) bytes.set(resource.bytes);
      result.push({ token: resource.token, bytes, mimeType: resource.mimeType });
    }
    this.pendingImageResources = [];
    return result;
  }

  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    return this.materializeLightSnapshot(this.captureLightSnapshot(uiContext, rootId, vpToPxScale, timestamp));
  }

  /**
   * UI-thread phase: reads only public FrameNode geometry/state and returns a
   * cheap handoff object.  Do not add JSON, resource, or filesystem work here.
   */
  public captureLightSnapshot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): ArkUIReplayLightSnapshot {
    const root = uiContext.getFrameNodeById(rootId);
    if (root === null) {
      throw new Error(`Session Replay root was not found: ${rootId}`);
    }
    return this.captureFrameNodeLight(root, vpToPxScale, timestamp);
  }

  /** Resolves reachable ArkUI containers; internal Page/Stage parents remain private. */
  public findSceneRoot(uiContext: UIContext, rootId: string): FrameNode | null {
    const pageRoot = uiContext.getFrameNodeById(rootId);
    if (pageRoot === null) return null;
    let root: FrameNode = pageRoot;
    for (let depth = 0; depth < 64; depth++) {
      try {
        const parent: FrameNode | null = root.getParent();
        if (parent === null || !parent.isAttached()) break;
        const size = parent.getMeasuredSize();
        if (size.width <= 0 || size.height <= 0) break;
        root = parent;
        if (parent.getNodeType().toLowerCase() === 'stage') break;
      } catch (_) { break; }
    }
    return root;
  }

  public captureFrameNode(
    root: FrameNode,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): SessionReplayRecord {
    return this.materializeLightSnapshot(this.captureFrameNodeLight(root, vpToPxScale, timestamp));
  }

  /** Page/Stage parents are private; compose roots supplied by page lifecycle hooks. */
  public captureSceneLight(
    uiContext: UIContext,
    rootIds: Array<string>,
    vpToPxScale: number = 1,
    timestamp: number = Date.now(),
    transitions: Map<string, ArkUIReplayPageTransition> = new Map(),
    viewportBounds: ArkUIReplaySceneBounds | null = null,
    scenePages: Array<ArkUIReplayScenePage> = []
  ): ArkUIReplayLightSnapshot {
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    const pages = scenePages.length > 0 ? scenePages : rootIds.map((rootId: string): ArkUIReplayScenePage => {
      return { key: rootId, rootId, root: uiContext.getFrameNodeById(rootId), retained: false };
    });
    const excludedIds = new Set<number>();
    for (const page of pages) {
      if (page.parentKey !== undefined && page.root !== null) excludedIds.add(page.root.getUniqueId());
    }
    const frames: Array<ArkUIReplaySceneFrame> = [];
    for (const page of pages) {
      const root = page.root;
      if (root === null) continue;
      try {
        this.assertRenderableRoot(root);
        try { if (!root.isVisible()) continue; } catch (_) { }
        const size = root.getMeasuredSize();
        const layout = root.getPositionToWindow();
        let measured = layout;
        try { measured = root.getPositionToWindowWithTransform(); } catch (_) { }
        const nativeX = measured.x - layout.x;
        const nativeY = measured.y - layout.y;
        if (!Number.isFinite(nativeX) || !Number.isFinite(nativeY) ||
          !Number.isFinite(layout.x) || !Number.isFinite(layout.y)) continue;
        const pageNodes: Array<ArkUIReplayLightNode> = [];
        this.appendLightPreOrder(root, scale, pageNodes, true, undefined,
          page.parentKey === undefined ? 1 : this.readAncestorOpacity(root), 0, 0, excludedIds,
          this.maxNodes - (page.parentKey === undefined ? 2 : 1));
        if (page.parentKey === undefined) {
          // A transparent application Column still sits on an opaque native
          // Router Page. Record that backing separately, below its contents.
          if (pageNodes.length > 0) pageNodes[0].isRoot = false;
          pageNodes.unshift({
            id: -this.toProtocolId(root.getUniqueId()), x: measured.x, y: measured.y,
            width: size.width / scale, height: size.height / scale,
            componentId: 'ft-session-replay-page-surface', nodeType: 'Column', inspectorInfo: null,
            shouldCaptureAsText: false, isRoot: true, usedTransformedPosition: true,
            opacity: 1, clip: { top: 0, right: 0, bottom: 0, left: 0 }, isPageSurface: true
          });
        }
        if (pageNodes.length === 0) continue;
        // Remove only the page's movement; retain each child's own scroll or
        // translation and its ancestor-local clip for later scene composition.
        for (const node of pageNodes) {
          node.x = this.roundReplayMetric(node.x - nativeX);
          node.y = this.roundReplayMetric(node.y - nativeY);
        }
        frames.push({ key: page.key, bounds: { x: layout.x, y: layout.y,
          width: size.width / scale, height: size.height / scale }, nativeX, nativeY, nodes: pageNodes });
      } catch (_) {
        // A retained page can already be detached. Its bounded detached frame
        // stays usable until the transition owner releases that page.
      }
    }
    const fallback = frames.find((frame: ArkUIReplaySceneFrame): boolean =>
      pages.some((page: ArkUIReplayScenePage): boolean => page.key === frame.key && page.parentKey === undefined));
    const viewport = viewportBounds ?? fallback?.bounds;
    if (viewport === undefined || viewport.width <= 0 || viewport.height <= 0) {
      throw new Error('Session Replay scene has no valid viewport.');
    }
    const nodes: Array<ArkUIReplayLightNode> = [{
      id: this.toProtocolId(0), x: 0, y: 0,
      width: viewport.width, height: viewport.height,
      componentId: 'ft-session-replay-scene', nodeType: 'Column', inspectorInfo: null,
      shouldCaptureAsText: false, isRoot: true, usedTransformedPosition: false, opacity: 1,
      clip: { top: 0, right: 0, bottom: 0, left: 0 }
    }];
    const composed = this.scene.compose(pages, frames, viewport, transitions, this.maxNodes - 1, timestamp);
    for (const node of composed) nodes.push(node);
    return { timestamp, vpToPxScale: scale, nodes };
  }

  private cachedWireframe(node: ArkUIReplayLightNode, inspector: string | null, scale: number): ReplayWireframe {
    const signature = `${node.componentId}|${node.nodeType}|${node.width}|${node.height}|${scale}|${node.isRoot}|` +
      `${node.shouldCaptureAsText}|${this.config.getTextAndInputPrivacy()}|${this.config.getImagePrivacy()}`;
    const cached = this.propertyCache.get(node.id);
    if (cached !== undefined && cached.inspector === inspector && cached.signature === signature) {
      const frame = copyReplayWireframe(cached.frame);
      frame.x = node.x;
      frame.y = node.y;
      if (frame.type === 'image' && frame.resourceId !== undefined) {
        const resource = this.resolveImageResource(node.componentId, node.id, inspector);
        if (resource !== null) frame.resourceId = resource.token;
      }
      return frame;
    }
    const frame = this.createWireframe(node.id, node.x, node.y, node.width, node.height,
      node.componentId, node.nodeType, inspector, node.shouldCaptureAsText, node.isRoot, scale);
    this.appendCommonVisualProperties(frame, inspector);
    this.propertyCacheChars -= cached?.inspector?.length ?? 0;
    this.propertyCacheChars += inspector?.length ?? 0;
    this.propertyCache.set(node.id, { inspector, signature, frame: copyReplayWireframe(frame) });
    while (this.propertyCacheChars > 2 * 1024 * 1024 || this.propertyCache.size > this.maxNodes) {
      const oldest = this.propertyCache.keys().next().value as number;
      this.propertyCacheChars -= this.propertyCache.get(oldest)?.inspector?.length ?? 0;
      this.propertyCache.delete(oldest);
    }
    return frame;
  }

  private readAncestorOpacity(root: FrameNode): number {
    let opacity = 1;
    let parent: FrameNode | null = null;
    try { parent = root.getParent(); } catch (_) { }
    for (let depth = 0; depth < 64 && parent !== null; depth++) {
      try {
        const value = parent.getOpacity();
        if (Number.isFinite(value)) opacity *= Math.max(0, Math.min(1, value));
        parent = parent.getParent();
      } catch (_) { break; }
    }
    return opacity;
  }

  /** Same UI-only phase for callers that already hold the root FrameNode. */
  public captureFrameNodeLight(
    root: FrameNode,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): ArkUIReplayLightSnapshot {
    this.assertRenderableRoot(root);
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    const nodes: Array<ArkUIReplayLightNode> = [];
    this.appendLightPreOrder(root, scale, nodes, true);
    return { timestamp, vpToPxScale: scale, nodes };
  }

  /**
   * Worker/queue phase: parses Inspector data, applies privacy policies,
   * creates wireframes and resolves image bytes.  This method intentionally
   * accepts no FrameNode so callers cannot accidentally traverse ArkUI here.
   */
  public materializeLightSnapshot(snapshot: ArkUIReplayLightSnapshot): SessionReplayRecord {
    const wireframes: Array<ReplayWireframe> = [];
    const pageZIndices: Map<number, Array<number>> = new Map();
    this.pendingImageResources = [];
    const retained = new Set<number>();
    for (let index = 0; index < snapshot.nodes.length; index++) {
      const node = snapshot.nodes[index];
      const inspector = this.serializeInspectorInfo(node.inspectorInfo);
      retained.add(node.id);
      const wireframe = this.cachedWireframe(node, inspector, snapshot.vpToPxScale);

      this.removeBakedPositionTranslation(wireframe, node.usedTransformedPosition);
      // Use a canonical zero clip for unclipped nodes so applying a clearing
      // Mutation produces exactly the same properties as the latest Full.
      wireframe.clip = {
        top: node.clip?.top ?? 0,
        right: node.clip?.right ?? 0,
        bottom: node.clip?.bottom ?? 0,
        left: node.clip?.left ?? 0
      };
      if (wireframe.type !== 'placeholder' && node.opacity !== undefined) {
        const style = wireframe.shapeStyle ?? {};
        style.opacity = node.opacity;
        wireframe.shapeStyle = style;
      }
      wireframes.push(wireframe);
      if (node.sceneLayer !== undefined && !node.isPageSurface) {
        let indices = pageZIndices.get(node.sceneLayer);
        if (indices === undefined) {
          indices = [];
          pageZIndices.set(node.sceneLayer, indices);
        }
        const zIndex = wireframe.zIndex ?? 0;
        if (!indices.includes(zIndex)) indices.push(zIndex);
      }
    }
    this.propertyCache.forEach((cached: CachedReplayProperties, id: number): void => {
      if (!retained.has(id)) {
        this.propertyCache.delete(id);
        this.propertyCacheChars -= cached.inspector?.length ?? 0;
      }
    });
    pageZIndices.forEach((indices: Array<number>): void => { indices.sort((left: number, right: number): number => left - right); });
    for (let index = 0; index < wireframes.length; index++) {
      const node = snapshot.nodes[index];
      if (node.sceneLayer === undefined) continue;
      const wireframe = wireframes[index];
      // Native zIndex is local to its page. Compact its relative order into
      // that page's reserved band instead of allowing it to cross pages.
      const rank = node.isPageSurface ? 0 : (pageZIndices.get(node.sceneLayer)?.indexOf(wireframe.zIndex ?? 0) ?? 0) + 1;
      wireframe.zIndex = node.sceneLayer + rank;
    }
    const data: FullSnapshotData = { wireframes };
    return {
      timestamp: snapshot.timestamp,
      type: ReplayRecordType.FULL_SNAPSHOT,
      data
    };
  }

  /**
   * A View-start callback can occur before ArkUI completes the first layout.
   * A zero-sized Full Snapshot is syntactically valid but makes the player
   * initialize a zero-sized canvas, so it must never be persisted or sent.
   */
  private assertRenderableRoot(root: FrameNode): void {
    if (!root.isAttached()) {
      throw new Error('Session Replay root is not attached.');
    }
    let width = 0;
    let height = 0;
    try {
      const size = root.getMeasuredSize();
      width = size.width;
      height = size.height;
    } catch (_) {
      throw new Error('Session Replay root size is unavailable.');
    }
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      throw new Error('Session Replay root has not completed layout.');
    }
  }

  private appendLightPreOrder(
    node: FrameNode,
    vpToPxScale: number,
    output: Array<ArkUIReplayLightNode>,
    isRoot: boolean,
    ancestorClip: ReplayClipRect | null | undefined = undefined,
    ancestorOpacity: number = 1,
    sceneOffsetX: number = 0,
    sceneOffsetY: number = 0,
    excludedIds: Set<number> = new Set(),
    nodeBudget: number = this.maxNodes
  ): void {
    if (output.length >= nodeBudget) {
      return;
    }

    const nodeId = node.getUniqueId();
    if (!isRoot && excludedIds.has(nodeId)) return;
    if (nodeId <= 0 || !node.isAttached()) {
      return;
    }
    let opacity = ancestorOpacity;
    try {
      if (!node.isVisible()) return;
      const ownOpacity = node.getOpacity();
      if (Number.isFinite(ownOpacity)) opacity *= Math.max(0, Math.min(1, ownOpacity));
    } catch (_) { }

    let x = 0;
    let y = 0;
    let width = 0;
    let height = 0;
    let usedTransformedPosition = false;
    try {
      // Scroll offsets and drawing translations are applied after layout. Use
      // the transformed window position so a scrolled child is captured where
      // it is actually painted, not where it was originally laid out.
      const position = node.getPositionToWindowWithTransform();
      x = this.roundReplayMetric(position.x);
      y = this.roundReplayMetric(position.y);
      usedTransformedPosition = true;
    } catch (_) {
      try {
        // Keep compatibility with an older ArkUI runtime that does not expose
        // the transformed query. The clip pass below still prevents overflow.
        const position = node.getPositionToWindow();
        x = this.roundReplayMetric(position.x);
        y = this.roundReplayMetric(position.y);
      } catch (_) { }
    }
    try {
      const size = node.getMeasuredSize();
      width = Math.max(0, this.roundReplayMetric(size.width / vpToPxScale));
      height = Math.max(0, this.roundReplayMetric(size.height / vpToPxScale));
    } catch (_) { }

    x = this.roundReplayMetric(x + sceneOffsetX);
    y = this.roundReplayMetric(y + sceneOffsetY);

    const bounds = this.createClipRect(x, y, width, height);
    const clipsDescendants = isRoot || this.isClipToFrame(node);
    const childClip = clipsDescendants
      ? this.intersectClipRects(ancestorClip, bounds)
      : ancestorClip;

    // Keep attached nodes and their original geometry while they move through
    // a clipping boundary. Fully clipped nodes remain present with an empty
    // clip instead of being removed and added again when they slide back in.
    if (width > 0 && height > 0) {
      const nodeType = this.readNodeType(node);
      output.push({
        id: this.toProtocolId(nodeId),
        x,
        y,
        width,
        height,
        componentId: this.readComponentId(node),
        nodeType,
        inspectorInfo: this.readInspectorInfo(node),
        shouldCaptureAsText: this.shouldCaptureAsText(node, nodeType),
        isRoot,
        usedTransformedPosition,
        opacity,
        clip: this.resolveWireframeClip(ancestorClip, bounds)
      });
    }

    let child: FrameNode | null = null;
    try {
      child = node.getFirstChild();
    } catch (_) {
      return;
    }
    while (child !== null && output.length < nodeBudget) {
      this.appendLightPreOrder(child, vpToPxScale, output, false, childClip, opacity, sceneOffsetX, sceneOffsetY, excludedIds, nodeBudget);
      try {
        child = child.getNextSibling();
      } catch (_) {
        return;
      }
    }
  }

  private createClipRect(x: number, y: number, width: number, height: number): ReplayClipRect {
    return {
      left: x,
      top: y,
      right: x + Math.max(0, width),
      bottom: y + Math.max(0, height)
    };
  }

  private resolveWireframeClip(
    ancestor: ReplayClipRect | null | undefined,
    bounds: ReplayClipRect
  ): ReplayWireframeClip {
    if (ancestor === undefined) {
      return { top: 0, right: 0, bottom: 0, left: 0 };
    }
    const width = this.roundReplayMetric(bounds.right - bounds.left);
    const height = this.roundReplayMetric(bounds.bottom - bounds.top);
    if (ancestor === null) {
      // A clipping ancestor has no visible region. Keep descendants hidden
      // even when their own transforms would bring them inside the window.
      return { top: 0, right: width, bottom: 0, left: 0 };
    }
    return {
      top: this.roundReplayMetric(Math.max(0, Math.min(height, ancestor.top - bounds.top))),
      right: this.roundReplayMetric(Math.max(0, Math.min(width, bounds.right - ancestor.right))),
      bottom: this.roundReplayMetric(Math.max(0, Math.min(height, bounds.bottom - ancestor.bottom))),
      left: this.roundReplayMetric(Math.max(0, Math.min(width, ancestor.left - bounds.left)))
    };
  }

  /**
   * `undefined` means no clipping ancestor yet; `null` represents an empty
   * visible region. Keeping those states distinct avoids accidentally reviving
   * descendants that have already been clipped by a parent Scroll/List.
   */
  private intersectClipRects(
    ancestor: ReplayClipRect | null | undefined,
    current: ReplayClipRect
  ): ReplayClipRect | null {
    if (ancestor === null || current.right <= current.left || current.bottom <= current.top) {
      return null;
    }
    if (ancestor === undefined) {
      return current;
    }
    const left = Math.max(ancestor.left, current.left);
    const top = Math.max(ancestor.top, current.top);
    const right = Math.min(ancestor.right, current.right);
    const bottom = Math.min(ancestor.bottom, current.bottom);
    if (right <= left || bottom <= top) {
      return null;
    }
    return { left, top, right, bottom };
  }

  private isClipToFrame(node: FrameNode): boolean {
    try {
      return node.isClipToFrame();
    } catch (_) {
      return false;
    }
  }

  /**
   * The transformed window query already includes native translation (notably
   * a Scroll's content offset). Preserve scale/rotation metadata, but remove
   * translateX/Y so the Replay player does not apply the same movement twice.
   */
  private removeBakedPositionTranslation(wireframe: ReplayWireframe, usedTransformedPosition: boolean): void {
    if (!usedTransformedPosition || wireframe.type === 'placeholder' || wireframe.shapeStyle === undefined ||
      wireframe.shapeStyle.transform === undefined) {
      return;
    }
    const transform = wireframe.shapeStyle.transform;
    transform.translateX = undefined;
    transform.translateY = undefined;
    if (transform.scaleX === undefined && transform.scaleY === undefined && transform.rotate === undefined) {
      wireframe.shapeStyle.transform = undefined;
    }
  }

  private createWireframe(
    id: number,
    x: number,
    y: number,
    width: number,
    height: number,
    componentId: string,
    nodeType: string,
    inspector: string | null,
    shouldCaptureAsText: boolean,
    isRoot: boolean,
    vpToPxScale: number
  ): ReplayWireframe {
    if (shouldCaptureAsText) {
      return this.createTextWireframe(id, x, y, width, height, componentId, nodeType, inspector, vpToPxScale);
    }
    if (this.isImageNode(nodeType)) {
      return this.createImageWireframe(id, x, y, width, height, componentId, nodeType, inspector, vpToPxScale);
    }
    return this.createShapeWireframe(id, x, y, width, height, componentId, nodeType, inspector, isRoot, vpToPxScale);
  }

  private createShapeWireframe(
    id: number,
    x: number,
    y: number,
    width: number,
    height: number,
    componentId: string,
    nodeType: string,
    inspector: string | null,
    isRoot: boolean,
    vpToPxScale: number
  ): ReplayShapeWireframe {
    const shape: ReplayShapeWireframe = {
      id, x, y, width, height,
      type: 'shape',
      shapeStyle: this.createShapeStyle(nodeType, inspector, isRoot, width, height, vpToPxScale)
    };
    const border = this.createBorder(nodeType, inspector, vpToPxScale);
    if (border !== null) {
      shape.border = border;
    }
    if (componentId.length > 0) {
      shape.permanentId = componentId;
    }
    return shape;
  }

  private createTextWireframe(
    id: number,
    x: number,
    y: number,
    width: number,
    height: number,
    componentId: string,
    nodeType: string,
    inspector: string | null,
    vpToPxScale: number
  ): ReplayTextWireframe {
    const rawText = this.readInspectorString(inspector, ['text', 'content', 'value', 'placeholder', 'label']);
    const text: ReplayTextWireframe = {
      id, x, y, width, height,
      type: 'text',
      text: this.filterText(rawText, nodeType, width, inspector),
      textStyle: this.createTextStyle(inspector, vpToPxScale)
    };
    const shapeStyle = this.createShapeStyle(nodeType, inspector, false, width, height, vpToPxScale);
    if (shapeStyle !== undefined) {
      text.shapeStyle = shapeStyle;
    }
    const border = this.createBorder(nodeType, inspector, vpToPxScale);
    if (border !== null) {
      text.border = border;
    }
    const textPosition = this.createTextPosition(inspector, vpToPxScale);
    if (textPosition !== undefined) {
      text.textPosition = textPosition;
    }
    if (componentId.length > 0) {
      text.permanentId = componentId;
    }
    return text;
  }

  private createImageWireframe(
    id: number,
    x: number,
    y: number,
    width: number,
    height: number,
    componentId: string,
    nodeType: string,
    inspector: string | null,
    vpToPxScale: number
  ): ReplayImageWireframe {
    const image: ReplayImageWireframe = {
      id, x, y, width, height,
      type: 'image',
      shapeStyle: this.createShapeStyle(nodeType, inspector, false, width, height, vpToPxScale),
      isEmpty: true
    };
    const border = this.createBorder(nodeType, inspector, vpToPxScale);
    if (border !== null) {
      image.border = border;
    }
    if (componentId.length > 0) {
      image.permanentId = componentId;
    }
    const imageStyle = this.createImageStyle(inspector);
    if (imageStyle !== undefined) {
      image.imageStyle = imageStyle;
    }
    if (!this.canCaptureImage(width, height, vpToPxScale)) {
      return image;
    }
    const resource = this.resolveImageResource(componentId, id, inspector);
    if (resource === null) {
      return image;
    }
    image.resourceId = resource.token;
    image.mimeType = resource.mimeType;
    image.isEmpty = false;
    return image;
  }

  private resolveImageResource(
    componentId: string,
    wireframeId: number,
    inspector: string | null
  ): CapturedReplayImageResource | null {
    const imageSource = this.readInspectorString(inspector, ['src', 'source', 'imageSrc', 'resource']);
    const registeredByComponent = componentId.length === 0 ? undefined : this.registeredImageAssets.get(componentId);
    // Bundle/file/network image pixels are intentionally not read from the
    // Inspector. An application may instead register the same bytes by its
    // public Image source string, which also covers images without `.id()`.
    const registeredBySource = imageSource === null ? undefined : this.registeredImageAssets.get(imageSource.trim());
    const registered = registeredByComponent === undefined ? registeredBySource : registeredByComponent;
    const autoDecoded = registered === undefined ? this.decodeDataUri(imageSource) : null;
    const asset = registered === undefined ? autoDecoded : registered;
    if (asset === null || asset === undefined || asset.bytes.byteLength === 0 || asset.bytes.byteLength > MAX_IMAGE_BYTES) {
      return null;
    }
    const token = `arkui-image-${this.rootEpoch}-${wireframeId}-${this.pendingImageResources.length}`;
    const bytes = asset.bytes;
    const resource: CapturedReplayImageResource = { token, bytes, mimeType: asset.mimeType };
    this.pendingImageResources.push(resource);
    return resource;
  }

  private decodeDataUri(value: string | null): RegisteredImageAsset | null {
    if (value === null || value.length > MAX_IMAGE_BYTES * 2) {
      return null;
    }
    const cached = this.decodedImages.get(value);
    if (cached !== undefined) return cached;
    const match = /^data:(image\/(?:png|jpeg|gif|webp|svg\+xml));base64,([A-Za-z0-9+/=\r\n]+)$/i.exec(value);
    if (match === null) {
      return null;
    }
    const mimeType = this.normalizeImageMimeType(match[1]);
    if (mimeType === null) {
      return null;
    }
    try {
      const bytes = new util.Base64Helper().decodeSync(match[2]);
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_IMAGE_BYTES) {
        return null;
      }
      const asset: RegisteredImageAsset = { bytes, mimeType };
      this.decodedImages.set(value, asset);
      this.decodedBytes += bytes.byteLength;
      while (this.decodedBytes > 8 * 1024 * 1024 || this.decodedImages.size > 16) {
        const key = this.decodedImages.keys().next().value as string;
        this.decodedBytes -= this.decodedImages.get(key)?.bytes.byteLength ?? 0;
        this.decodedImages.delete(key);
      }
      return asset;
    } catch (_) {
      return null;
    }
  }

  /** Privacy thresholds remain based on physical image area, not replay vp units. */
  private canCaptureImage(width: number, height: number, vpToPxScale: number): boolean {
    const privacy = this.config.getImagePrivacy();
    if (privacy === ImagePrivacy.MASK_ALL) {
      return false;
    }
    const physicalArea = width * vpToPxScale * height * vpToPxScale;
    if (privacy === ImagePrivacy.MASK_LARGE_ONLY && physicalArea >= LARGE_IMAGE_PIXEL_COUNT) {
      return false;
    }
    return true;
  }

  private createShapeStyle(
    nodeType: string,
    inspector: string | null,
    isRoot: boolean,
    width: number,
    height: number,
    vpToPxScale: number
  ): ReplayShapeStyle | undefined {
    const directBackground = this.readInspectorString(inspector, ['backgroundColor', 'background']);
    const nestedBackground = directBackground === null ?
      this.readInspectorNestedString(inspector, ['background'], ['color']) : null;
    const backgroundColor = this.normalizeColor(directBackground === null ? nestedBackground : directBackground);
    const reportedCornerRadius = this.readCornerRadius(inspector, vpToPxScale);
    const cornerRadius = this.resolveCornerRadius(nodeType, inspector, width, height, reportedCornerRadius);
    const opacity = this.readInspectorNumber(inspector, ['opacity']);
    const gradient = this.createGradient(inspector);
    const shadow = this.createShadow(inspector, vpToPxScale);
    const transform = this.createTransform(inspector, vpToPxScale);
    const visible = this.readVisibility(inspector);
    const fallbackColor = backgroundColor === null ? this.defaultBackgroundColor(nodeType, isRoot) : backgroundColor;
    if (fallbackColor === null && cornerRadius === null && opacity === null && gradient === undefined && shadow === undefined &&
      transform === undefined && visible === null) {
      return undefined;
    }
    const style: ReplayShapeStyle = {};
    if (fallbackColor !== null) style.backgroundColor = fallbackColor;
    if (opacity !== null) style.opacity = this.clamp(opacity, 0, 1);
    if (cornerRadius !== null) style.cornerRadius = Math.max(0, this.roundReplayMetric(cornerRadius));
    if (gradient !== undefined) style.backgroundGradient = gradient;
    if (shadow !== undefined) style.shadow = shadow;
    if (transform !== undefined) style.transform = transform;
    if (visible !== null) style.visible = visible;
    return style;
  }

  private createBorder(nodeType: string, inspector: string | null, vpToPxScale: number): ReplayShapeBorder | null {
    const directColor = this.readInspectorString(inspector, ['borderColor', 'outlineColor']);
    const nestedColor = directColor === null ?
      this.readInspectorNestedString(inspector, ['border', 'outline'], ['color']) : null;
    const color = this.normalizeColor(directColor === null ? nestedColor : directColor);
    const configuredWidth = this.readInspectorLength(inspector, ['borderWidth', 'outlineWidth'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['border', 'outline'], ['width'], vpToPxScale);
    if (color !== null && configuredWidth !== null && configuredWidth > 0) {
      return { color, width: Math.max(0.5, this.roundReplayMetric(configuredWidth)) };
    }
    if (this.isInputNode(nodeType)) {
      return { color: DEFAULT_INPUT_BORDER_COLOR, width: 1 };
    }
    return null;
  }

  private createTextStyle(inspector: string | null, vpToPxScale: number): ReplayTextStyle {
    const size = this.readInspectorLength(inspector, ['fontSize', 'textSize'], vpToPxScale);
    const color = this.normalizeColor(this.readInspectorString(inspector, ['fontColor', 'textColor', 'color']));
    const family = this.readInspectorString(inspector, ['fontFamily', 'font']) ?? DEFAULT_FONT_FAMILY;
    // If Inspector did not expose typography, a stable 14vp fallback is less
    // misleading than deriving a huge font from the node's container height.
    const style: ReplayTextStyle = {
      family: this.safeFontFamily(family),
      size: Math.max(8, Math.min(72, Math.round(size === null ? 14 : size))),
      color: color === null ? DEFAULT_TEXT_COLOR : color
    };
    const weight = this.normalizeFontWeight(this.readInspectorString(inspector, ['fontWeight', 'weight']));
    const fontStyle = this.normalizeFontStyle(this.readInspectorString(inspector, ['fontStyle', 'style']));
    const lineHeight = this.readInspectorLength(inspector, ['lineHeight'], vpToPxScale);
    const letterSpacing = this.readInspectorLength(inspector, ['letterSpacing', 'letterSpace'], vpToPxScale);
    const decoration = this.normalizeTextDecoration(this.readInspectorString(
      inspector, ['textDecoration', 'decoration']
    ));
    if (weight !== null) style.weight = weight;
    if (fontStyle !== null) style.style = fontStyle;
    if (lineHeight !== null && lineHeight > 0) style.lineHeight = Math.round(lineHeight);
    if (letterSpacing !== null) style.letterSpacing = Math.round(letterSpacing * 100) / 100;
    if (decoration !== null) style.decoration = decoration;
    return style;
  }

  /**
   * `textPosition` is already understood by Studio's Android wireframe
   * renderer. Supplying the native insets and alignment fixes the common
   * top-left/default-layout fallback without extending the wire protocol.
   */
  private createTextPosition(inspector: string | null, vpToPxScale: number): ReplayTextPosition | undefined {
    const shorthand = this.readInspectorInsets(inspector, ['padding'], vpToPxScale);
    let top = this.readInspectorLength(inspector, ['paddingTop', 'topPadding'], vpToPxScale);
    let right = this.readInspectorLength(inspector, ['paddingRight', 'rightPadding'], vpToPxScale);
    let bottom = this.readInspectorLength(inspector, ['paddingBottom', 'bottomPadding'], vpToPxScale);
    let left = this.readInspectorLength(inspector, ['paddingLeft', 'leftPadding'], vpToPxScale);
    if (top === null && shorthand !== undefined && shorthand.top !== undefined) top = shorthand.top;
    if (right === null && shorthand !== undefined && shorthand.right !== undefined) right = shorthand.right;
    if (bottom === null && shorthand !== undefined && shorthand.bottom !== undefined) bottom = shorthand.bottom;
    if (left === null && shorthand !== undefined && shorthand.left !== undefined) left = shorthand.left;
    const horizontal = this.normalizeHorizontalAlignment(
      this.readInspectorString(inspector, ['textAlign', 'horizontalAlign', 'alignment'])
    );
    const vertical = this.normalizeVerticalAlignment(
      this.readInspectorString(inspector, ['verticalAlign', 'verticalAlignment', 'alignment'])
    );
    if (top === null && right === null && bottom === null && left === null && horizontal === null && vertical === null) {
      return undefined;
    }

    const result: ReplayTextPosition = {};
    if (top !== null || right !== null || bottom !== null || left !== null) {
      result.padding = {};
      if (top !== null) result.padding.top = Math.max(0, this.roundReplayMetric(top));
      if (right !== null) result.padding.right = Math.max(0, this.roundReplayMetric(right));
      if (bottom !== null) result.padding.bottom = Math.max(0, this.roundReplayMetric(bottom));
      if (left !== null) result.padding.left = Math.max(0, this.roundReplayMetric(left));
    }
    if (horizontal !== null || vertical !== null) {
      result.alignment = {};
      if (horizontal !== null) result.alignment.horizontal = horizontal;
      if (vertical !== null) result.alignment.vertical = vertical;
    }
    return result;
  }

  /**
   * Inspector exposes gradients as a structured value on current ArkUI builds.
   * Only a bounded, colour-stop based subset is retained so replay payloads do
   * not contain arbitrary Inspector JSON.
   */
  private createGradient(inspector: string | null): ReplayGradient | undefined {
    const gradient = this.readInspectorObject(inspector, ['backgroundGradient', 'linearGradient', 'gradient']);
    if (gradient === null) {
      return undefined;
    }
    const rawColors = this.findInspectorStringArray(gradient, ['colors', 'colorStops']);
    if (rawColors === null || rawColors.length < 2 || rawColors.length > 16) {
      return undefined;
    }
    const colors: Array<string> = [];
    for (let index = 0; index < rawColors.length; index++) {
      const color = this.normalizeColor(rawColors[index]);
      if (color === null) {
        return undefined;
      }
      colors.push(color);
    }
    const type = this.findInspectorScalar(gradient, ['type', 'kind']);
    const result: ReplayGradient = {
      kind: type !== null && type.toLowerCase().includes('radial') ? 'radial' : 'linear',
      colors
    };
    const rawStops = this.findInspectorStringArray(gradient, ['stops', 'locations', 'offsets']);
    if (rawStops !== null && rawStops.length === colors.length) {
      const stops: Array<number> = [];
      for (let index = 0; index < rawStops.length; index++) {
        const stop = Number(rawStops[index]);
        if (!Number.isFinite(stop)) {
          return result;
        }
        stops.push(this.clamp(stop, 0, 1));
      }
      result.stops = stops;
    }
    const angle = this.parseInspectorDegrees(this.findInspectorScalar(gradient, ['angle', 'direction']));
    if (angle !== null) {
      result.angle = angle;
    }
    return result;
  }

  /** Captures common one-layer shadows without recording arbitrary style blobs. */
  private createShadow(inspector: string | null, vpToPxScale: number): ReplayShadow | undefined {
    const color = this.normalizeColor(
      this.readInspectorString(inspector, ['shadowColor']) ??
        this.readInspectorNestedString(inspector, ['shadow', 'boxShadow'], ['color'])
    );
    if (color === null) {
      return undefined;
    }
    const offsetX = this.readInspectorLength(inspector, ['shadowOffsetX'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['shadow', 'boxShadow'], ['offsetX', 'x'], vpToPxScale) ?? 0;
    const offsetY = this.readInspectorLength(inspector, ['shadowOffsetY'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['shadow', 'boxShadow'], ['offsetY', 'y'], vpToPxScale) ?? 0;
    const blurRadius = this.readInspectorLength(inspector, ['shadowBlurRadius', 'shadowRadius'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['shadow', 'boxShadow'], ['blurRadius', 'radius', 'blur'], vpToPxScale) ?? 0;
    const spreadRadius = this.readInspectorLength(inspector, ['shadowSpreadRadius'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['shadow', 'boxShadow'], ['spreadRadius', 'spread'], vpToPxScale);
    const shadow: ReplayShadow = {
      color,
      offsetX: Math.round(offsetX),
      offsetY: Math.round(offsetY),
      blurRadius: Math.max(0, Math.round(blurRadius))
    };
    if (spreadRadius !== null) {
      shadow.spreadRadius = Math.round(spreadRadius);
    }
    return shadow;
  }

  private createTransform(inspector: string | null, vpToPxScale: number): ReplayTransform | undefined {
    const translateX = this.readInspectorLength(inspector, ['translateX'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['transform'], ['translateX', 'x'], vpToPxScale);
    const translateY = this.readInspectorLength(inspector, ['translateY'], vpToPxScale) ??
      this.readInspectorNestedLength(inspector, ['transform'], ['translateY', 'y'], vpToPxScale);
    const scaleX = this.readInspectorNumber(inspector, ['scaleX']) ??
      this.readInspectorNestedNumber(inspector, ['transform'], ['scaleX']);
    const scaleY = this.readInspectorNumber(inspector, ['scaleY']) ??
      this.readInspectorNestedNumber(inspector, ['transform'], ['scaleY']);
    const sharedScale = this.readInspectorNumber(inspector, ['scale']) ??
      this.readInspectorNestedNumber(inspector, ['transform'], ['scale']);
    const rotate = this.parseInspectorDegrees(this.readInspectorString(inspector, ['rotate', 'rotation']) ??
      this.readInspectorNestedString(inspector, ['transform'], ['rotate', 'rotation']));
    if (translateX === null && translateY === null && scaleX === null && scaleY === null && sharedScale === null && rotate === null) {
      return undefined;
    }
    const transform: ReplayTransform = {};
    if (translateX !== null) transform.translateX = Math.round(translateX);
    if (translateY !== null) transform.translateY = Math.round(translateY);
    if (scaleX !== null) transform.scaleX = scaleX;
    else if (sharedScale !== null) transform.scaleX = sharedScale;
    if (scaleY !== null) transform.scaleY = scaleY;
    else if (sharedScale !== null) transform.scaleY = sharedScale;
    if (rotate !== null) transform.rotate = rotate;
    return transform;
  }

  private createImageStyle(inspector: string | null): ReplayImageStyle | undefined {
    const objectFit = this.normalizeImageFit(this.readInspectorString(inspector, ['objectFit', 'imageFit', 'fit']));
    const tintColor = this.normalizeColor(this.readInspectorString(inspector, ['tintColor', 'colorFilter']));
    if (objectFit === null && tintColor === null) {
      return undefined;
    }
    const style: ReplayImageStyle = {};
    if (objectFit !== null) style.objectFit = objectFit;
    if (tintColor !== null) style.tintColor = tintColor;
    return style;
  }

  private appendCommonVisualProperties(wireframe: ReplayWireframe, inspector: string | null): void {
    const zIndex = this.readInspectorNumber(inspector, ['zIndex', 'zOrder']);
    if (zIndex !== null) {
      wireframe.zIndex = Math.round(zIndex);
    }
  }

  private readVisibility(inspector: string | null): boolean | null {
    const value = this.readInspectorString(inspector, ['visibility', 'visible']);
    if (value === null) return null;
    const normalized = value.trim().toLowerCase();
    if (normalized === 'true' || normalized.includes('visible')) return true;
    if (normalized === 'false' || normalized.includes('hidden') || normalized.includes('none') || normalized.includes('gone')) {
      return false;
    }
    return null;
  }

  private filterText(value: string | null, nodeType: string, width: number, inspector: string | null): string {
    const source = value === null ? '' : value;
    const input = this.isInputNode(nodeType);
    const privacy = this.config.getTextAndInputPrivacy();
    const masked = privacy === TextAndInputPrivacy.MASK_ALL ||
      (privacy === TextAndInputPrivacy.MASK_ALL_INPUTS && input) ||
      (privacy === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS && this.isSensitiveInput(nodeType, inspector));
    if (!masked) {
      return source;
    }
    const length = source.length > 0 ? source.length : Math.max(3, Math.min(24, Math.floor(width / 12)));
    return '•'.repeat(Math.min(64, length));
  }

  /** Reads the native Inspector object but deliberately does not serialize it on UI. */
  private readInspectorInfo(node: FrameNode): Object | null {
    try {
      const inspector = node.getInspectorInfo();
      return inspector === undefined || inspector === null ? null : inspector;
    } catch (_) {
      return null;
    }
  }

  /**
   * Runs in the processing queue.  The serialized value is used only as a
   * transient parser input; unknown Inspector fields never enter a wireframe.
   */
  private serializeInspectorInfo(inspectorInfo: Object | null): string | null {
    if (inspectorInfo === null) {
      return null;
    }
    try {
      const serialized = JSON.stringify(inspectorInfo);
      if (serialized.length === 0 || serialized.length > MAX_INSPECTOR_BYTES) {
        return null;
      }
      return serialized;
    } catch (_) {
      return null;
    }
  }

  /** Reads only explicitly allowed scalar fields from structured inspector JSON. */
  private readInspectorString(inspector: string | null, keys: Array<string>): string | null {
    const value = this.getInspectorValue(inspector);
    if (value === null) {
      return null;
    }
    return this.findInspectorScalar(value, keys);
  }

  /** Reads a whitelisted scalar nested under a named inspector style object. */
  private readInspectorNestedString(
    inspector: string | null,
    parentKeys: Array<string>,
    keys: Array<string>
  ): string | null {
    const value = this.getInspectorValue(inspector);
    if (value === null) {
      return null;
    }
    const parent = this.findInspectorObject(value, parentKeys);
    return parent === null ? null : this.findInspectorScalar(parent, keys);
  }

  /** Reads a named structured Inspector value without retaining its unknown fields. */
  private readInspectorObject(inspector: string | null, keys: Array<string>): Record<string, Object> | null {
    const value = this.getInspectorValue(inspector);
    return value === null ? null : this.findInspectorObject(value, keys);
  }

  private readInspectorNestedLength(
    inspector: string | null,
    parentKeys: Array<string>,
    keys: Array<string>,
    vpToPxScale: number
  ): number | null {
    const value = this.readInspectorNestedString(inspector, parentKeys, keys);
    return value === null ? null : this.parseInspectorLength(value, vpToPxScale);
  }

  private readInspectorNestedNumber(
    inspector: string | null,
    parentKeys: Array<string>,
    keys: Array<string>
  ): number | null {
    const value = this.readInspectorNestedString(inspector, parentKeys, keys);
    if (value === null) return null;
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : null;
  }

  private getInspectorValue(inspector: string | null): Record<string, Object> | null {
    if (inspector === null) {
      return null;
    }
    if (this.parsedInspectorCache.has(inspector)) {
      return this.parsedInspectorCache.get(inspector) ?? null;
    }
    try {
      const value: Record<string, Object> = JSON.parse(inspector) as Record<string, Object>;
      if (value === null || Array.isArray(value) || typeof value !== 'object') {
        return null;
      }
      this.parsedInspectorCache.set(inspector, value);
      this.inspectorCacheChars += inspector.length;
      while (this.inspectorCacheChars > 1024 * 1024 || this.parsedInspectorCache.size > this.maxNodes) {
        const key = this.parsedInspectorCache.keys().next().value as string;
        this.inspectorCacheChars -= key.length;
        this.parsedInspectorCache.delete(key);
      }
      return value;
    } catch (_error) {
      return null;
    }
  }

  /**
   * Look up a field by semantic name, first on the current object and only
   * then in its children. This avoids the old regex's accidental match inside
   * an unrelated serialized sub-object while still accepting Inspector layout
   * variations across API levels.
   */
  private findInspectorScalar(value: Record<string, Object>, keys: Array<string>): string | null {
    for (let keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      const expected = keys[keyIndex].toLowerCase();
      const properties = Object.keys(value);
      for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
        const property = properties[propertyIndex];
        const candidate: Object = value[property];
        if (property.toLowerCase() === expected) {
          const scalar = this.inspectorScalarToString(candidate);
          if (scalar !== null) return scalar;
        }
      }
    }
    const properties = Object.keys(value);
    for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
      const candidate: Object = value[properties[propertyIndex]];
      if (candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate)) {
        const nested = this.findInspectorScalar(candidate as Record<string, Object>, keys);
        if (nested !== null) return nested;
      } else if (Array.isArray(candidate)) {
        const values = candidate as Array<Object>;
        for (let index = 0; index < values.length; index++) {
          const arrayValue = values[index];
          if (arrayValue !== null && typeof arrayValue === 'object' && !Array.isArray(arrayValue)) {
            const nested = this.findInspectorScalar(arrayValue as Record<string, Object>, keys);
            if (nested !== null) return nested;
          }
        }
      }
    }
    return null;
  }

  private findInspectorObject(value: Record<string, Object>, keys: Array<string>): Record<string, Object> | null {
    for (let keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      const expected = keys[keyIndex].toLowerCase();
      const properties = Object.keys(value);
      for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
        const property = properties[propertyIndex];
        const candidate: Object = value[property];
        if (property.toLowerCase() === expected && candidate !== null &&
          typeof candidate === 'object' && !Array.isArray(candidate)) {
          return candidate as Record<string, Object>;
        }
      }
    }
    const properties = Object.keys(value);
    for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
      const candidate: Object = value[properties[propertyIndex]];
      if (candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate)) {
        const nested = this.findInspectorObject(candidate as Record<string, Object>, keys);
        if (nested !== null) return nested;
      } else if (Array.isArray(candidate)) {
        const values = candidate as Array<Object>;
        for (let index = 0; index < values.length; index++) {
          const arrayValue = values[index];
          if (arrayValue !== null && typeof arrayValue === 'object' && !Array.isArray(arrayValue)) {
            const nested = this.findInspectorObject(arrayValue as Record<string, Object>, keys);
            if (nested !== null) return nested;
          }
        }
      }
    }
    return null;
  }

  /** Reads a bounded scalar array from an allowed Inspector field. */
  private findInspectorStringArray(value: Record<string, Object>, keys: Array<string>): Array<string> | null {
    for (let keyIndex = 0; keyIndex < keys.length; keyIndex++) {
      const expected = keys[keyIndex].toLowerCase();
      const properties = Object.keys(value);
      for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
        const property = properties[propertyIndex];
        const candidate: Object = value[property];
        if (property.toLowerCase() === expected && Array.isArray(candidate)) {
          const result: Array<string> = [];
          const values = candidate as Array<Object>;
          for (let index = 0; index < values.length; index++) {
            const scalar = this.inspectorScalarToString(values[index]);
            if (scalar === null) return null;
            result.push(scalar);
          }
          return result;
        }
      }
    }
    const properties = Object.keys(value);
    for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
      const candidate: Object = value[properties[propertyIndex]];
      if (candidate !== null && typeof candidate === 'object' && !Array.isArray(candidate)) {
        const nested = this.findInspectorStringArray(candidate as Record<string, Object>, keys);
        if (nested !== null) return nested;
      } else if (Array.isArray(candidate)) {
        const values = candidate as Array<Object>;
        for (let index = 0; index < values.length; index++) {
          const arrayValue = values[index];
          if (arrayValue !== null && typeof arrayValue === 'object' && !Array.isArray(arrayValue)) {
            const nested = this.findInspectorStringArray(arrayValue as Record<string, Object>, keys);
            if (nested !== null) return nested;
          }
        }
      }
    }
    return null;
  }

  private inspectorScalarToString(value: Object): string | null {
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return null;
  }

  private readInspectorNumber(inspector: string | null, keys: Array<string>): number | null {
    const value = this.readInspectorString(inspector, keys);
    if (value !== null) {
      const parsed = Number(value.replace(/(?:px|vp|fp)$/i, '').trim());
      return Number.isFinite(parsed) ? parsed : null;
    }
    return null;
  }

  /**
   * Normalizes physical inspector lengths into the same vp unit as geometry.
   * ArkUI Inspector commonly exposes computed values in px; explicit vp/fp
   * values are already density-normalized and must not be divided again.
   */
  private readInspectorLength(
    inspector: string | null,
    keys: Array<string>,
    vpToPxScale: number
  ): number | null {
    const value = this.readInspectorString(inspector, keys);
    if (value === null) {
      return null;
    }
    return this.parseInspectorLength(value, vpToPxScale);
  }

  /**
   * ArkUI can expose a radius as one scalar or as four corner values. The
   * mobile replay schema has one radius, so use the largest available corner
   * when the source is asymmetric; that avoids flattening a visibly rounded
   * control while retaining the common uniform-radius case exactly.
   */
  private readCornerRadius(inspector: string | null, vpToPxScale: number): number | null {
    const scalar = this.readInspectorLength(inspector, ['borderRadius', 'cornerRadius', 'radius'], vpToPxScale);
    if (scalar !== null) {
      return scalar;
    }
    const radius = this.readInspectorObject(inspector, ['borderRadius', 'cornerRadius', 'radius']);
    if (radius === null) {
      return null;
    }
    const cornerKeys = [
      'topLeft', 'topRight', 'bottomRight', 'bottomLeft', 'topStart', 'topEnd', 'bottomStart', 'bottomEnd'
    ];
    let largest: number | null = null;
    for (let index = 0; index < cornerKeys.length; index++) {
      const value = this.findInspectorScalar(radius, [cornerKeys[index]]);
      if (value === null) {
        continue;
      }
      const length = this.parseInspectorLength(value, vpToPxScale);
      if (length !== null && (largest === null || length > largest)) {
        largest = length;
      }
    }
    return largest;
  }

  private parseInspectorLength(value: string, vpToPxScale: number): number | null {
    const match = /^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s*(px|vp|fp)?\s*$/i.exec(value);
    if (match === null) {
      return null;
    }
    const parsed = Number(match[1]);
    if (!Number.isFinite(parsed)) {
      return null;
    }
    const unit = match[2] === undefined ? '' : match[2].toLowerCase();
    return unit === 'vp' || unit === 'fp' ? parsed : parsed / vpToPxScale;
  }

  private parseInspectorDegrees(value: string | null): number | null {
    if (value === null) return null;
    const match = /^\s*([-+]?[0-9]+(?:\.[0-9]+)?)\s*(deg)?\s*$/i.exec(value);
    if (match === null) return null;
    const parsed = Number(match[1]);
    return Number.isFinite(parsed) ? Math.round(parsed * 100) / 100 : null;
  }

  private readInspectorInsets(
    inspector: string | null,
    keys: Array<string>,
    vpToPxScale: number
  ): ReplayInsets | undefined {
    const shorthand = this.readInspectorString(inspector, keys);
    if (shorthand !== null) {
      const values = shorthand.trim().split(/[\s,]+/);
      if (values.length >= 1 && values.length <= 4) {
        const normalized: Array<number> = [];
        for (let index = 0; index < values.length; index++) {
          const length = this.parseInspectorLength(values[index], vpToPxScale);
          if (length === null) {
            return undefined;
          }
          normalized.push(length);
        }
        if (normalized.length === 1) {
          const all: ReplayInsets = {
            top: normalized[0], right: normalized[0], bottom: normalized[0], left: normalized[0]
          };
          return all;
        }
        if (normalized.length === 2) {
          const verticalHorizontal: ReplayInsets = {
            top: normalized[0], right: normalized[1], bottom: normalized[0], left: normalized[1]
          };
          return verticalHorizontal;
        }
        if (normalized.length === 3) {
          const topHorizontalBottom: ReplayInsets = {
            top: normalized[0], right: normalized[1], bottom: normalized[2], left: normalized[1]
          };
          return topHorizontalBottom;
        }
        const allEdges: ReplayInsets = {
          top: normalized[0], right: normalized[1], bottom: normalized[2], left: normalized[3]
        };
        return allEdges;
      }
    }

    const top = this.readInspectorNestedLength(inspector, keys, ['top'], vpToPxScale);
    const right = this.readInspectorNestedLength(inspector, keys, ['right', 'end'], vpToPxScale);
    const bottom = this.readInspectorNestedLength(inspector, keys, ['bottom'], vpToPxScale);
    const left = this.readInspectorNestedLength(inspector, keys, ['left', 'start'], vpToPxScale);
    if (top === null && right === null && bottom === null && left === null) {
      return undefined;
    }
    const insets: ReplayInsets = {};
    if (top !== null) insets.top = top;
    if (right !== null) insets.right = right;
    if (bottom !== null) insets.bottom = bottom;
    if (left !== null) insets.left = left;
    return insets;
  }

  private normalizeHorizontalAlignment(value: string | null): 'left' | 'right' | 'center' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('center') || normalized.includes('middle')) return 'center';
    if (normalized.includes('right') || normalized.includes('end')) return 'right';
    if (normalized.includes('left') || normalized.includes('start')) return 'left';
    return null;
  }

  private normalizeVerticalAlignment(value: string | null): 'top' | 'bottom' | 'center' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('center') || normalized.includes('middle')) return 'center';
    if (normalized.includes('bottom') || normalized.includes('end')) return 'bottom';
    if (normalized.includes('top') || normalized.includes('start')) return 'top';
    return null;
  }

  private readComponentId(node: FrameNode): string {
    try {
      return node.getId();
    } catch (_) {
      return '';
    }
  }

  private readNodeType(node: FrameNode): string {
    try {
      const type = node.getNodeType();
      return type.length === 0 ? 'UnknownComponent' : type;
    } catch (_) {
      return 'UnknownComponent';
    }
  }

  private defaultBackgroundColor(nodeType: string, isRoot: boolean): string | null {
    if (isRoot) return DEFAULT_PAGE_COLOR;
    if (nodeType === 'Button' || nodeType === 'MenuItem') return DEFAULT_BUTTON_COLOR;
    if (this.isImageNode(nodeType)) return DEFAULT_IMAGE_COLOR;
    if (this.isInputNode(nodeType)) return DEFAULT_PAGE_COLOR;
    return null;
  }

  /**
   * Button's `borderRadius` Inspector value is the generic border value and
   * does not describe the component's built-in shape. Preserve explicit
   * values only for Normal buttons; Capsule and Circle are defined by ArkUI
   * from their measured dimensions.
   */
  private resolveCornerRadius(
    nodeType: string,
    inspector: string | null,
    width: number,
    height: number,
    reportedCornerRadius: number | null
  ): number | null {
    if (nodeType !== 'Button') {
      return reportedCornerRadius;
    }
    const type = this.readButtonType(inspector);
    if (type === 'circle') {
      return width > 0 && height > 0 ? Math.min(width, height) / 2 : null;
    }
    if (type === 'capsule') {
      return height > 0 ? height / 2 : null;
    }
    // ButtonType.Normal has a square default. An explicit borderRadius is
    // represented by Inspector; zero is therefore both valid and intentional.
    return reportedCornerRadius === null ? 0 : reportedCornerRadius;
  }

  private readButtonType(inspector: string | null): 'capsule' | 'circle' | 'normal' {
    // `buttonType` is used by newer Inspector payloads; `type` covers older
    // payloads whose Button-specific field is simply named `type`. A value
    // such as `$type: Button` does not match any branch and therefore safely
    // retains ArkUI's documented Capsule default.
    const value = this.readInspectorString(inspector, ['buttonType', 'type']);
    if (value === null) {
      return 'capsule';
    }
    const normalized = value.toLowerCase();
    if (normalized.includes('circle')) return 'circle';
    if (normalized.includes('normal')) return 'normal';
    return 'capsule';
  }

  /**
   * Buttons and menu items paint their own background but delegate label
   * layout to an internal Text FrameNode. Reporting both as text produces the
   * doubled, top-left-plus-centred labels visible in replay.
   */
  private isButtonLikeNode(nodeType: string): boolean {
    return nodeType === 'Button' || nodeType === 'MenuItem';
  }

  /**
   * A Text/Span/RichEditor wrapper with a text descendant is visual chrome;
   * its child owns the rendered glyphs. Representing the wrapper as a shape
   * retains its background/border while preventing duplicate rich-text runs.
   */
  private shouldCaptureAsText(node: FrameNode, nodeType: string): boolean {
    if (!this.isTextNode(nodeType) || this.isButtonLikeNode(nodeType)) {
      return false;
    }
    if (nodeType === 'Text' || nodeType === 'Span' || nodeType === 'RichEditor') {
      return !this.hasTextDescendant(node, MAX_TEXT_DESCENDANT_SEARCH_DEPTH);
    }
    return true;
  }

  private hasTextDescendant(node: FrameNode, remainingDepth: number): boolean {
    if (remainingDepth <= 0) {
      return false;
    }
    let child: FrameNode | null = null;
    try {
      child = node.getFirstChild();
    } catch (_) {
      return false;
    }
    while (child !== null) {
      const childType = this.readNodeType(child);
      if (this.isTextNode(childType) && !this.isButtonLikeNode(childType)) {
        return true;
      }
      if (this.hasTextDescendant(child, remainingDepth - 1)) {
        return true;
      }
      try {
        child = child.getNextSibling();
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  private isTextNode(nodeType: string): boolean {
    return nodeType === 'Text' || nodeType === 'Span' || nodeType === 'TextInput' ||
      nodeType === 'TextArea' || nodeType === 'Search' || nodeType === 'RichEditor';
  }

  private isInputNode(nodeType: string): boolean {
    return nodeType === 'TextInput' || nodeType === 'TextArea' || nodeType === 'Search';
  }

  /**
   * `MASK_SENSITIVE_INPUTS` keeps ordinary copy replayable while never
   * revealing an input whose semantic type is absent or explicitly sensitive.
   * Unknown inputs intentionally remain masked as the privacy-safe fallback.
   */
  private isSensitiveInput(nodeType: string, inspector: string | null): boolean {
    if (!this.isInputNode(nodeType)) return false;
    const value = this.readInspectorString(inspector, [
      'inputType', 'contentType', 'keyboardType', 'textContentType'
    ]);
    if (value === null) return true;
    const normalized = value.toLowerCase();
    if (/password|passcode|pin|email|phone|tel|number|card|bank|idcard|identity|security|verify|code/.test(normalized)) {
      return true;
    }
    return !/text|normal|default|unspecified|url|nickname|name|search/.test(normalized);
  }

  private isImageNode(nodeType: string): boolean {
    return nodeType === 'Image' || nodeType === 'ImageAnimator' || nodeType === 'PixelMap';
  }

  private normalizeColor(value: string | null): string | null {
    if (value === null) return null;
    const color = value.trim();
    const six = /^#([0-9a-f]{6})$/i.exec(color);
    if (six !== null) return `#${six[1].toUpperCase()}FF`;
    const eight = /^#([0-9a-f]{8})$/i.exec(color);
    if (eight !== null) {
      // ArkUI serializes #AARRGGBB, while the Android replay renderer uses
      // #RRGGBBAA. Leaving this unchanged swaps opacity and color channels.
      const argb = eight[1].toUpperCase();
      return `#${argb.substring(2)}${argb.substring(0, 2)}`;
    }
    const hex = /^0x([0-9a-f]{8})$/i.exec(color);
    if (hex !== null) {
      // ArkUI's 0xAARRGGBB becomes the Android Replay renderer's #RRGGBBAA.
      const argb = hex[1].toUpperCase();
      return `#${argb.substring(2)}${argb.substring(0, 2)}`;
    }
    return null;
  }

  private normalizeImageMimeType(value: string): string | null {
    const mimeType = value.trim().toLowerCase();
    return mimeType === 'image/png' || mimeType === 'image/jpeg' || mimeType === 'image/gif' ||
      mimeType === 'image/webp' || mimeType === 'image/svg+xml' ? mimeType : null;
  }

  private normalizeImageFit(value: string | null): 'fill' | 'contain' | 'cover' | 'none' | 'scale-down' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase().replace(/[ _]/g, '');
    if (normalized.includes('contain')) return 'contain';
    if (normalized.includes('cover')) return 'cover';
    if (normalized.includes('scaledown')) return 'scale-down';
    if (normalized.includes('none') || normalized.includes('auto')) return 'none';
    if (normalized.includes('fill')) return 'fill';
    return null;
  }

  private normalizeFontWeight(value: string | null): number | null {
    if (value === null) return null;
    const normalized = value.trim().toLowerCase();
    const numeric = Number(normalized);
    if (Number.isFinite(numeric) && numeric >= 100 && numeric <= 900) {
      return Math.round(numeric / 100) * 100;
    }
    if (normalized.includes('thin')) return 100;
    if (normalized.includes('light')) return 300;
    if (normalized.includes('regular') || normalized.includes('normal')) return 400;
    if (normalized.includes('medium')) return 500;
    if (normalized.includes('semi') || normalized.includes('demi')) return 600;
    if (normalized.includes('extra') || normalized.includes('black') || normalized.includes('heavy')) return 900;
    if (normalized.includes('bold')) return 700;
    return null;
  }

  private normalizeFontStyle(value: string | null): 'normal' | 'italic' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('italic') || normalized.includes('oblique')) return 'italic';
    if (normalized.includes('normal')) return 'normal';
    return null;
  }

  private normalizeTextDecoration(value: string | null): 'none' | 'underline' | 'line-through' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('line-through') || normalized.includes('strik')) return 'line-through';
    if (normalized.includes('underline')) return 'underline';
    if (normalized.includes('none')) return 'none';
    return null;
  }

  private safeFontFamily(value: string): string {
    const families = value.split(',')
      .map((candidate: string): string => candidate.trim().replace(/^['\"]|['\"]$/g, ''))
      .filter((candidate: string): boolean => /^[a-zA-Z0-9 _-]{1,64}$/.test(candidate))
      .slice(0, 4);
    return families.length > 0 ? families.join(', ') : DEFAULT_FONT_FAMILY;
  }

  private clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  /** Preserve sub-vp layout values so accumulated column gaps stay aligned. */
  private roundReplayMetric(value: number): number {
    return Math.round(value * 100) / 100;
  }

  private toProtocolId(uniqueId: number): number {
    const candidate = this.rootEpoch * 1000000000 + uniqueId;
    if (!Number.isSafeInteger(candidate)) {
      throw new Error('Session Replay FrameNode id exceeds the protocol-safe range');
    }
    return candidate;
  }
}
