/** Fine-grained text and input masking values aligned with Android Replay. */
export enum TextAndInputPrivacy {
  MASK_SENSITIVE_INPUTS = 'mask_sensitive_inputs',
  MASK_ALL_INPUTS = 'mask_all_inputs',
  MASK_ALL = 'mask_all'
}

/** Fine-grained image masking values aligned with Android Replay. */
export enum ImagePrivacy {
  MASK_ALL = 'mask_all',
  MASK_LARGE_ONLY = 'mask_large_only',
  MASK_NONE = 'mask_none'
}

/** Touch masking values aligned with Android Replay. */
export enum TouchPrivacy {
  HIDE = 'hide',
  SHOW = 'show'
}

/**
 * POC configuration that preserves Android's public sampling and privacy
 * vocabulary. The collector is intentionally conservative: it never reads
 * text, input values, image data, or inspector payloads.
 */
export class FTSessionReplayConfig {
  private sampleRate: number = 1;
  private sessionReplayOnErrorSampleRate: number = 0;
  private textAndInputPrivacy: TextAndInputPrivacy = TextAndInputPrivacy.MASK_ALL;
  private imagePrivacy: ImagePrivacy = ImagePrivacy.MASK_ALL;
  private touchPrivacy: TouchPrivacy = TouchPrivacy.HIDE;
  private rumLinkKeys: Array<string> = [];
  private maxNodesPerSnapshot: number = 1500;

  public setSampleRate(sampleRate: number): FTSessionReplayConfig {
    this.sampleRate = clampRate(sampleRate);
    return this;
  }

  public getSampleRate(): number {
    return this.sampleRate;
  }

  public setSessionReplayOnErrorSampleRate(sampleRate: number): FTSessionReplayConfig {
    this.sessionReplayOnErrorSampleRate = clampRate(sampleRate);
    return this;
  }

  public getSessionReplayOnErrorSampleRate(): number {
    return this.sessionReplayOnErrorSampleRate;
  }

  public setTextAndInputPrivacy(privacy: TextAndInputPrivacy): FTSessionReplayConfig {
    this.textAndInputPrivacy = privacy;
    return this;
  }

  public getTextAndInputPrivacy(): TextAndInputPrivacy {
    return this.textAndInputPrivacy;
  }

  public setImagePrivacy(privacy: ImagePrivacy): FTSessionReplayConfig {
    this.imagePrivacy = privacy;
    return this;
  }

  public getImagePrivacy(): ImagePrivacy {
    return this.imagePrivacy;
  }

  public setTouchPrivacy(privacy: TouchPrivacy): FTSessionReplayConfig {
    this.touchPrivacy = privacy;
    return this;
  }

  public getTouchPrivacy(): TouchPrivacy {
    return this.touchPrivacy;
  }

  public enableLinkRUMKeys(keys: Array<string> | null | undefined): FTSessionReplayConfig {
    this.rumLinkKeys = keys === null || keys === undefined ? [] : keys.slice();
    return this;
  }

  public getRumLinkKeys(): Array<string> {
    return this.rumLinkKeys.slice();
  }

  public setMaxNodesPerSnapshot(maxNodes: number): FTSessionReplayConfig {
    this.maxNodesPerSnapshot = Math.max(1, Math.floor(maxNodes));
    return this;
  }

  public getMaxNodesPerSnapshot(): number {
    return this.maxNodesPerSnapshot;
  }
}

function clampRate(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.min(1, value));
}
