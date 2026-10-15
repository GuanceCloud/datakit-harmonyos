import { ReplayPatternLock } from './ReplayPatternLock';
import { FTSessionReplayBridgeRegistry } from '@guancecloud/ft_sdk';
import { copyReplayWireframe } from './ReplayWireframeValues';
import { ReplayOverlayVectors, ReplayPopupArrowSide } from './ReplayOverlayVectors';
import { FrameNode, UIContext } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { resourceManager } from '@kit.LocalizationKit';
import { ReplayMarqueeAnimation } from './ReplayMarqueeAnimation';
import { ReplayRichText } from './ReplayRichText';
import { normalizeReplayFontWeight, readReplayFontWeight } from './ReplayFontWeight';
import { ReplayComponentRaster, ReplayRasterOptions } from './ReplayComponentRaster';
import { ReplayVideoCapture, ReplayVideoFrameProvider, ReplayVideoState } from './ReplayVideoCapture';
import { ReplayVideoWireframes } from './ReplayVideoWireframes';
import { ReplayNativeControlPaint } from './ReplayNativeControlPaint';
import { ReplayControlWireframes } from './ReplayControlWireframes';
import { ReplayCalendarWireframes } from './ReplayCalendarWireframes';
import { ReplaySystemIcons } from './ReplaySystemIcons';
import { FTSessionReplayConfig, ImagePrivacy, TextAndInputPrivacy, TouchPrivacy } from './FTSessionReplayConfig';
import {
  ArkUIReplayLightNode, ArkUIReplayLightSnapshot, ArkUIReplayPageTransition,
  ArkUIReplaySceneBounds, ArkUIReplaySceneFrame, ArkUIReplayScenePage, ReplayInlineRun, SessionReplayScene
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
const MAX_OVERLAY_TREE_BYTES = 2 * 1024 * 1024;
const MAX_WINDOW_CHILDREN = 64;
const WINDOW_OVERLAY_SETTLE_MS = 600;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
const LARGE_IMAGE_PIXEL_COUNT = 100_000;
const DEFAULT_FONT_FAMILY = 'sans-serif';
const DEFAULT_TEXT_COLOR = '#1F2937FF';
const DEFAULT_PAGE_COLOR = '#FFFFFFFF';
const DEFAULT_BUTTON_COLOR = '#0A59F7FF';
const DEFAULT_IMAGE_COLOR = '#E2E8F0FF';
const DEFAULT_INPUT_BORDER_COLOR = '#CBD5E1FF';
const MAX_TEXT_DESCENDANT_SEARCH_DEPTH = 32;
const TEXT_FONT_SIZE_KEYS: Array<string> = ['actualFontSize', 'fontSize', 'textSize'];

interface RegisteredImageAsset {
  bytes: Uint8Array;
  mimeType: string;
}

interface ReplayControlVectorAsset { bytes: Uint8Array; token: string; }

interface ReplayNativeModalProjection {
  x: number;
  y: number;
  drawnX: number;
  drawnY: number;
  scale: number;
}

interface CachedReplayProperties {
  selectLabel: string | null;
  inspector: string | null;
  signature: string;
  frame: ReplayWireframe;
  imageKeys?: Array<string>;
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
  private overlayContext: UIContext | null = null;
  private overlayWindowRoot: FrameNode | null = null;
  private overlayGeometrySignature: string = '';
  private overlaySamplingUntil: number = 0;
  private readonly marquee: ReplayMarqueeAnimation = new ReplayMarqueeAnimation();
  private readonly richText: ReplayRichText = new ReplayRichText();
  private readonly rasters: ReplayComponentRaster = new ReplayComponentRaster();
  private readonly mediaRasters: ReplayComponentRaster = new ReplayComponentRaster('media');
  private readonly videoRasters: ReplayComponentRaster = new ReplayComponentRaster('video');
  private readonly videos: ReplayVideoCapture = new ReplayVideoCapture();
  private readonly calendarFrames: ReplayCalendarWireframes = new ReplayCalendarWireframes();
  private readonly systemIcons: ReplaySystemIcons = new ReplaySystemIcons();
  private readonly controls: ReplayNativeControlPaint = new ReplayNativeControlPaint();
  private readonly controlFrames: ReplayControlWireframes = new ReplayControlWireframes();
  private readonly controlVectorCache: Map<string, ReplayControlVectorAsset> = new Map();
  private controlVectorBytes: number = 0;
  private controlVectorRevision: number = 0;
  private readonly patterns: ReplayPatternLock = new ReplayPatternLock();
  private rasterContext: UIContext | null = null;
  private inlineMediaOwners: Set<number> | null = null;
  private editorContentSignatures: Map<number, string> | null = null;
  private inlineTextRuns: Map<number, Array<ReplayInlineRun> | null> | null = null;
  private activeComponentAnimations: boolean = false;
  private activeMediaIntervalMs: number = 0;
  private mediaPaintRevision: number = 0;
  private captureTimestamp: number = 0;

  constructor(maxNodes: number = 1500, config: FTSessionReplayConfig = new FTSessionReplayConfig()) {
    this.maxNodes = Math.max(1, Math.floor(maxNodes));
    this.config = config;
    const publish = (key: string, bytes: Uint8Array, mimeType: string): void => {
      this.registerImageAsset(key, bytes, mimeType);
      this.rasterPublished?.(key, bytes, mimeType);
    };
    const remove = (key: string): void => {
      this.unregisterImageAsset(key);
      this.rasterRemoved?.(key);
    };
    this.rasters.setCallbacks(publish, remove);
    this.mediaRasters.setCallbacks(publish, remove);
    this.videoRasters.setCallbacks(publish, remove);
  }

  private rasterPublished: ((key: string, bytes: Uint8Array, mimeType: string) => void) | null = null;
  private rasterRemoved: ((key: string) => void) | null = null;

  /** Forward newly packed native resources to the existing FIFO Worker image queue. */
  public setComponentRasterCallbacks(publish: (key: string, bytes: Uint8Array, mimeType: string) => void,
    remove: (key: string) => void): void {
    this.rasterPublished = publish;
    this.rasterRemoved = remove;
  }

  public registerVideoSource(componentId: string, source: string, poster?: ResourceStr): void {
    this.videos.register(componentId, source, poster);
  }

  public registerVideoFrameProvider(componentId: string, provider: ReplayVideoFrameProvider): void {
    this.videos.setProvider(componentId, provider);
  }

  public updateVideoState(componentId: string, state: ReplayVideoState): void { this.videos.update(componentId, state); }

  public unregisterVideoSource(componentId: string): void { this.videos.unregister(componentId); }

  public clearVideoSources(): void { this.videos.clear(); }

  public invalidateComponentRasters(): void {
    this.inlineMediaOwners = null;
    this.editorContentSignatures = null;
    this.inlineTextRuns = null;
  }

  public invalidateNativeControlPaint(): void {
    this.controls.invalidatePaint();
    // A PixelMap/Canvas can repaint with unchanged Inspector properties. Do
    // not invalidate from the rendering pass requested by our own snapshots.
    if (!this.rasters.isCapturing() && !this.mediaRasters.isCapturing() && !this.videoRasters.isCapturing()) this.mediaPaintRevision++;
    // A Span can change while its Text/RichEditor retains the same layout box.
    this.editorContentSignatures = null;
    this.inlineTextRuns = null;
  }

  public preparePatternLock(uiContext: UIContext, componentId: string, scale: number, originX: number, originY: number): void {
    if (this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_SENSITIVE_INPUTS ||
      this.config.getTouchPrivacy() !== TouchPrivacy.SHOW) return;
    try {
      const node = uiContext.getFrameNodeById(componentId);
      if (node === null || !node.isAttached() || !node.isVisible() || this.readNodeType(node) !== 'PatternLock') return;
      const info = this.readInspectorInfo(node);
      if (!this.canCaptureEditorInfo(info)) return;
      const attrs = this.controlFrames.attrs(info);
      const position = node.getPositionToWindowWithTransform();
      const size = node.getMeasuredSize();
      const radius = Math.max(0, parseFloat(String(attrs['circleRadius'] ?? '6vp')) || 6) /
        (String(attrs['circleRadius'] ?? '').endsWith('px') ? scale : 1);
      this.patterns.observe(this.toProtocolId(node.getUniqueId()), componentId,
        position.x - originX, position.y - originY, Math.min(size.width, size.height) / scale,
        radius, String(attrs['autoReset'] ?? 'true') !== 'false', String(attrs['skipUnselectedPoint']) === 'true');
    } catch (_) { }
  }

  public recordControlTouch(type: 'down' | 'move' | 'up' | 'cancel', pointerId: number, x: number, y: number): void {
    this.rasters.touch(x, y);
    if (this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS &&
      this.config.getTouchPrivacy() === TouchPrivacy.SHOW) this.patterns.touch(type, pointerId, x, y);
  }

  public updatePatternLockState(componentId: string, points: Array<number>, completed: boolean = true): void {
    if (this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS &&
      this.config.getTouchPrivacy() === TouchPrivacy.SHOW) this.patterns.update(componentId, points, completed);
  }

  private canCaptureNativeControl(type: string, info: Object | null): boolean {
    return !this.controlFrames.supports(type, info) && this.controls.isSupported(type) &&
      this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_ALL &&
      (type !== 'PatternLock' || (this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS &&
        this.config.getTouchPrivacy() === TouchPrivacy.SHOW));
  }

  /** Only the native CalendarPicker dialog owns this paint-only, bounded subtree. */
  private isNativeCalendarDialog(node: FrameNode, parentType: string): boolean {
    if (parentType !== 'Dialog' || this.readNodeType(node) !== 'Column') return false;
    const pending: Array<FrameNode> = [node];
    let calendar = false;
    let navigation = false;
    for (let index = 0; index < pending.length && index < 64; index++) {
      const current = pending[index];
      const type = this.readNodeType(current);
      if (this.readComponentId(current).length > 0 || this.isInputNode(type) || type === 'Web' || type === 'RichText') return false;
      if (type === 'Calendar') calendar = true;
      if (type === 'Image') {
        const source = this.readOwnInspectorString(this.serializeInspectorInfo(this.readInspectorInfo(current)), ['src']);
        if (source !== null && /^resource:\/\/\/ohos_ic_public_(?:double_)?arrow_(?:left|right)\.svg$/.test(source)) navigation = true;
      }
      try {
        let child = current.getFirstChild();
        while (child !== null) {
          if (pending.length >= 64) return false;
          pending.push(child);
          child = child.getNextSibling();
        }
      } catch (_) { return false; }
    }
    return calendar && navigation;
  }

  /** Starts a new lifetime for a root that was reconstructed by ArkUI. */
  public renewRootEpoch(): void {
    this.rootEpoch++;
    this.propertyCache.clear();
    this.propertyCacheChars = 0;
    this.scene.clear();
    this.marquee.clear();
    this.richText.clear();
    this.rasters.clear();
    this.mediaRasters.clear();
    this.videoRasters.clear();
    this.videos.reset();
    this.controls.clear();
    this.controlFrames.clear();
    this.systemIcons.clear();
    this.controlVectorCache.clear();
    this.controlVectorBytes = 0;
    this.patterns.clear();
    this.invalidateComponentRasters();
    this.overlayContext = null;
    this.overlayWindowRoot = null;
    this.overlayGeometrySignature = '';
    this.overlaySamplingUntil = 0;
  }

  public clearScene(): void {
    this.scene.clear();
    this.marquee.clear();
    this.richText.clear();
    this.rasters.clear();
    this.mediaRasters.clear();
    this.videoRasters.clear();
    this.videos.reset();
    this.controls.clear();
    this.controlFrames.clear();
    this.systemIcons.clear();
    this.controlVectorCache.clear();
    this.controlVectorBytes = 0;
    this.patterns.clear();
    this.invalidateComponentRasters();
    this.overlayContext = null;
    this.overlayWindowRoot = null;
    this.overlayGeometrySignature = '';
    this.overlaySamplingUntil = 0;
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
    this.invalidateImageProperties(key);
    this.registeredImageAssets.set(key, { bytes: copy, mimeType: normalizedMimeType });
    return true;
  }

  public unregisterImageAsset(componentId: string): void {
    this.registeredImageAssets.delete(componentId.trim());
    this.invalidateImageProperties(componentId.trim());
  }

  private invalidateImageProperties(key: string): void {
    this.propertyCache.forEach((cached: CachedReplayProperties, id: number): void => {
      if (cached.imageKeys?.includes(key)) {
        this.propertyCache.delete(id);
        this.propertyCacheChars -= (cached.inspector?.length ?? 0) + (cached.selectLabel?.length ?? 0);
      }
    });
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
   * UI-thread phase: reads public FrameNode state and returns a cheap handoff.
   * Bounded, id-filtered metadata identifies virtual media spans; native PNG
   * packing runs asynchronously and only registered resource keys enter frames.
   */
  public captureLightSnapshot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1,
    timestamp: number = Date.now()
  ): ArkUIReplayLightSnapshot {
    this.rasterContext = uiContext;
    const root = uiContext.getFrameNodeById(rootId);
    if (root === null) {
      throw new Error(`Session Replay root was not found: ${rootId}`);
    }
    const snapshot = this.captureFrameNodeLight(root, vpToPxScale, timestamp);
    const isDarkMode = this.readDarkMode(uiContext);
    for (const node of snapshot.nodes) node.isDarkMode = isDarkMode;
    return snapshot;
  }

  /** Resolves reachable ArkUI containers; internal Page/Stage parents remain private. */
  public findSceneRoot(uiContext: UIContext, rootId: string): FrameNode | null {
    this.rasterContext = uiContext;
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

  /** Compose lifecycle page roots together with the window's native floating surfaces. */
  public captureSceneLight(
    uiContext: UIContext,
    rootIds: Array<string>,
    vpToPxScale: number = 1,
    timestamp: number = Date.now(),
    transitions: Map<string, ArkUIReplayPageTransition> = new Map(),
    viewportBounds: ArkUIReplaySceneBounds | null = null,
    scenePages: Array<ArkUIReplayScenePage> = []
  ): ArkUIReplayLightSnapshot {
    this.rasterContext = uiContext;
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    this.beginComponentFrame(timestamp);
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
      // Always emit an explicit background layer, including frames without
      // modeled controls. Removing zIndex would replace this opaque canvas,
      // letting the player's insertion fallback place it above the page.
      sceneLayer: 0,
      clip: { top: 0, right: 0, bottom: 0, left: 0 }
    }];
    const isDarkMode = this.readDarkMode(uiContext);
    const composed = this.scene.compose(pages, frames, viewport, transitions, this.maxNodes - 1, timestamp);
    for (const node of composed) node.isDarkMode = isDarkMode;
    const capturedIds = new Set<number>();
    let overlayLayer = 0;
    for (const node of composed) {
      if (node.id > this.toProtocolId(0)) capturedIds.add(node.id - this.toProtocolId(0));
      overlayLayer = Math.max(overlayLayer, node.sceneLayer ?? 0);
    }
    const overlays: Array<ArkUIReplayLightNode> = [];
    const viewportClip = this.createClipRect(0, 0, viewport.width, viewport.height);
    for (const root of this.readWindowOverlayRoots(uiContext)) {
      try {
        const start = overlays.length;
        this.appendLightPreOrder(root, scale, overlays, false, viewportClip,
          this.readAncestorOpacity(root), -viewport.x, -viewport.y, capturedIds, this.maxNodes - 1);
        overlayLayer += this.maxNodes + 1;
        for (let index = start; index < overlays.length; index++) {
          overlays[index].sceneLayer = overlayLayer;
          overlays[index].isDarkMode = isDarkMode;
          capturedIds.add(overlays[index].id - this.toProtocolId(0));
        }
      } catch (_) { }
    }
    // Floating surfaces must remain visible even when a large page exhausts
    // the budget. Their window-space geometry never inherits Router movement.
    for (const node of composed.slice(0, Math.max(0, this.maxNodes - 1 - overlays.length))) nodes.push(node);
    for (const node of overlays) {
      if (node.isPopupSurface) node.popupArrowSide = this.readPopupArrowSide(node, composed);
      nodes.push(node);
    }
    this.sampleWindowOverlayMotion(overlays, timestamp);
    this.finishControlFrame(nodes);
    this.marquee.endFrame();
    // The synthetic scene root only supplies a stable viewport; it is not a
    // rendered application frame. When the last Router page has already been
    // released, persisting that root would remove every visible wireframe and
    // leave Replay on a blank final frame. Let the recorder keep the last
    // renderable snapshot until a successor page or View End arrives.
    if (nodes.length === 1) {
      throw new Error('Session Replay scene has no renderable content.');
    }
    return { timestamp, vpToPxScale: scale, nodes, hasActiveAnimations: this.activeComponentAnimations || this.activeMediaIntervalMs > 0,
      preferredSamplingIntervalMs: this.activeComponentAnimations ? undefined : this.activeMediaIntervalMs };
  }

  private isWindowOverlay(nodeType: string): boolean {
    return nodeType === 'MenuWrapper' || nodeType === 'Popup' || nodeType === 'Dialog' ||
      nodeType === 'AlertDialog' || nodeType === 'ActionSheet' ||
      nodeType === 'SheetWrapper';
  }

  /** Window Render Service animations can continue without another page willDraw callback. */
  private sampleWindowOverlayMotion(nodes: Array<ArkUIReplayLightNode>, timestamp: number): void {
    const signature = nodes.map((node): string =>
      `${node.id}:${node.x}:${node.y}:${node.width}:${node.height}:${node.opacity ?? 1}`).join('|');
    if (signature !== this.overlayGeometrySignature) {
      this.overlayGeometrySignature = signature;
      this.overlaySamplingUntil = nodes.length === 0 ? 0 : timestamp + WINDOW_OVERLAY_SETTLE_MS;
    }
    // Carry this through the existing frame scheduler so a final settled
    // position is committed even when native overlay drawing is otherwise idle.
    this.activeComponentAnimations = this.activeComponentAnimations || timestamp < this.overlaySamplingUntil;
  }

  private readPopupArrowSide(surface: ArkUIReplayLightNode, page: Array<ArkUIReplayLightNode>): ReplayPopupArrowSide {
    let side: ReplayPopupArrowSide = 'top';
    let score = Infinity;
    for (const node of page) {
      if (node.nodeType !== 'Button' || (node.opacity ?? 1) <= 0 ||
        (node.clip?.top ?? 0) + (node.clip?.bottom ?? 0) >= node.height ||
        (node.clip?.left ?? 0) + (node.clip?.right ?? 0) >= node.width) continue;
      const cx = surface.x + surface.width / 2, cy = surface.y + surface.height / 2;
      const candidates: Array<number> = [surface.y - node.y - node.height, node.y - surface.y - surface.height,
        surface.x - node.x - node.width, node.x - surface.x - surface.width];
      const sides: Array<ReplayPopupArrowSide> = ['top', 'bottom', 'left', 'right'];
      for (let index = 0; index < candidates.length; index++) {
        const gap = candidates[index];
        const aligned: boolean = index < 2
          ? (cx >= node.x && cx <= node.x + node.width)
          : (cy >= node.y && cy <= node.y + node.height);
        // Native message popups leave an 8vp target gap. Fall back to their default Bottom placement.
        if (aligned && gap >= 0 && gap <= 32 && Math.abs(gap - 8) < score) {
          score = Math.abs(gap - 8); side = sides[index];
        }
      }
    }
    return side;
  }

  private readDarkMode(uiContext: UIContext): boolean {
    try {
      return uiContext.getHostContext()?.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    } catch (_) { return false; }
  }

  /**
   * Page/Stage hide their parents from FrameNode. Bootstrap floating roots
   * from the public, id-filtered window Inspector; discard its attributes.
   * Once an overlay exposes the window root, use only live FrameNode siblings
   * on subsequent frames. No Inspector tree is handed off or persisted.
   */
  private readWindowOverlayRoots(uiContext: UIContext): Array<FrameNode> {
    const roots: Array<FrameNode> = [];
    if (this.overlayContext !== uiContext) {
      this.overlayContext = uiContext;
      this.overlayWindowRoot = null;
      this.overlayGeometrySignature = '';
      this.overlaySamplingUntil = 0;
    }
    try {
      if (this.overlayWindowRoot !== null && this.overlayWindowRoot.isAttached()) {
        let child = this.overlayWindowRoot.getFirstChild();
        for (let index = 0; child !== null && index < MAX_WINDOW_CHILDREN; index++) {
          if (this.isWindowOverlay(child.getNodeType())) roots.push(child);
          child = child.getNextSibling();
        }
        return roots;
      }
      this.overlayWindowRoot = null;
      const tree = uiContext.getFilteredInspectorTree(['id']);
      if (tree.length === 0 || tree.length > MAX_OVERLAY_TREE_BYTES) return roots;
      const info = JSON.parse(tree) as Record<string, Object>;
      const children = info['$children'];
      if (!Array.isArray(children)) return roots;
      for (let index = 0; index < Math.min(children.length, MAX_WINDOW_CHILDREN); index++) {
        const descriptor = children[index] as Record<string, Object>;
        if (descriptor === null || typeof descriptor !== 'object') continue;
        const nodeType = descriptor['$type'];
        const id = descriptor['$ID'];
        if (typeof nodeType !== 'string' || !this.isWindowOverlay(nodeType) ||
          typeof id !== 'number' || !Number.isInteger(id) || id <= 0) continue;
        const root = uiContext.getFrameNodeByUniqueId(id);
        if (root === null || !root.isAttached() || !this.isWindowOverlay(root.getNodeType())) continue;
        roots.push(root);
        const parent = root.getParent();
        if (parent !== null && parent.getNodeType() === 'root' && parent.isAttached()) {
          this.overlayWindowRoot = parent;
        }
      }
    } catch (_) {
      // Older runtimes or a disappearing overlay cannot invalidate the page.
      this.overlayWindowRoot = null;
    }
    return roots;
  }

  private cachedWireframe(
    node: ArkUIReplayLightNode, inspector: string | null, scale: number, selectLabel: string | null
  ): ReplayWireframe {
    if (node.nodeType === 'Web' && node.webViewSlotId !== undefined) {
      return {
        id: node.id, type: 'webview', slotId: node.webViewSlotId,
        x: node.x, y: node.y, width: node.width, height: node.height,
        permanentId: node.componentId || undefined,
        isVisible: (node.opacity ?? 1) > 0 &&
          (node.clip?.left ?? 0) + (node.clip?.right ?? 0) < node.width &&
          (node.clip?.top ?? 0) + (node.clip?.bottom ?? 0) < node.height
      };
    }
    const signature = `${node.componentId}|${node.nodeType}|${node.width}|${node.height}|${scale}|${node.isRoot}|` +
      `${node.shouldCaptureAsText}|${node.isSelectArrow}|${node.isDarkMode}|${node.componentRasterKey}|` +
      `${node.isPopupSurface}|${node.isOverlayCloseIcon}|` +
      `${this.config.getTextAndInputPrivacy()}|${this.config.getImagePrivacy()}|${this.config.isCaptureVisiblePasswordEnabled()}|${this.config.getTouchPrivacy()}`;
    const cached = this.propertyCache.get(node.id);
    if (cached !== undefined && cached.inspector === inspector && cached.signature === signature && cached.selectLabel === selectLabel) {
      const frame = copyReplayWireframe(cached.frame);
      frame.x = node.x;
      frame.y = node.y;
      if (frame.type === 'image' && frame.resourceId !== undefined) {
        const resource = this.resolveImageResource(node.componentRasterKey ?? node.componentId, node.id,
          node.componentRasterKey === undefined ? inspector : null);
        if (resource !== null) frame.resourceId = resource.token;
      }
      return frame;
    }
    const canUseRaster = node.componentRasterKey !== undefined && this.canCaptureImage(node.width, node.height, scale) &&
      (this.isMediaNode(node.nodeType) || node.nodeType === 'Text' || node.nodeType === 'SymbolGlyph' || node.nodeType === 'RichEditor' ||
        this.canCaptureNativeControl(node.nodeType, node.inspectorInfo)) &&
      (node.nodeType !== 'Text' || this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_ALL) &&
      (node.nodeType !== 'RichEditor' || this.canCaptureEditor(inspector)) && this.canCaptureMedia(node.nodeType);
    const frame = canUseRaster ? this.createImageWireframe(node.id, node.x, node.y, node.width, node.height,
      node.componentId, node.nodeType, inspector, scale, node.componentRasterKey) :
      this.createWireframe(node.id, node.x, node.y, node.width, node.height,
      node.componentId, node.nodeType, inspector, node.shouldCaptureAsText, node.isRoot, scale, node.isSelectArrow === true, selectLabel);
    this.appendCommonVisualProperties(frame, inspector);
    if (frame.type === 'shape') {
      this.appendNativeMaterialBackground(frame, inspector, node.isDarkMode === true);
    }
    this.propertyCacheChars -= (cached?.inspector?.length ?? 0) + (cached?.selectLabel?.length ?? 0);
    this.propertyCacheChars += (inspector?.length ?? 0) + (selectLabel?.length ?? 0);
    const imageKeys = frame.type === 'image' ? [node.componentRasterKey ?? node.componentId,
      this.readInspectorString(inspector, ['src', 'source', 'imageSrc', 'resource'])?.trim() ?? ''] : undefined;
    this.propertyCache.set(node.id, { inspector, selectLabel, signature, frame: copyReplayWireframe(frame), imageKeys });
    while (this.propertyCacheChars > 2 * 1024 * 1024 || this.propertyCache.size > this.maxNodes) {
      const oldest = this.propertyCache.keys().next().value as number;
      const evicted = this.propertyCache.get(oldest);
      this.propertyCacheChars -= (evicted?.inspector?.length ?? 0) + (evicted?.selectLabel?.length ?? 0);
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
    this.beginComponentFrame(timestamp);
    const scale = Number.isFinite(vpToPxScale) && vpToPxScale > 0 ? vpToPxScale : 1;
    const nodes: Array<ArkUIReplayLightNode> = [];
    this.appendLightPreOrder(root, scale, nodes, true);
    this.finishControlFrame(nodes);
    this.marquee.endFrame();
    return { timestamp, vpToPxScale: scale, nodes, hasActiveAnimations: this.activeComponentAnimations || this.activeMediaIntervalMs > 0,
      preferredSamplingIntervalMs: this.activeComponentAnimations ? undefined : this.activeMediaIntervalMs };
  }

  /** Custom thumbs and stars refer to immutable assets; state changes only move or clip the frames. */
  private controlImage(owner: ArkUIReplayLightNode, source: string, template: ReplayShapeWireframe, scale: number): ReplayWireframe {
    const info: Record<string, Object> = { 'src': source };
    const node: ArkUIReplayLightNode = { id: template.id, x: template.x, y: template.y,
      width: template.width, height: template.height, componentId: template.permanentId ?? owner.componentId,
      nodeType: 'Image', inspectorInfo: info, shouldCaptureAsText: false, isRoot: false,
      usedTransformedPosition: false, opacity: template.shapeStyle?.opacity };
    const image = this.cachedWireframe(node, JSON.stringify(info), scale, null);
    image.permanentId = template.permanentId;
    image.clip = template.clip;
    image.zIndex = template.zIndex;
    if (image.type === 'image') {
      image.shapeStyle = { opacity: template.shapeStyle?.opacity };
      image.border = template.border;
    }
    return image;
  }

  /** Only control geometry / allowlisted system SVGs; app images retain image privacy. */
  private controlVector(svg: string, template: ReplayShapeWireframe): ReplayWireframe {
    let asset = this.controlVectorCache.get(svg);
    if (asset === undefined) {
      const bytes = util.TextEncoder.create('utf-8').encodeInto(svg);
      asset = { bytes, token: `arkui-vector-${this.rootEpoch}-${++this.controlVectorRevision}` };
      this.controlVectorCache.set(svg, asset);
      this.controlVectorBytes += asset.bytes.byteLength;
      while (this.controlVectorCache.size > 64 || this.controlVectorBytes > 512 * 1024) {
        const oldest = this.controlVectorCache.keys().next().value as string;
        this.controlVectorBytes -= this.controlVectorCache.get(oldest)!.bytes.byteLength;
        this.controlVectorCache.delete(oldest);
      }
    }
    const token = asset.token;
    if (!this.pendingImageResources.some((resource): boolean => resource.token === token)) {
      this.pendingImageResources.push({ token, bytes: asset.bytes, mimeType: 'image/svg+xml' });
    }
    const frame: ReplayImageWireframe = { id: template.id, type: 'image', x: template.x, y: template.y,
      width: template.width, height: template.height, permanentId: template.permanentId,
      clip: template.clip, zIndex: template.zIndex, shapeStyle: template.shapeStyle,
      resourceId: token, mimeType: 'svg+xml', isEmpty: false, imageStyle: { objectFit: 'fill' } };
    return frame;
  }

  private finishControlFrame(nodes: Array<ArkUIReplayLightNode>): void {
    const ids = new Set<number>();
    const visibleVideos = new Set<string>();
    for (const node of nodes) {
      if (node.nodeType === 'Video' && (node.opacity ?? 1) > 0 &&
        (node.clip?.left ?? 0) + (node.clip?.right ?? 0) < node.width &&
        (node.clip?.top ?? 0) + (node.clip?.bottom ?? 0) < node.height) visibleVideos.add(node.componentId);
      if (node.componentRasterKey !== undefined && (node.nodeType === 'RichEditor' || node.nodeType === 'Text') &&
        (node.opacity ?? 1) > 0 && (node.clip?.left ?? 0) + (node.clip?.right ?? 0) < node.width &&
        (node.clip?.top ?? 0) + (node.clip?.bottom ?? 0) < node.height) {
        this.rasters.observeTouchRegion(node.id - this.toProtocolId(0), node.x, node.y, node.width, node.height);
      }
      if (node.nodeType !== 'PatternLock') continue;
      ids.add(node.id);
      this.patterns.align(node.id, node.x, node.y);
    }
    this.patterns.retain(ids);
    this.videos.retainVisible(visibleVideos);
  }

  private beginComponentFrame(timestamp: number): void {
    this.patterns.beginFrame();
    this.rasters.beginFrame();
    this.captureTimestamp = timestamp;
    this.activeComponentAnimations = false;
    this.activeMediaIntervalMs = 0;
    this.marquee.beginFrame();
  }

  /**
   * Worker/queue phase: parses Inspector data, applies privacy policies,
   * creates wireframes and resolves image bytes.  This method intentionally
   * accepts no FrameNode so callers cannot accidentally traverse ArkUI here.
   */
  public materializeLightSnapshot(snapshot: ArkUIReplayLightSnapshot): SessionReplayRecord {
    const wireframes: Array<ReplayWireframe> = [];
    const frameSources: Map<number, ArkUIReplayLightNode> = new Map();
    let extraBudget = Math.max(0, this.maxNodes - snapshot.nodes.length);
    let hasControlParts = false;
    const pageZIndices: Map<number, Array<number>> = new Map();
    this.pendingImageResources = [];
    const retained = new Set<number>();
    const groupStates = this.controlFrames.groupStates(snapshot.nodes);
    const calendar = this.calendarFrames.prepare(snapshot.nodes, snapshot.timestamp);
    const fontWeights = this.resolveFontWeights(snapshot.nodes);
    const selectInspectors = new Map<number, string | null>();
    for (const node of snapshot.nodes) {
      if (node.nodeType === 'Select' || node.nodeType === 'Button' || node.nodeType === 'Toggle') {
        selectInspectors.set(node.id, this.serializeInspectorInfo(node.inspectorInfo));
      }
    }
    for (let index = 0; index < snapshot.nodes.length; index++) {
      const node = snapshot.nodes[index];
      const inspector = node.nodeType === 'Select' ? selectInspectors.get(node.id) ?? null :
        this.serializeInspectorInfo(node.inspectorInfo);
      const selectLabel = calendar.labels.get(node.id) ?? (node.selectLabelOwnerId !== undefined ?
        this.readInspectorString(selectInspectors.get(node.selectLabelOwnerId) ?? null, ['value']) :
        node.buttonLabelOwnerId !== undefined ?
          this.readOwnInspectorString(selectInspectors.get(node.buttonLabelOwnerId) ?? null, ['label']) : null);
      retained.add(node.id);
      let wireframe = this.cachedWireframe(node, inspector, snapshot.vpToPxScale, selectLabel);
      // Resolved or explicit child weights (including Normal) always win.
      // Apply fallback after the property cache so owner-only changes stay live.
      if (wireframe.type === 'text' && wireframe.textStyle.weight === undefined) {
        const weight = fontWeights.get(node.id);
        if (weight !== undefined) wireframe.textStyle.weight = weight;
      }
      if (node.systemIconZIndex !== undefined) wireframe.zIndex = node.systemIconZIndex;
      if (node.systemIconSvg !== undefined && wireframe.type !== 'placeholder') {
        // Keep native geometry, fit, clipping, transforms and tint. Loading a
        // static system asset does not require screenshotting the input owner.
        const template: ReplayShapeWireframe = { id: node.id, type: 'shape', x: node.x, y: node.y,
          width: node.width, height: node.height, permanentId: wireframe.permanentId,
          border: wireframe.border,
          // A resolved icon has no empty-image placeholder background.
          shapeStyle: this.createShapeStyle('SystemIcon', inspector, false, node.width, node.height, snapshot.vpToPxScale),
          zIndex: wireframe.zIndex };
        const info = this.getInspectorValue(inspector);
        const symbolColors = node.nodeType === 'SymbolGlyph' && info !== null ?
          this.findInspectorStringArray(info, ['symbolColor', 'symbolColorList', 'fontColor']) : null;
        const color = this.normalizeColor(this.readOwnInspectorString(inspector, ['fillColor'])) ??
          (node.nodeType === 'SymbolGlyph' ? this.normalizeColor(symbolColors?.[0] ??
            this.readOwnInspectorString(inspector, ['symbolColor', 'fontColor'])) : null);
        const icon = this.controlVector(ReplaySystemIcons.tint(node.systemIconSvg, color), template);
        if (icon.type === 'image' && wireframe.type === 'image') icon.imageStyle = wireframe.imageStyle ?? icon.imageStyle;
        wireframe = icon;
      }
      if (node.nodeType === 'CalendarDialog' && wireframe.type === 'shape' && node.calendarTheme !== undefined &&
        this.readOwnInspectorString(inspector, ['shadow'])?.toUpperCase() === 'SHADOWSTYLE.OUTERDEFAULTSM') {
        const style = wireframe.shapeStyle ?? {};
        style.shadow = node.calendarTheme.shadow;
        wireframe.shapeStyle = style;
      }
      const calendarArrow = calendar.arrows.get(node.id);
      if (calendarArrow !== undefined) {
        const template: ReplayShapeWireframe = { id: node.id, type: 'shape', x: node.x, y: node.y,
          width: node.width, height: node.height, shapeStyle: { opacity: node.opacity ?? 1 } };
        wireframe = this.controlVector(calendarArrow, template);
      }
      const content = snapshot.nodes[index + 1];
      const popupBackground = wireframe.type === 'shape' ? wireframe.shapeStyle?.backgroundColor : undefined;
      if (node.isPopupSurface && wireframe.type === 'shape' && content?.nodeType === 'Scroll' &&
        node.componentId.length === 0 && popupBackground !== undefined && !popupBackground.endsWith('00') &&
        this.readInspectorString(inspector, ['shadow'])?.toUpperCase() === 'SHADOWSTYLE.OUTERDEFAULTMD') {
        const template = wireframe;
        template.shapeStyle = { opacity: node.opacity ?? 1,
          transform: template.shapeStyle?.transform, visible: template.shapeStyle?.visible,
          shadow: { color: '#00000026', offsetX: 0, offsetY: 6, blurRadius: 20 } };
        wireframe = this.controlVector(ReplayOverlayVectors.popup(node.width, node.height,
          { x: this.roundReplayMetric(content.x - node.x), y: this.roundReplayMetric(content.y - node.y),
            width: content.width, height: content.height }, popupBackground, node.popupArrowSide), template);
      }
      if (node.isOverlayCloseIcon) {
        const color = this.readRenderedTextColor(inspector) ?? '#000000E5';
        const template: ReplayShapeWireframe = { id: node.id, type: 'shape', x: node.x, y: node.y,
          width: node.width, height: node.height, permanentId: node.componentId || undefined,
          shapeStyle: { opacity: node.opacity ?? 1 } };
        wireframe = this.controlVector(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M4 4L20 20M20 4L4 20" fill="none" stroke="${color}" stroke-width="1.8" stroke-linecap="round"/></svg>`, template);
      }

      // System dialog scale animations were normalized to layout coordinates
      // on UI. Do not apply that native surface transform a second time.
      if (node.isNativeModalSurface && wireframe.type !== 'placeholder' && wireframe.shapeStyle !== undefined) {
        wireframe.shapeStyle.transform = undefined;
      }

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
      frameSources.set(wireframe.id, node);
      if (node.nodeType === 'Video' && this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_ALL) {
        const parts = ReplayVideoWireframes.create(node, extraBudget);
        extraBudget -= parts.length;
        hasControlParts = hasControlParts || parts.length > 0;
        for (const part of parts) {
          retained.add(part.id);
          part.zIndex = (wireframe.zIndex ?? 0) + 0.5;
          wireframes.push(part);
          frameSources.set(part.id, node);
        }
      }
      if (node.nodeType === 'CalendarPicker' && wireframe.type === 'shape') {
        const parts = this.calendarFrames.completeEntry(node, snapshot.nodes, index, wireframe,
          snapshot.vpToPxScale, extraBudget);
        extraBudget -= parts.length;
        hasControlParts = hasControlParts || parts.length > 0;
        for (const part of parts) {
          retained.add(part.id);
          part.zIndex = wireframe.zIndex;
          wireframes.push(part);
          frameSources.set(part.id, node);
        }
      }
      const calendarGrid = calendar.grids.get(node.id);
      if (calendarGrid !== undefined) {
        const parts = this.calendarFrames.create(node, calendarGrid, snapshot.vpToPxScale, extraBudget,
          (value: string): string => this.filterText(value, 'Text', node.width, null),
          this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS);
        extraBudget -= parts.length;
        hasControlParts = hasControlParts || parts.length > 0;
        for (const part of parts) {
          retained.add(part.id);
          part.zIndex = (wireframe.zIndex ?? 0) + (part.zIndex ?? 0) * 0.5;
          wireframes.push(part);
          frameSources.set(part.id, node);
        }
      }
      if (node.isSelectArrow || this.controlFrames.supports(node.nodeType, node.inspectorInfo)) {
        const attrs = this.controlFrames.attrs(node.inspectorInfo);
        const isButton = node.nodeType === 'Button' ||
          (node.nodeType === 'Toggle' && String(attrs['type']).includes('Button'));
        if (!isButton && wireframe.type === 'shape') {
          const style = wireframe.shapeStyle ?? {};
          style.backgroundColor = '#00000000';
          style.backgroundGradient = undefined;
          wireframe.shapeStyle = style;
        }
        const parts = this.controlFrames.create(node, snapshot.vpToPxScale, extraBudget, groupStates.get(node.id),
          this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS,
          this.canCaptureEditorInfo(node.inspectorInfo) && this.config.getTouchPrivacy() === TouchPrivacy.SHOW,
          (source: string, template: ReplayShapeWireframe): ReplayWireframe => this.controlImage(node, source, template, snapshot.vpToPxScale),
          (svg: string, template: ReplayShapeWireframe): ReplayWireframe => this.controlVector(svg, template));
        extraBudget -= parts.length;
        hasControlParts = hasControlParts || parts.length > 0;
        for (const part of parts) {
          retained.add(part.id);
          // A foreground plane fits between this native zIndex and the next.
          // It is compacted to an integer after all frames are materialized.
          part.zIndex = (wireframe.zIndex ?? 0) + (part.zIndex ?? 0) * 0.5;
          wireframes.push(part);
          frameSources.set(part.id, node);
        }
      }
      if (node.nodeType === 'RichText') {
        const html = this.readInspectorString(inspector, ['content']);
        if (html !== null && html.trim().length > 0) {
          const children = this.richText.create(node, html, snapshot.vpToPxScale, extraBudget,
            (value: string, input: boolean): string => this.filterText(value, input ? 'TextArea' : 'Text', node.width, null));
          extraBudget -= children.length;
          for (const child of children) {
            child.zIndex = wireframe.zIndex;
            wireframes.push(child);
            frameSources.set(child.id, node);
          }
        }
      }
      if (node.inlineRuns !== undefined) {
        const children = this.richText.createNative(node, snapshot.vpToPxScale, extraBudget,
          (value: string, input: boolean): string => this.filterText(value, input ? 'RichEditor' : 'Text', node.width, inspector),
          (source: string, template: ReplayShapeWireframe): ReplayWireframe => this.controlImage(node, source, template, snapshot.vpToPxScale),
          fontWeights.get(node.id));
        extraBudget -= children.length;
        for (const child of children) {
          retained.add(child.id);
          child.zIndex = wireframe.zIndex;
          wireframes.push(child);
          frameSources.set(child.id, node);
        }
      }
    }
    this.propertyCache.forEach((cached: CachedReplayProperties, id: number): void => {
      if (!retained.has(id)) {
        this.propertyCache.delete(id);
        this.propertyCacheChars -= (cached.inspector?.length ?? 0) + (cached.selectLabel?.length ?? 0);
      }
    });
    this.richText.retain(retained);
    for (const frame of wireframes) {
      const source = frameSources.get(frame.id)!;
      if (source.isPageSurface || (source.sceneLayer === undefined && !hasControlParts)) continue;
      const layer = source.sceneLayer ?? -1;
      let indices = pageZIndices.get(layer);
      if (indices === undefined) {
        indices = [];
        pageZIndices.set(layer, indices);
      }
      const zIndex = frame.zIndex ?? 0;
      if (!indices.includes(zIndex)) indices.push(zIndex);
    }
    pageZIndices.forEach((indices: Array<number>): void => { indices.sort((left: number, right: number): number => left - right); });
    for (let index = 0; index < wireframes.length; index++) {
      const node = frameSources.get(wireframes[index].id)!;
      if (node.sceneLayer === undefined && !hasControlParts) continue;
      const wireframe = wireframes[index];
      // Native zIndex is local to its page. Compact its relative order into
      // that page's reserved band instead of allowing it to cross pages.
      const rank = node.isPageSurface ? 0 : (pageZIndices.get(node.sceneLayer ?? -1)?.indexOf(wireframe.zIndex ?? 0) ?? 0) + 1;
      wireframe.zIndex = (node.sceneLayer ?? 0) + rank;
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
    nodeBudget: number = this.maxNodes,
    parentType: string = '',
    grandparentType: string = '',
    parentId: number = 0,
    grandparentId: number = 0,
    marqueeTextX?: number,
    inheritedModalProjection?: ReplayNativeModalProjection,
    fontWeightOwnerId?: number
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
    // Calendar's days are native paint. Keep its surface and descendants as
    // data; the processing queue completes only the missing semantic content.
    const nodeType = this.isNativeCalendarDialog(node, parentType) ? 'CalendarDialog' : this.readNodeType(node);
    const isNativeModalSurface = nodeType === 'Column' && (parentType === 'AlertDialog' || parentType === 'ActionSheet');
    const modalProjection = isNativeModalSurface ? this.readNativeModalProjection(node, vpToPxScale) : inheritedModalProjection;
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

    if (modalProjection !== undefined) {
      // Native modal animations project the whole subtree, but measured
      // dimensions and text metrics remain unscaled. Restore that single
      // layout basis while retaining each descendant's own scroll offset.
      x = isNativeModalSurface ? modalProjection.x :
        this.roundReplayMetric(modalProjection.x + (x - modalProjection.drawnX) / modalProjection.scale);
      y = isNativeModalSurface ? modalProjection.y :
        this.roundReplayMetric(modalProjection.y + (y - modalProjection.drawnY) / modalProjection.scale);
    }
    x = this.roundReplayMetric(x + sceneOffsetX);
    y = this.roundReplayMetric(y + sceneOffsetY);
    if (parentType === 'Marquee' && marqueeTextX !== undefined) x = this.roundReplayMetric(marqueeTextX);

    const bounds = this.createClipRect(x, y, width, height);
    const clipsDescendants = isRoot || this.isClipToFrame(node);
    const childClip = clipsDescendants
      ? this.intersectClipRects(ancestorClip, bounds)
      : ancestorClip;

    // Keep attached nodes and their original geometry while they move through
    // a clipping boundary. Fully clipped nodes remain present with an empty
    // clip instead of being removed and added again when they slide back in.
    const inspectorInfo = this.readInspectorInfo(node);
    let systemIconSvg = nodeType === 'Image' ? this.systemIcons.capture(inspectorInfo) : undefined;
    if (nodeType === 'SymbolGlyph' && parentType === 'Stack' && grandparentType === 'TextInput') {
      try {
        const owner = node.getParent()?.getParent();
        if (owner !== null && owner !== undefined) systemIconSvg = this.systemIcons.capturePasswordSymbol(this.readInspectorInfo(owner));
      } catch (_) { }
    }
    let systemIconZIndex: number | undefined = undefined;
    if (nodeType === 'Image' && parentType === 'Button' && grandparentType === 'SideBarContainer') {
      // Native zIndex is local to the Button subtree. The replay protocol is
      // flat; without its owner's plane this Image can sit behind the content.
      try {
        const owner = node.getParent();
        if (owner !== null) systemIconZIndex = this.readInspectorNumber(
          this.serializeInspectorInfo(this.readInspectorInfo(owner)), ['zIndex', 'zOrder']) ?? undefined;
      } catch (_) { }
    }
    let componentRasterKey: string | undefined = undefined;
    const visible = this.intersectClipRects(ancestorClip, bounds) !== null && opacity > 0;
    const controlInfo = (inspectorInfo ?? {}) as Record<string, Object>;
    const controlAttrs = (controlInfo['$attrs'] ?? controlInfo) as Record<string, Object>;
    const videoState = nodeType === 'Video' ? this.videos.state(this.readComponentId(node)) : undefined;
    if (this.isMediaNode(nodeType) && systemIconSvg === undefined) {
      componentRasterKey = this.captureMedia(node, nodeType, controlAttrs, width, height, vpToPxScale, visible);
    }
    const isFrameControl = this.controlFrames.supports(nodeType, inspectorInfo);
    if (isFrameControl && String(controlAttrs['enabled'] ?? 'true') === 'false') opacity *= 0.4;
    const motion = isFrameControl ? this.controlFrames.sample(nodeId, nodeType, inspectorInfo, this.captureTimestamp, visible) : null;
    this.activeComponentAnimations = this.activeComponentAnimations || motion?.active === true;
    const pattern = nodeType === 'PatternLock' && visible && this.canCaptureEditorInfo(inspectorInfo) &&
      this.config.getTouchPrivacy() === TouchPrivacy.SHOW ?
      this.patterns.observe(this.toProtocolId(nodeId), this.readComponentId(node), x, y, Math.min(width, height),
        Math.max(0, parseFloat(String(controlAttrs['circleRadius'] ?? '6vp')) || 6) /
          (String(controlAttrs['circleRadius'] ?? '').endsWith('px') ? vpToPxScale : 1),
        String(controlAttrs['autoReset'] ?? 'true') !== 'false', String(controlAttrs['skipUnselectedPoint']) === 'true') : null;
    const hasNativeLabel = typeof controlAttrs['label'] === 'string' && (controlAttrs['label'] as string).length > 0;
    const isNativeControl = this.canCaptureNativeControl(nodeType, inspectorInfo) &&
      ((nodeType !== 'Button' && nodeType !== 'Toggle') || hasNativeLabel || !this.hasTextDescendant(node, MAX_TEXT_DESCENDANT_SEARCH_DEPTH)) &&
      !this.hasInputDescendant(node, MAX_TEXT_DESCENDANT_SEARCH_DEPTH);
    const isSelectArrow = nodeType === 'SymbolGlyph' && parentType === 'Row' && grandparentType === 'Select';
    const isOverlayCloseIcon = nodeType === 'SymbolGlyph' && parentType === 'Button' && grandparentType === 'SheetPage';
    const inlineRuns = (nodeType === 'Text' && this.config.getImagePrivacy() !== ImagePrivacy.MASK_ALL && this.hasInlineMedia(nodeId, inspectorInfo)) ||
      (nodeType === 'RichEditor' && String(controlAttrs['focused'] ?? 'false') !== 'true' && this.canCaptureEditorInfo(inspectorInfo)) ?
      this.captureInlineRuns(nodeId, vpToPxScale, visible) : undefined;
    if (systemIconSvg === undefined && !isSelectArrow && !isOverlayCloseIcon && width > 0 && height > 0 && this.canCaptureImage(width, height, vpToPxScale) &&
      inlineRuns === undefined && (isNativeControl || nodeType === 'SymbolGlyph' || (nodeType === 'RichEditor' && this.canCaptureEditorInfo(inspectorInfo) &&
        !this.hasInputDescendant(node, MAX_TEXT_DESCENDANT_SEARCH_DEPTH)) || (nodeType === 'Text' &&
        this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_ALL && this.hasInlineMedia(nodeId, inspectorInfo)))) {
      const info = (inspectorInfo ?? {}) as Record<string, Object>;
      const attrs = (info['$attrs'] ?? info) as Record<string, Object>;
      const editorContent = nodeType === 'RichEditor' || nodeType === 'Text' ? this.readEditorContentSignature(nodeId) : null;
      const control = isNativeControl ? this.controls.sample(nodeId, nodeType, inspectorInfo, this.captureTimestamp, visible) : null;
      this.activeComponentAnimations = this.activeComponentAnimations || control?.active === true;
      const signature = `${control?.signature ?? editorContent ?? JSON.stringify(attrs).substring(0, 16384)}|${width}|${height}|${vpToPxScale}|${String(attrs['focused'] ?? '')}|${String(attrs['backgroundColor'] ?? '')}|` +
        `${String(attrs['content'] ?? '').substring(0, 16384)}|${String(attrs['fontColor'] ?? '')}|` +
        `${String(attrs['fontSize'] ?? '')}|${String(attrs['fontWeight'] ?? '')}|` +
        `${String(attrs['fontFamily'] ?? '')}|${String(attrs['fontStyle'] ?? '')}|${String(attrs['textAlign'] ?? '')}`;
      const state = this.rasters.request(visible ? this.rasterContext : null, nodeId, this.readComponentId(node), signature,
        width * height * vpToPxScale * vpToPxScale, nodeType === 'RichEditor' || isNativeControl ? 1048576 : 262144,
        editorContent !== null || isNativeControl);
      componentRasterKey = state.key;
      this.activeComponentAnimations = this.activeComponentAnimations || state.pending;
    }
    if (width > 0 && height > 0) {
      output.push({
        id: this.toProtocolId(nodeId),
        x,
        y,
        width,
        height,
        componentId: this.readComponentId(node),
        nodeType,
        systemIconSvg,
        systemIconZIndex,
        calendarTheme: nodeType === 'CalendarDialog' ?
          this.calendarFrames.captureTheme(this.rasterContext, vpToPxScale, this.captureTimestamp) : undefined,
        inspectorInfo,
        shouldCaptureAsText: inlineRuns === undefined && this.shouldCaptureAsText(node, nodeType, inspectorInfo),
        webViewSlotId: nodeType === 'Web' ?
          FTSessionReplayBridgeRegistry.getWebReplaySlotId(this.readComponentId(node)) || undefined : undefined,
        isSelectArrow,
        isPopupSurface: parentType === 'Popup' && nodeType === 'Column' ? true : undefined,
        isOverlayCloseIcon: isOverlayCloseIcon ? true : undefined,
        isNativeModalSurface: isNativeModalSurface && modalProjection !== undefined ? true : undefined,
        componentRasterKey,
        videoState,
        controlState: motion?.value,
        controlPoints: pattern?.points,
        controlPointer: pattern?.pointer,
        inlineRuns,
        controlParentId: isFrameControl && (nodeType === 'Checkbox' || nodeType === 'CheckboxGroup') ?
          this.toProtocolId(parentId) : undefined,
        selectLabelOwnerId: nodeType === 'Text' && parentType === 'Row' && grandparentType === 'Select' ?
          this.toProtocolId(grandparentId) : undefined,
        buttonLabelOwnerId: nodeType === 'Text' && (parentType === 'Button' || parentType === 'Toggle') ?
          this.toProtocolId(parentId) : undefined,
        fontWeightOwnerId,
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
    let textX: number | undefined = undefined;
    if (nodeType === 'Marquee' && child !== null) {
      try {
        const textWidth = child.getMeasuredSize().width / vpToPxScale;
        const localX = child.getPositionToParent().x;
        const nativeOffset = child.getPositionToWindowWithTransform().x + sceneOffsetX - x - localX;
        const visible = this.intersectClipRects(ancestorClip, bounds);
        const sample = this.marquee.sample(nodeId, inspectorInfo, width, textWidth, vpToPxScale,
          this.captureTimestamp, nativeOffset, visible !== null && opacity > 0 && output.length < nodeBudget);
        textX = x + localX + sample.offset;
        this.activeComponentAnimations = this.activeComponentAnimations || sample.active;
      } catch (_) { textX = x; }
    }
    const childFontWeightOwnerId = this.isFontWeightOwner(nodeType) ? this.toProtocolId(nodeId) : fontWeightOwnerId;
    while (child !== null && output.length < nodeBudget) {
      // A completed Text raster already contains its inline image children.
      if (!(componentRasterKey !== undefined && this.isMediaNode(nodeType) && nodeType !== 'Video') &&
        inlineRuns === undefined && nodeType !== 'RichEditor' && !(nodeType === 'Button' && hasNativeLabel) &&
        !(nodeType === 'Radio' && !String(controlAttrs['indicatorType'] ?? 'TICK').toUpperCase().includes('CUSTOM')) &&
        ((nodeType !== 'Text' && !this.controls.isSupported(nodeType)) || componentRasterKey === undefined)) {
        this.appendLightPreOrder(child, vpToPxScale, output, false, childClip, opacity, sceneOffsetX, sceneOffsetY,
          excludedIds, nodeBudget, nodeType, parentType, nodeId, parentId, textX, modalProjection,
          childFontWeightOwnerId);
      }
      try {
        child = child.getNextSibling();
      } catch (_) {
        return;
      }
    }
  }

  /** Default AlertDialog/ActionSheet scale about the content centre during entry and exit. */
  private readNativeModalProjection(node: FrameNode, vpToPxScale: number): ReplayNativeModalProjection | undefined {
    try {
      const layout = node.getPositionToWindow();
      const drawn = node.getPositionToWindowWithTransform();
      const width = node.getMeasuredSize().width / vpToPxScale;
      // The centre-anchored horizontal displacement exposes the system scale
      // even on runtimes whose Inspector reports an empty scale object.
      const scale = 1 - 2 * (drawn.x - layout.x) / width;
      if (width <= 0 || !Number.isFinite(scale) || scale < 0.5 || scale > 1.05 ||
        !Number.isFinite(layout.x) || !Number.isFinite(layout.y) || !Number.isFinite(drawn.x) || !Number.isFinite(drawn.y)) return undefined;
      if (Math.abs(scale - 1) > 0.001 || Math.abs(drawn.y - layout.y) > 0.01) this.activeComponentAnimations = true;
      return { x: layout.x, y: layout.y, drawnX: drawn.x, drawnY: drawn.y, scale };
    } catch (_) { return undefined; }
  }

  private hasInlineMedia(nodeId: number, inspector: Object | null): boolean {
    const info = (inspector ?? {}) as Record<string, Object>;
    const attrs = (info['$attrs'] ?? info) as Record<string, Object>;
    const images = attrs['imageNodes'];
    if (Array.isArray(images) && images.length > 0) return true;
    if (this.inlineMediaOwners === null) {
      this.inlineMediaOwners = new Set();
      try {
        const tree = this.rasterContext?.getFilteredInspectorTree(['id']) ?? '';
        if (tree.length > 0 && tree.length <= MAX_OVERLAY_TREE_BYTES) {
          this.readInlineMediaDescriptors(JSON.parse(tree) as Record<string, Object>, 0, 0, this.inlineMediaOwners, [0]);
        }
      } catch (_) {}
    }
    return this.inlineMediaOwners.has(nodeId);
  }

  /** Virtual editor Span content is used only as a bounded refresh signature, never emitted as Inspector data. */
  private readEditorContentSignature(id: number): string | null {
    if (this.editorContentSignatures === null) {
      try {
        const tree = this.rasterContext?.getFilteredInspectorTree(['id', 'content', 'src', 'fontSize', 'fontColor', 'fontWeight', 'font', 'fontFamily', 'fontStyle',
          'letterSpacing', 'lineHeight', 'decoration', 'width', 'height', 'symbolColor', 'symbolColorList', 'symbolId']) ?? '';
        if (tree.length === 0 || tree.length > MAX_OVERLAY_TREE_BYTES) return null;
        this.editorContentSignatures = new Map();
        this.inlineTextRuns = new Map();
        this.readEditorDescriptors(JSON.parse(tree) as Record<string, Object>, 0, 0, this.editorContentSignatures, [0]);
      } catch (_) { return null; }
    }
    return this.editorContentSignatures.get(id) ?? null;
  }

  private captureInlineRuns(id: number, scale: number, visible: boolean): Array<ReplayInlineRun> | undefined {
    this.readEditorContentSignature(id);
    const descriptors = this.inlineTextRuns?.get(id);
    if (descriptors === undefined || descriptors === null || descriptors.length === 0 || descriptors.length > 64) return undefined;
    const runs: Array<ReplayInlineRun> = [];
    for (const descriptor of descriptors) {
      const run: ReplayInlineRun = { id: descriptor.id, nodeType: descriptor.nodeType,
        inspectorInfo: descriptor.inspectorInfo, text: descriptor.text, fontWeightParentId: descriptor.fontWeightParentId };
      if (run.nodeType !== 'Span') {
        try {
          const image = this.rasterContext?.getFrameNodeByUniqueId(run.id);
          if (image === null || image === undefined || !image.isAttached()) return undefined;
          const size = image.getMeasuredSize();
          run.width = this.roundReplayMetric(size.width / scale);
          run.height = this.roundReplayMetric(size.height / scale);
          if (run.width <= 0 || run.height <= 0) return undefined;
          if (this.canCaptureImage(run.width, run.height, scale)) {
            const signature = `${JSON.stringify(run.inspectorInfo)}|${run.width}|${run.height}|${scale}`;
            const state = this.rasters.request(visible ? this.rasterContext : null, run.id, this.readComponentId(image), signature,
              size.width * size.height);
            run.componentRasterKey = state.key;
            this.activeComponentAnimations = this.activeComponentAnimations || state.pending;
          }
        } catch (_) { return undefined; }
      }
      runs.push(run);
    }
    return runs;
  }

  private readEditorDescriptors(node: Record<string, Object>, owner: number, depth: number,
    signatures: Map<number, string>, count: Array<number>, parentSpanId?: number): void {
    if (depth > 64 || count[0]++ > 4096) return;
    if ((node['$type'] === 'RichEditor' || node['$type'] === 'Text') && typeof node['$ID'] === 'number') {
      owner = node['$ID'] as number;
      signatures.set(owner, '');
      this.inlineTextRuns?.set(owner, []);
      parentSpanId = undefined;
    }
    if (owner > 0) {
      const attrs = (node['$attrs'] ?? {}) as Record<string, Object>;
      let signature = `${node['$type']}|${node['$ID']}|`;
      for (const key of ['content', 'src', 'fontSize', 'fontColor', 'fontWeight', 'fontFamily', 'fontStyle',
        'letterSpacing', 'lineHeight', 'decoration', 'width', 'height', 'symbolColor', 'symbolColorList', 'symbolId']) signature += `${String(attrs[key] ?? '').substring(0, 4096)}|`;
      signature += `${JSON.stringify(attrs['font'] ?? '').substring(0, 4096)}|${parentSpanId ?? ''}|`;
      signatures.set(owner, ((signatures.get(owner) ?? '') + signature).substring(0, 16384));
      const type = String(node['$type'] ?? '');
      const runs = this.inlineTextRuns?.get(owner);
      if (type === 'SymbolSpan' || type === 'CustomSpan' || type === 'BuilderSpan') this.inlineTextRuns?.set(owner, null);
      else if (runs !== undefined && runs !== null && ['Span', 'ImageSpan', 'Image'].includes(type)) {
        const id = node['$ID'];
        const content = typeof attrs['content'] === 'string' ? attrs['content'] as string : '';
        if (typeof id !== 'number' || runs.length >= 64 || content.length > 4096) this.inlineTextRuns?.set(owner, null);
        else {
          runs.push({ id, nodeType: type, inspectorInfo: attrs, text: content, fontWeightParentId: parentSpanId });
          if (type === 'Span') parentSpanId = id;
        }
        if (type === 'ImageSpan' || type === 'Image') return;
      }
    }
    const children = node['$children'];
    if (Array.isArray(children)) for (const child of children as Array<Object>) {
      if (child !== null && typeof child === 'object') this.readEditorDescriptors(child as Record<string, Object>, owner, depth + 1, signatures, count, parentSpanId);
    }
  }

  private readInlineMediaDescriptors(info: Record<string, Object>, owner: number, depth: number,
    owners: Set<number>, count: Array<number>): void {
    if (depth > 64 || count[0]++ > 4096) return;
    const type = info['$type'];
    const id = info['$ID'];
    if (type === 'Text' && typeof id === 'number') owner = id;
    if (owner > 0 && (type === 'SymbolSpan' || type === 'ImageSpan' || type === 'Image')) owners.add(owner);
    const children = info['$children'];
    if (!Array.isArray(children)) return;
    for (const child of children as Array<Object>) {
      if (child !== null && typeof child === 'object') {
        this.readInlineMediaDescriptors(child as Record<string, Object>, owner, depth + 1, owners, count);
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
    vpToPxScale: number,
    isSelectArrow: boolean = false,
    selectLabel: string | null = null
  ): ReplayWireframe {
    if (isSelectArrow) {
      return this.createShapeWireframe(id, x, y, width, height, componentId, nodeType, inspector, false, vpToPxScale);
    }
    if (shouldCaptureAsText) {
      return this.createTextWireframe(id, x, y, width, height, componentId, nodeType, inspector, vpToPxScale, selectLabel);
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
    vpToPxScale: number,
    selectLabel: string | null = null
  ): ReplayTextWireframe {
    let rawText = this.readOwnInspectorString(inspector, ['text', 'content', 'value', 'label']);
    const isPlaceholder = nodeType !== 'RichEditor' && this.isInputNode(nodeType) && (rawText === null || rawText.length === 0);
    if (isPlaceholder) rawText = this.readOwnInspectorString(inspector, ['placeholder']);
    // Native Select can paint a styled label while its Text Inspector reports
    // empty content. Use only the owning Select's public value as fallback;
    // keep the child geometry/typography and apply the normal text privacy.
    if ((rawText === null || rawText.length === 0) && selectLabel !== null) rawText = selectLabel;
    const text: ReplayTextWireframe = {
      id, x, y, width, height,
      type: 'text',
      text: this.filterText(rawText, isPlaceholder ? 'Text' : nodeType, width, inspector),
      textStyle: this.createTextStyle(inspector, vpToPxScale, isPlaceholder)
    };
    const shapeStyle = this.createShapeStyle(nodeType, inspector, false, width, height, vpToPxScale);
    if (shapeStyle !== undefined) {
      text.shapeStyle = shapeStyle;
    }
    const border = this.createBorder(nodeType, inspector, vpToPxScale);
    if (border !== null) {
      text.border = border;
    }
    const textPosition = this.createTextPosition(inspector, vpToPxScale, nodeType);
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
    vpToPxScale: number,
    rasterKey?: string
  ): ReplayImageWireframe {
    const image: ReplayImageWireframe = {
      id, x, y, width, height,
      type: 'image',
      shapeStyle: this.createShapeStyle(nodeType, inspector, false, width, height, vpToPxScale),
      isEmpty: true
    };
    if (rasterKey !== undefined && this.controls.isSupported(nodeType)) {
      // The native bitmap owns the track, background, border and shadow.
      // Painting Inspector chrome beneath transparent pixels doubles alpha.
      image.shapeStyle = undefined;
    }
    const border = this.createBorder(nodeType, inspector, vpToPxScale);
    if (border !== null && (rasterKey === undefined || !this.controls.isSupported(nodeType))) {
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
    const resource = this.resolveImageResource(rasterKey ?? componentId, id, rasterKey === undefined ? inspector : null);
    if (resource === null) {
      return image;
    }
    image.resourceId = resource.token;
    // Mobile Replay constructs data:image/<mimeType>; uploaded asset metadata
    // keeps the full MIME separately. Sending image/png here doubles the prefix.
    image.mimeType = resource.mimeType.substring('image/'.length);
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
    // Divider paints its stroke, not backgroundColor. Its measured bounds
    // already include stroke width, orientation and layout scaling.
    const backgroundColor = nodeType === 'Divider' ?
      this.normalizeColor(this.readOwnInspectorString(inspector, ['color'])) ?? '#00000033' :
      this.normalizeColor(directBackground === null ? nestedBackground : directBackground);
    const reportedCornerRadius = this.readCornerRadius(inspector, vpToPxScale);
    const cornerRadius = this.resolveCornerRadius(nodeType, inspector, width, height, reportedCornerRadius);
    const opacity = this.readInspectorNumber(inspector, ['opacity']);
    const gradient = this.createGradient(inspector);
    const shadow = this.createShadow(inspector, vpToPxScale);
    const transform = this.createTransform(inspector, vpToPxScale);
    const visible = this.readVisibility(inspector);
    const selectedToggle = nodeType === 'Toggle' &&
      this.readOwnInspectorString(inspector, ['type']) === 'ToggleType.Button' &&
      this.readOwnInspectorString(inspector, ['isOn']) === 'true' ?
      this.normalizeColor(this.readOwnInspectorString(inspector, ['selectedColor'])) : null;
    const fallbackColor = selectedToggle ?? (backgroundColor === null ? this.defaultBackgroundColor(nodeType, isRoot) : backgroundColor);
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

  private appendNativeMaterialBackground(frame: ReplayShapeWireframe, inspector: string | null, isDarkMode: boolean): void {
    const background = frame.shapeStyle?.backgroundColor;
    if (background !== undefined && !background.endsWith('00')) return;
    const blur = this.readInspectorObject(inspector, ['backgroundBlurStyle']);
    if (blur === null || typeof blur['value'] !== 'string' ||
      (blur['value'] as string).toUpperCase() !== 'BLURSTYLE.COMPONENT_ULTRA_THICK') return;
    const options = this.findInspectorObject(blur, ['options']);
    const policy = options === null ? null : this.findInspectorScalar(options, ['policy']);
    if (policy?.toUpperCase().includes('ALWAYS_INACTIVE')) {
      const inactive = options === null ? null : this.normalizeColor(this.findInspectorScalar(options, ['inactiveColor']));
      if (inactive !== null) {
        const style = frame.shapeStyle ?? {};
        style.backgroundColor = inactive;
        frame.shapeStyle = style;
      }
      return;
    }
    const colorMode = (options === null ? null : this.findInspectorScalar(options, ['colorMode']))?.toLowerCase();
    const dark = colorMode?.endsWith('.dark') === true ||
      (colorMode?.endsWith('.light') !== true && isDarkMode);
    // ArkUI leaves backgroundColor transparent while Render Service paints
    // the component material. Mobile Replay has no backdrop material field;
    // use its opaque appearance so page glyphs cannot show through the panel.
    const style = frame.shapeStyle ?? {};
    style.backgroundColor = dark ? '#333333FF' : '#FFFFFFFF';
    frame.shapeStyle = style;
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
    if (this.isInputNode(nodeType) && configuredWidth === null) {
      return { color: DEFAULT_INPUT_BORDER_COLOR, width: 1 };
    }
    return null;
  }

  private createTextStyle(inspector: string | null, vpToPxScale: number, placeholder: boolean = false): ReplayTextStyle {
    let size = placeholder ? this.readInspectorNestedLength(inspector, ['placeholderFont'], ['size', 'fontSize'], vpToPxScale) : null;
    for (const key of TEXT_FONT_SIZE_KEYS) {
      if (size !== null && size > 0) break;
      size = this.readInspectorLength(inspector, [key], vpToPxScale);
    }
    if (size === null || size <= 0) size = this.readInspectorNestedLength(inspector, ['font'], ['size', 'fontSize'], vpToPxScale);
    const color = (placeholder ? this.normalizeTextColor(this.readInspectorString(inspector, ['placeholderColor'])) : null) ??
      this.readRenderedTextColor(inspector);
    const family = (placeholder ? this.readInspectorNestedString(inspector, ['placeholderFont'], ['fontFamily', 'family']) : null) ??
      this.readInspectorString(inspector, ['fontFamily']) ??
      this.readInspectorNestedString(inspector, ['font'], ['family', 'fontFamily']) ??
      this.readInspectorString(inspector, ['font']) ?? DEFAULT_FONT_FAMILY;
    // If Inspector did not expose typography, the native Text default is less
    // misleading than deriving a huge font from the node's container height.
    const style: ReplayTextStyle = {
      family: this.safeFontFamily(family),
      size: Math.max(8, Math.min(72, Math.round(size === null || size <= 0 ? 16 : size))),
      color: color === null ? DEFAULT_TEXT_COLOR : color
    };
    const weight = (placeholder ? normalizeReplayFontWeight(
      this.readInspectorNestedString(inspector, ['placeholderFont'], ['weight', 'fontWeight'])) : null) ??
      readReplayFontWeight(this.getInspectorValue(inspector));
    const fontStyle = this.normalizeFontStyle((placeholder ? this.readInspectorNestedString(inspector, ['placeholderFont'], ['style', 'fontStyle']) : null) ??
      this.readInspectorString(inspector, ['fontStyle', 'style']) ??
      this.readInspectorNestedString(inspector, ['font'], ['style', 'fontStyle']));
    const lineHeight = this.readInspectorLength(inspector, ['lineHeight'], vpToPxScale);
    const letterSpacing = this.readInspectorLength(inspector, ['letterSpacing', 'letterSpace'], vpToPxScale);
    const decoration = this.normalizeTextDecoration(
      this.readInspectorNestedString(inspector, ['textDecoration', 'decoration'], ['type']) ??
      this.readInspectorString(inspector, ['textDecoration', 'decoration']));
    if (weight !== null) style.weight = weight;
    if (fontStyle !== null) style.style = fontStyle;
    if (lineHeight !== null && lineHeight > 0) style.lineHeight = Math.round(lineHeight);
    if (letterSpacing !== null) style.letterSpacing = Math.round(letterSpacing * 100) / 100;
    if (decoration !== null) style.decoration = decoration;
    return style;
  }

  private readRenderedTextColor(inspector: string | null): string | null {
    // ArkUI propagates inherited foreground colors into each descendant's
    // RenderContext. Its Inspector foregroundColor is the painted color,
    // whereas fontColor can still contain the Text theme's default (e.g. a
    // custom Button's white label). Prefer that resolved value so we also
    // preserve explicit child overrides without guessing from parent styles.
    const foreground = this.normalizeTextColor(this.readInspectorString(inspector, ['foregroundColor']));
    if (foreground !== null) return foreground;
    return this.normalizeTextColor(this.readInspectorString(inspector, ['fontColor', 'textColor', 'color']));
  }

  private normalizeTextColor(value: string | null): string | null {
    // Color::FOREGROUND (0x00000001) references the RenderContext color; it
    // is not transparent blue. Keep this check specific to text, since other
    // visual properties and real transparent text must retain their alpha.
    if (value !== null && /^(?:#|0x)00000001$/i.test(value.trim())) return null;
    return this.normalizeColor(value);
  }

  /**
   * `textPosition` is already understood by Studio's Android wireframe
   * renderer. Supplying the native insets and alignment fixes the common
   * top-left/default-layout fallback without extending the wire protocol.
   */
  private createTextPosition(inspector: string | null, vpToPxScale: number, nodeType: string): ReplayTextPosition | undefined {
    const shorthand = this.readInspectorInsets(inspector, ['padding'], vpToPxScale);
    let top = this.readInspectorLength(inspector, ['paddingTop', 'topPadding'], vpToPxScale);
    let right = this.readInspectorLength(inspector, ['paddingRight', 'rightPadding'], vpToPxScale);
    let bottom = this.readInspectorLength(inspector, ['paddingBottom', 'bottomPadding'], vpToPxScale);
    let left = this.readInspectorLength(inspector, ['paddingLeft', 'leftPadding'], vpToPxScale);
    if (top === null && shorthand !== undefined && shorthand.top !== undefined) top = shorthand.top;
    if (right === null && shorthand !== undefined && shorthand.right !== undefined) right = shorthand.right;
    if (bottom === null && shorthand !== undefined && shorthand.bottom !== undefined) bottom = shorthand.bottom;
    if (left === null && shorthand !== undefined && shorthand.left !== undefined) left = shorthand.left;
    const blockAlignment = this.readInspectorString(inspector, ['align', 'alignment']);
    const direction = this.readInspectorString(inspector, ['textDirection', 'direction']);
    const horizontal = this.normalizeHorizontalAlignment(
      this.readInspectorString(inspector, ['textAlign', 'horizontalAlign']), direction?.toLowerCase().includes('rtl') === true
    ) ?? this.normalizeHorizontalAlignment(blockAlignment);
    const vertical = this.normalizeVerticalAlignment(
      this.readInspectorString(inspector, ['verticalAlign', 'verticalAlignment'])
    ) ?? (nodeType === 'TextArea' || nodeType === 'RichEditor' ? 'top' : null) ??
      this.normalizeBlockVerticalAlignment(blockAlignment) ??
      (nodeType === 'Text' || nodeType === 'Span' || nodeType === 'Hyperlink' ? 'center' : null);
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
      (privacy === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS && this.isSensitiveInput(nodeType, inspector) &&
        !this.canCaptureVisiblePassword(nodeType, inspector));
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

  /** Content belongs to this node, never to a nested material/style's `value`. */
  private readOwnInspectorString(inspector: string | null, keys: Array<string>): string | null {
    const object = this.getInspectorValue(inspector);
    if (object === null) return null;
    const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
    for (const key of keys) {
      const text = this.inspectorScalarToString(attrs[key]);
      if (text !== null) return text;
    }
    return null;
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
        // ArkUI serializes padding, borderRadius and font as JSON strings.
        // Decode only a requested named object, never arbitrary Inspector data.
        if (property.toLowerCase() === expected && typeof candidate === 'string') {
          const parsed = this.getInspectorValue(candidate);
          if (parsed !== null) return parsed;
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
        let candidate: Object = value[property];
        if (property.toLowerCase() === expected && typeof candidate === 'string' && candidate.trim().startsWith('[')) {
          try { candidate = JSON.parse(candidate) as Object; } catch (_) { }
        }
        if (property.toLowerCase() === expected && Array.isArray(candidate)) {
          const result: Array<string> = [];
          const values = candidate as Array<Object>;
          for (let index = 0; index < Math.min(values.length, 32); index++) {
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
    // Read the named corner object before a recursive scalar fallback. Native
    // Inspector also includes foregroundEffect.radius and shadow.radius; their
    // default zero must not replace a control's real borderRadius object.
    const radius = this.readInspectorObject(inspector, ['borderRadius', 'cornerRadius', 'radius']);
    if (radius === null) {
      return this.readInspectorLength(inspector, ['borderRadius', 'cornerRadius', 'radius'], vpToPxScale);
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
    return largest ?? this.readInspectorLength(inspector, ['borderRadius', 'cornerRadius', 'radius'], vpToPxScale);
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
    if (shorthand !== null && !shorthand.trim().startsWith('{')) {
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

  private normalizeHorizontalAlignment(value: string | null, rtl: boolean = false): 'left' | 'right' | 'center' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('right')) return 'right';
    if (normalized.includes('left')) return 'left';
    if (normalized.includes('end')) return rtl ? 'left' : 'right';
    if (normalized.includes('start')) return rtl ? 'right' : 'left';
    if (normalized.includes('center') || normalized.includes('middle') ||
      normalized.includes('top') || normalized.includes('bottom')) return 'center';
    return null;
  }

  private normalizeVerticalAlignment(value: string | null): 'top' | 'bottom' | 'center' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('bottom')) return 'bottom';
    if (normalized.includes('top')) return 'top';
    if (normalized.includes('center') || normalized.includes('middle')) return 'center';
    if (normalized.includes('end')) return 'bottom';
    if (normalized.includes('start')) return 'top';
    return null;
  }

  private normalizeBlockVerticalAlignment(value: string | null): 'top' | 'bottom' | 'center' | null {
    if (value === null) return null;
    const normalized = value.toLowerCase();
    if (normalized.includes('top')) return 'top';
    if (normalized.includes('bottom')) return 'bottom';
    // Alignment.Start/End place a block at centre-left/right. They are not
    // the top/bottom meanings of the separate VerticalAlign enum.
    if (/center|middle|start|end|left|right/.test(normalized)) return 'center';
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
    const value = this.readOwnInspectorString(inspector, ['buttonType', 'type']);
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
   * A Text/Span/Search wrapper with a text descendant is visual chrome;
   * its child owns the rendered glyphs. Representing the wrapper as a shape
   * retains its background/border while preventing duplicate rich-text runs.
   */
  private shouldCaptureAsText(node: FrameNode, nodeType: string, info: Object | null): boolean {
    if (nodeType === 'Button') {
      const object = (info ?? {}) as Record<string, Object>;
      const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
      return typeof attrs['label'] === 'string' && (attrs['label'] as string).length > 0;
    }
    if (!this.isTextNode(nodeType) || this.isButtonLikeNode(nodeType)) {
      return false;
    }
    if (nodeType === 'Text' || nodeType === 'Span' || nodeType === 'Search') {
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
        try {
          const size = child.getMeasuredSize();
          if (size.width > 0 && size.height > 0) return true;
        } catch (_) { return true; }
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
    return nodeType === 'Text' || nodeType === 'Span' || nodeType === 'Hyperlink' || nodeType === 'TextInput' ||
      nodeType === 'TextArea' || nodeType === 'Search' || nodeType === 'SearchField' || nodeType === 'RichEditor';
  }

  private isInputNode(nodeType: string): boolean {
    return nodeType === 'TextInput' || nodeType === 'TextArea' || nodeType === 'Search' ||
      nodeType === 'SearchField' || nodeType === 'RichEditor';
  }

  /**
   * `MASK_SENSITIVE_INPUTS` keeps ordinary copy replayable while never
   * revealing an input whose semantic type is absent or explicitly sensitive.
   * Unknown inputs intentionally remain masked as the privacy-safe fallback.
   */
  private isSensitiveInput(nodeType: string, inspector: string | null): boolean {
    if (!this.isInputNode(nodeType)) return false;
    const object = this.getInspectorValue(inspector);
    const attrs = object === null ? null : this.findInspectorObject(object, ['$attrs']) ?? object;
    const type = attrs === null ? null : this.inspectorScalarToString(attrs['type']);
    const semantic = ['inputType', 'contentType', 'keyboardType', 'textContentType'].map(
      (key: string): string => this.readOwnInspectorString(inspector, [key]) ?? '').join('|');
    if (nodeType === 'RichEditor') return this.readInspectorString(inspector, ['privacySensitive']) === 'true';
    const normalized = `${type ?? ''}|${semantic ?? ''}`.toLowerCase();
    if (/password|passcode|pin|email|phone|tel|number|card|bank|idcard|identity|security|verify|code/.test(normalized)) {
      return true;
    }
    const explicitType = this.readOwnInspectorString(inspector, ['inputType']) ?? type;
    return !/text|normal|default|url|nickname|name|search/.test((explicitType ?? semantic).toLowerCase());
  }

  private canCaptureVisiblePassword(nodeType: string, inspector: string | null): boolean {
    if (nodeType !== 'TextInput' || !this.config.isCaptureVisiblePasswordEnabled() ||
      this.readOwnInspectorString(inspector, ['showPassword']) !== 'true') return false;
    const type = this.readOwnInspectorString(inspector, ['inputType', 'type']);
    return type !== null && /password/i.test(type);
  }

  private canCaptureEditor(inspector: string | null): boolean {
    return this.canCaptureEditorInfo(this.getInspectorValue(inspector));
  }

  private canCaptureEditorInfo(info: Object | null): boolean {
    const object = (info ?? {}) as Record<string, Object>;
    const attrs = (object['$attrs'] ?? object) as Record<string, Object>;
    return this.config.getTextAndInputPrivacy() === TextAndInputPrivacy.MASK_SENSITIVE_INPUTS &&
      String(attrs['privacySensitive'] ?? 'false') !== 'true' &&
      String(attrs['builderSpanInfos'] ?? '').trim().length === 0;
  }

  private hasInputDescendant(node: FrameNode, depth: number): boolean {
    if (depth <= 0) return true;
    try {
      let child = node.getFirstChild();
      while (child !== null) {
        if (this.isInputNode(this.readNodeType(child)) || this.hasInputDescendant(child, depth - 1)) return true;
        child = child.getNextSibling();
      }
    } catch (_) { return true; }
    return false;
  }

  private isImageNode(nodeType: string): boolean {
    return nodeType === 'Image' || nodeType === 'ImageAnimator' || nodeType === 'PixelMap';
  }

  private isDrawingNode(type: string): boolean {
    return ['QRCode', 'Shape', 'Rect', 'Circle', 'Ellipse', 'Line', 'Polygon', 'Polyline', 'Path', 'Canvas'].includes(type);
  }

  private isMediaNode(type: string): boolean { return this.isImageNode(type) || this.isDrawingNode(type) || type === 'Video'; }

  private canCaptureMedia(type: string): boolean {
    // Canvas may paint text and QRCode encodes application text as pixels.
    return !this.isDrawingNode(type) || this.config.getTextAndInputPrivacy() !== TextAndInputPrivacy.MASK_ALL;
  }

  private captureMedia(node: FrameNode, type: string, attrs: Record<string, Object>, width: number, height: number,
    scale: number, visible: boolean): string | undefined {
    const id = node.getUniqueId();
    if (!this.canCaptureImage(width, height, scale) || !this.canCaptureMedia(type)) {
      this.mediaRasters.discard(id);
      this.videoRasters.discard(id);
      return undefined;
    }
    if (!visible || width <= 0 || height <= 0) return undefined;
    const componentId = this.readComponentId(node);
    const source = String(attrs['src'] ?? attrs['source'] ?? '');
    // Explicit bytes remain authoritative and avoid unnecessary native work.
    if (this.isImageNode(type) && (this.registeredImageAssets.has(componentId) || this.registeredImageAssets.has(source.trim()) || source.startsWith('data:image/'))) return undefined;
    const area = width * height * scale * scale;
    const reduction = Math.min(1, 640 / Math.max(width * scale, height * scale));
    const options: ReplayRasterOptions = { identity: `${type}|${source}|${String(attrs['images'] ?? '')}`, scale: reduction,
      refreshIntervalMs: this.isImageNode(type) ? 2000 : 200,
      minimumIntervalMs: this.isImageNode(type) ? 2000 : 200,
      paintRevision: this.mediaPaintRevision,
      approved: (): boolean => this.canCaptureImage(width, height, scale) && this.canCaptureMedia(type) && node.isAttached() };
    const signature = `${JSON.stringify(attrs).substring(0, 16384)}|${width}|${height}|${scale}`;
    if (type === 'ImageAnimator') {
      const state = String(attrs['state'] ?? attrs['status'] ?? '').toLowerCase();
      const running = state === '1' || state.includes('running');
      options.refreshIntervalMs = running ? 200 : 0;
      options.minimumIntervalMs = 200;
      if (running) this.keepMediaSampling(200);
    }
    if (type === 'Video') {
      if (!this.videos.canCapture(componentId)) return undefined;
      const video = this.videos.state(componentId);
      options.identity = `video|${this.videos.identity(componentId)}`;
      options.refreshIntervalMs = 1000;
      options.paintRevision = 0;
      options.minimumIntervalMs = 1000;
      options.mimeType = 'image/jpeg';
      options.maxDimension = 640;
      const ui = this.rasterContext;
      options.pixels = (): Promise<image.PixelMap> => this.videos.pixels(componentId, ui, width * scale, height * scale);
      if (video?.playing === true) this.keepMediaSampling(1000);
      // onUpdate is normally once a second. Encode only at that low cadence,
      // with a final refresh when pause/seek changes the scalar state.
      const videoSignature = `${options.identity}|${video?.playing}|${Math.floor(video?.currentTime ?? 0)}|${width}|${height}`;
      const capture = this.videoRasters.request(null, id, componentId, videoSignature, area * reduction * reduction, 1048576, false, options);
      if (capture.pending) this.keepMediaSampling(200);
      return capture.key;
    }
    // Only media/drawing subtrees may become bitmaps. Never screenshot a page
    // or an arbitrary container which could contain privacy-filtered inputs.
    if (this.hasInputDescendant(node, MAX_TEXT_DESCENDANT_SEARCH_DEPTH)) return undefined;
    const capture = this.mediaRasters.request(this.rasterContext, id, componentId, signature,
      area * reduction * reduction, 1048576, true, options);
    if (capture.pending) this.keepMediaSampling(200);
    return capture.key;
  }

  private keepMediaSampling(intervalMs: number): void {
    this.activeMediaIntervalMs = this.activeMediaIntervalMs === 0 ? intervalMs : Math.min(this.activeMediaIntervalMs, intervalMs);
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

  private isFontWeightOwner(type: string): boolean {
    return ['Text', 'Button', 'Toggle', 'Select', 'TextInput', 'TextArea', 'Search', 'SearchField',
      'RichEditor', 'TextPicker', 'DatePicker', 'TimePicker', 'CalendarPicker', 'TextClock', 'TextTimer', 'Hyperlink'].includes(type);
  }

  /** Follow real native ownership within a scene, never inferred screen overlap. */
  private resolveFontWeights(nodes: Array<ArkUIReplayLightNode>): Map<number, number> {
    const sources = new Map<number, ArkUIReplayLightNode>();
    const weights = new Map<number, number>();
    for (const node of nodes) {
      sources.set(node.id, node);
      const weight = readReplayFontWeight(node.inspectorInfo);
      if (weight !== null) weights.set(node.id, weight);
    }
    for (const node of nodes) {
      if (weights.has(node.id)) continue;
      let ownerId = node.fontWeightOwnerId ?? node.buttonLabelOwnerId ?? node.selectLabelOwnerId;
      for (let depth = 0; ownerId !== undefined && depth < 32; depth++) {
        const owner = sources.get(ownerId);
        if (owner === undefined || owner.sceneLayer !== node.sceneLayer) break;
        const weight = weights.get(ownerId);
        if (weight !== undefined) { weights.set(node.id, weight); break; }
        ownerId = owner.fontWeightOwnerId ?? owner.buttonLabelOwnerId ?? owner.selectLabelOwnerId;
      }
    }
    return weights;
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
    // HarmonyOS system fonts are normally absent on the web replay host.
    // Keep their identity but explicitly choose a sans fallback instead of a browser's serif default.
    if (families.some((family: string): boolean => /^HarmonyOS Sans(?:\s|$)/i.test(family)) &&
      !families.some((family: string): boolean => family.toLowerCase() === 'sans-serif')) {
      if (families.length === 4) families.pop();
      families.push('sans-serif');
    }
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
