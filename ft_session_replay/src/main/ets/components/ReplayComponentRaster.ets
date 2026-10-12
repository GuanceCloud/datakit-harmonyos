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
}

export interface ReplayRasterState { key?: string; pending: boolean; }

/** Small, asynchronous native component fallback. Never snapshots a page or an input. */
export class ReplayComponentRaster {
  private readonly entries: Map<number, RasterEntry> = new Map();
  private generation: number = 0;
  private revision: number = 0;
  private inFlight: number = 0;
  private totalBytes: number = 0;
  private publish: (key: string, bytes: Uint8Array) => void = (): void => {};
  private remove: (key: string) => void = (): void => {};

  public setCallbacks(publish: (key: string, bytes: Uint8Array) => void, remove: (key: string) => void): void {
    this.publish = publish;
    this.remove = remove;
  }

  public clear(): void {
    this.generation++;
    this.entries.forEach((entry: RasterEntry): void => { if (entry.ready) this.remove(entry.key); });
    this.entries.clear();
    this.totalBytes = 0;
  }

  public request(uiContext: UIContext | null, id: number, componentId: string, signature: string,
    physicalArea: number): ReplayRasterState {
    let entry = this.entries.get(id);
    if (entry !== undefined && entry.signature === signature) {
      entry.touched = Date.now();
      return { key: entry.ready ? entry.key : undefined, pending: entry.pending };
    }
    const key = entry?.ready === true ? entry.key : undefined;
    if (uiContext === null || physicalArea <= 0 || physicalArea > 262144) return { key, pending: false };
    if (entry?.pending === true || this.inFlight >= 2) return { key, pending: true };
    // Layout can be reported for a frame requested by Replay itself. Retain
    // the last approved bitmap during refresh, and bound repeated packing.
    if (entry?.ready === true && Date.now() - entry.updatedAt < 200) return { key, pending: false };
    if (entry === undefined) {
      while (this.entries.size >= 32) this.evictOldest();
      entry = { signature, key: `ft-replay-raster-${this.generation}-${id}-${++this.revision}`,
        ready: false, pending: true, bytes: 0, touched: Date.now(), updatedAt: 0 };
      this.entries.set(id, entry);
    } else {
      entry.signature = signature;
      entry.pending = true;
      entry.touched = Date.now();
    }
    this.capture(uiContext, id, componentId, entry, this.generation);
    return { key, pending: true };
  }

  private async capture(uiContext: UIContext, id: number, componentId: string, entry: RasterEntry,
    generation: number): Promise<void> {
    this.inFlight++;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const snapshots = uiContext.getComponentSnapshot();
      // Unique-id snapshots are public since API 15. A component id keeps
      // API 12 apps supported without depending on private native handles.
      if (typeof snapshots.getWithUniqueId === 'function') pixelMap = await snapshots.getWithUniqueId(id);
      else if (componentId.length > 0) pixelMap = await snapshots.get(componentId);
      else return;
      if (generation !== this.generation || this.entries.get(id) !== entry) return;
      packer = image.createImagePacker();
      const packed = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
      if (generation !== this.generation || this.entries.get(id) !== entry || packed.byteLength > 2 * 1024 * 1024) return;
      this.totalBytes -= entry.bytes;
      entry.bytes = packed.byteLength;
      this.totalBytes += entry.bytes;
      entry.ready = true;
      entry.updatedAt = Date.now();
      this.publish(entry.key, new Uint8Array(packed));
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
