import { UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';

interface RasterEntry {
  signature: string;
  key: string;
  ready: boolean;
  pending: boolean;
  bytes: number;
  touched: number;
  updatedAt: number;
  attemptedAt: number;
  identity: string;
  mimeType: string;
  paintRevision: number;
}

interface RasterTouchRegion { id: number; x: number; y: number; width: number; height: number; }

export interface ReplayRasterState { key?: string; pending: boolean; }

export interface ReplayRasterOptions {
  /** Changing the media source must discard the preceding image immediately. */
  identity?: string;
  refreshIntervalMs?: number;
  minimumIntervalMs?: number;
  scale?: number;
  mimeType?: string;
  maxDimension?: number;
  paintRevision?: number;
  /** The returned PixelMap belongs to this capture and will be released. */
  pixels?: () => Promise<image.PixelMap>;
  approved?: () => boolean;
}

/** Bounded asynchronous native fallback; the collector approves component types and privacy first. */
export class ReplayComponentRaster {
  private readonly namespace: string;
  private readonly entries: Map<number, RasterEntry> = new Map();
  private generation: number = 0;
  private revision: number = 0;
  private inFlight: number = 0;
  private totalBytes: number = 0;
  private readonly touchRegions: Array<RasterTouchRegion> = [];
  private publish: (key: string, bytes: Uint8Array, mimeType: string) => void = (): void => {};
  private remove: (key: string) => void = (): void => {};

  constructor(namespace: string = 'native') { this.namespace = namespace; }

  public setCallbacks(publish: (key: string, bytes: Uint8Array, mimeType: string) => void, remove: (key: string) => void): void {
    this.publish = publish;
    this.remove = remove;
  }

  public clear(): void {
    this.generation++;
    this.entries.forEach((entry: RasterEntry): void => { if (entry.ready) this.remove(entry.key); });
    this.entries.clear();
    this.totalBytes = 0;
    this.touchRegions.length = 0;
  }

  public beginFrame(): void { this.touchRegions.length = 0; }

  public isCapturing(): boolean { return this.inFlight > 0; }

  public observeTouchRegion(id: number, x: number, y: number, width: number, height: number): void {
    if (this.touchRegions.length < 32) this.touchRegions.push({ id, x, y, width, height });
  }

  /** Cursor, selection and internal scrolling can change without changing text. */
  public touch(x: number, y: number): void {
    for (let index = this.touchRegions.length - 1; index >= 0; index--) {
      const region = this.touchRegions[index];
      if (x < region.x || y < region.y || x > region.x + region.width || y > region.y + region.height) continue;
      const entry = this.entries.get(region.id);
      if (entry !== undefined) entry.signature = '';
      return;
    }
  }

  public request(uiContext: UIContext | null, id: number, componentId: string, signature: string,
    physicalArea: number, maxPhysicalArea: number = 262144, retryOnThrottle: boolean = false,
    options: ReplayRasterOptions = {}): ReplayRasterState {
    let entry = this.entries.get(id);
    const identity = options.identity ?? '';
    if (entry !== undefined && entry.identity !== identity) {
      if (entry.ready) this.remove(entry.key);
      this.totalBytes -= entry.bytes;
      this.entries.delete(id);
      entry = undefined;
    }
    const refresh = options.refreshIntervalMs ?? 0;
    const age = entry === undefined ? Infinity : Date.now() - entry.attemptedAt;
    if (entry !== undefined && entry.signature === signature && entry.paintRevision === (options.paintRevision ?? 0) &&
      (entry.pending || (entry.ready && (refresh <= 0 || age < refresh)) || (!entry.ready && age < 1000))) {
      entry.touched = Date.now();
      return { key: entry.ready ? entry.key : undefined, pending: entry.pending };
    }
    const key = entry?.ready === true ? entry.key : undefined;
    if ((uiContext === null && options.pixels === undefined) || physicalArea <= 0 || physicalArea > Math.min(1048576, maxPhysicalArea)) return { key, pending: false };
    if (entry?.pending === true || this.inFlight >= 2) return { key, pending: true };
    if (entry !== undefined && age < (options.minimumIntervalMs ?? 0)) return { key, pending: true };
    // Layout can be reported for a frame requested by Replay itself. Retain
    // the last approved bitmap during refresh, and bound repeated packing.
    if (entry?.ready === true && Date.now() - entry.updatedAt < 200) return { key, pending: retryOnThrottle };
    if (entry === undefined) {
      while (this.entries.size >= 32) this.evictOldest();
      entry = { signature, key: `ft-replay-raster-${this.namespace}-${this.generation}-${id}-${++this.revision}`,
        ready: false, pending: true, bytes: 0, touched: Date.now(), updatedAt: 0, attemptedAt: Date.now(),
        identity, mimeType: options.mimeType ?? 'image/png', paintRevision: options.paintRevision ?? 0 };
      this.entries.set(id, entry);
    } else {
      entry.signature = signature;
      entry.pending = true;
      entry.touched = Date.now();
      entry.attemptedAt = Date.now();
      entry.paintRevision = options.paintRevision ?? 0;
    }
    this.capture(uiContext, id, componentId, entry, this.generation, options);
    return { key, pending: true };
  }

  private async capture(uiContext: UIContext | null, id: number, componentId: string, entry: RasterEntry,
    generation: number, options: ReplayRasterOptions): Promise<void> {
    this.inFlight++;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const snapshots = uiContext?.getComponentSnapshot();
      // Unique-id snapshots are public since API 15. A component id keeps
      // API 12 apps supported without depending on private native handles.
      if (options.pixels !== undefined) pixelMap = await options.pixels();
      else if (snapshots !== undefined && typeof snapshots.getWithUniqueId === 'function') {
        pixelMap = await snapshots.getWithUniqueId(id, { scale: options.scale ?? 1, waitUntilRenderFinished: true });
      } else if (snapshots !== undefined && componentId.length > 0) {
        pixelMap = await snapshots.get(componentId, { scale: options.scale ?? 1, waitUntilRenderFinished: true });
      }
      else return;
      if (generation !== this.generation || this.entries.get(id) !== entry || options.approved?.() === false) return;
      if (options.maxDimension !== undefined) {
        const info = await pixelMap.getImageInfo();
        const ratio = Math.min(1, options.maxDimension / Math.max(info.size.width, info.size.height));
        if (ratio < 1) await pixelMap.scale(ratio, ratio);
      }
      packer = image.createImagePacker();
      const packed = await packer.packing(pixelMap, { format: options.mimeType ?? 'image/png', quality: options.mimeType === 'image/jpeg' ? 65 : 100 });
      if (generation !== this.generation || this.entries.get(id) !== entry || options.approved?.() === false || packed.byteLength > 2 * 1024 * 1024) return;
      this.totalBytes -= entry.bytes;
      entry.bytes = packed.byteLength;
      this.totalBytes += entry.bytes;
      entry.ready = true;
      entry.updatedAt = Date.now();
      this.publish(entry.key, new Uint8Array(packed), entry.mimeType);
      while (this.totalBytes > 8 * 1024 * 1024) this.evictOldest();
    } catch (_) {
      // Keep the privacy-filtered wireframe fallback if the surface disappears.
    } finally {
      entry.pending = false;
      this.inFlight--;
      try { await packer?.release(); } catch (_) {}
      try { await pixelMap?.release(); } catch (_) {}
    }
  }

  public discard(id: number): void {
    const entry = this.entries.get(id);
    if (entry === undefined) return;
    if (entry.ready) this.remove(entry.key);
    this.totalBytes -= entry.bytes;
    this.entries.delete(id);
  }

  private evictOldest(): void {
    let oldestId = -1;
    let oldestTime = Infinity;
    this.entries.forEach((entry: RasterEntry, id: number): void => {
      if (entry.touched < oldestTime) { oldestId = id; oldestTime = entry.touched; }
    });
    const entry = this.entries.get(oldestId);
    if (entry === undefined) return;
    if (entry.ready) this.remove(entry.key);
    this.totalBytes -= entry.bytes;
    this.entries.delete(oldestId);
  }
}
