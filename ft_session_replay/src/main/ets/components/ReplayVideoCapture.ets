import { UIContext } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** Seconds, matching ArkUI Video's onPrepared/onUpdate/onSeeked callbacks. */
export interface ReplayVideoState {
  playing?: boolean;
  buffering?: boolean;
  currentTime?: number;
  duration?: number;
  muted?: boolean;
  playbackRate?: number;
}

/** Return a newly owned PixelMap; Replay releases it after encoding. */
export type ReplayVideoFrameProvider = (timeSeconds: number) => Promise<image.PixelMap>;

interface VideoBinding {
  source: string;
  poster?: ResourceStr;
  state: ReplayVideoState;
  provider?: ReplayVideoFrameProvider;
  revision: number;
  retryAfter?: number;
}

interface VideoDecoder {
  source: string;
  generator?: media.AVImageGenerator;
  extractor?: media.AVMetadataExtractor;
  file?: fs.File;
  busy: boolean;
  retired: boolean;
}

/** Video surfaces are never captured via ComponentSnapshot. */
export class ReplayVideoCapture {
  private readonly bindings: Map<string, VideoBinding> = new Map();
  private readonly decoders: Map<string, VideoDecoder> = new Map();
  private revision: number = 0;

  public register(componentId: string, source: string, poster?: ResourceStr): void {
    this.unregister(componentId);
    if (componentId.trim().length === 0 || this.bindings.size >= 32) return;
    this.bindings.set(componentId, { source, poster, state: {}, revision: ++this.revision });
  }

  public setProvider(componentId: string, provider: ReplayVideoFrameProvider): void {
    const decoder = this.decoders.get(componentId);
    if (decoder !== undefined) this.retire(componentId, decoder);
    let binding = this.bindings.get(componentId);
    if (binding === undefined) {
      this.register(componentId, '');
      binding = this.bindings.get(componentId);
    }
    if (binding !== undefined) { binding.provider = provider; binding.revision = ++this.revision; }
  }

  public update(componentId: string, state: ReplayVideoState): void {
    let binding = this.bindings.get(componentId);
    if (binding === undefined) {
      this.register(componentId, '');
      binding = this.bindings.get(componentId);
    }
    if (binding === undefined) return;
    const value = binding.state;
    if (typeof state.playing === 'boolean') value.playing = state.playing;
    if (typeof state.buffering === 'boolean') value.buffering = state.buffering;
    if (typeof state.muted === 'boolean') value.muted = state.muted;
    if (state.currentTime !== undefined && Number.isFinite(state.currentTime)) value.currentTime = Math.max(0, state.currentTime);
    if (state.duration !== undefined && Number.isFinite(state.duration)) value.duration = Math.max(0, state.duration);
    if (state.playbackRate !== undefined && Number.isFinite(state.playbackRate)) value.playbackRate = Math.max(0.1, Math.min(8, state.playbackRate));
  }

  public state(componentId: string): ReplayVideoState | undefined {
    const value = this.bindings.get(componentId)?.state;
    if (value === undefined) return undefined;
    return { playing: value.playing, buffering: value.buffering, currentTime: value.currentTime,
      duration: value.duration, muted: value.muted, playbackRate: value.playbackRate };
  }

  public identity(componentId: string): string { return String(this.bindings.get(componentId)?.revision ?? 0); }

  public canCapture(componentId: string): boolean {
    const value = this.bindings.get(componentId);
    return value !== undefined && (value.provider !== undefined || value.source.length > 0 || value.poster !== undefined);
  }

  public async pixels(componentId: string, ui: UIContext | null, width: number, height: number): Promise<image.PixelMap> {
    const binding = this.bindings.get(componentId);
    if (binding === undefined) throw new Error('Video is no longer registered.');
    const time = binding.state.currentTime ?? 0;
    if (time === 0 && binding.state.playing !== true && binding.poster !== undefined) {
      return this.poster(binding.poster, ui);
    }
    if (binding.provider !== undefined) return binding.provider(time);
    if ((binding.retryAfter ?? 0) > Date.now()) {
      if (binding.poster !== undefined) return this.poster(binding.poster, ui);
      throw new Error('Video decoding is backing off.');
    }
    let decoder = this.decoders.get(componentId);
    if (decoder === undefined) {
      // Bound native decoder allocation separately from the bitmap cache.
      if (this.decoders.size >= 2) throw new Error('Video decoder limit reached.');
      decoder = { source: binding.source, busy: true, retired: false };
      this.decoders.set(componentId, decoder);
      try {
        if (/^https?:\/\//i.test(binding.source)) {
          decoder.extractor = await media.createAVMetadataExtractor();
          if (typeof decoder.extractor.setUrlSource !== 'function' || typeof decoder.extractor.fetchFrameByTime !== 'function') {
            throw new Error('Network video keyframes require API 20.');
          }
          decoder.extractor.setUrlSource(binding.source);
        } else {
          const path = binding.source.startsWith('file://') ? binding.source.substring(7) : binding.source;
          if (!path.startsWith('/')) throw new Error('Use a local absolute path or a frame provider.');
          decoder.file = await fs.open(path, fs.OpenMode.READ_ONLY);
          decoder.generator = await media.createAVImageGenerator();
          decoder.generator.fdSrc = { fd: decoder.file.fd };
        }
      } catch (error) {
        binding.retryAfter = Date.now() + 5000;
        decoder.busy = false;
        this.retire(componentId, decoder);
        // A poster remains useful on old runtimes and unsupported streams.
        if (binding.poster !== undefined) return this.poster(binding.poster, ui);
        throw new Error(String(error));
      }
    }
    decoder.busy = true;
    try {
      if (decoder.retired || this.bindings.get(componentId) !== binding) throw new Error('Video source changed.');
      const scale = Math.min(1, 640 / Math.max(width, height));
      const size: media.PixelMapParams = { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
      const timeUs = Math.round(time * 1000000);
      if (decoder.extractor !== undefined) {
        return await decoder.extractor.fetchFrameByTime(timeUs, media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, size);
      }
      if (decoder.generator !== undefined) {
        return await decoder.generator.fetchFrameByTime(timeUs, media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, size);
      }
      throw new Error('Video decoder is unavailable.');
    } catch (error) {
      binding.retryAfter = Date.now() + 5000;
      this.retire(componentId, decoder);
      if (binding.poster !== undefined) return await this.poster(binding.poster, ui);
      throw new Error(String(error));
    } finally {
      decoder.busy = false;
      if (decoder.retired) this.release(decoder);
    }
  }

  private async poster(source: ResourceStr, ui: UIContext | null): Promise<image.PixelMap> {
    let decoder: image.ImageSource;
    if (typeof source === 'string') {
      if (/^https?:\/\//i.test(source)) throw new Error('Network posters use the rendered Image or registered image bytes.');
      decoder = image.createImageSource(source.startsWith('file://') ? source.substring(7) : source);
    } else {
      const bytes = await ui?.getHostContext()?.resourceManager.getMediaContent(source);
      if (bytes === undefined || bytes.byteLength > 2 * 1024 * 1024) throw new Error('Video poster is unavailable.');
      decoder = image.createImageSource(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    }
    try { return await decoder.createPixelMap(); } finally { await decoder.release(); }
  }

  public unregister(componentId: string): void {
    this.bindings.delete(componentId);
    const decoder = this.decoders.get(componentId);
    if (decoder !== undefined) this.retire(componentId, decoder);
  }

  public clear(): void {
    this.reset();
    this.bindings.clear();
  }

  public reset(): void {
    this.decoders.forEach((value: VideoDecoder, key: string): void => this.retire(key, value));
  }

  public retainVisible(componentIds: Set<string>): void {
    this.decoders.forEach((value: VideoDecoder, key: string): void => {
      if (!componentIds.has(key)) this.retire(key, value);
    });
  }

  private retire(componentId: string, decoder: VideoDecoder): void {
    decoder.retired = true;
    if (this.decoders.get(componentId) === decoder) this.decoders.delete(componentId);
    if (!decoder.busy) this.release(decoder);
  }

  private async release(decoder: VideoDecoder): Promise<void> {
    try { await decoder.extractor?.release(); } catch (_) { }
    try { await decoder.generator?.release(); } catch (_) { }
    try { if (decoder.file !== undefined) await fs.close(decoder.file); } catch (_) { }
  }
}
