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
  private snapshotIntervalMs: number = 500;
  private storageMaxBytes: number = 10 * 1024 * 1024;
  private maxRecordsPerSegment: number = 100;
  // Android-like background draining cadence. Zero opts out and leaves flush()
  // as the only upload trigger.
  private uploadIntervalMs: number = 15_000;
  // Optional absolute Replay intake URL. When omitted, the installed core SDK's
  // DataKit or Dataway endpoint is used with Android's Replay path.
  private uploadUrl: string = '';
  private delayInit: boolean = false;

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

  /** Defers activation until the application explicitly calls `start()`. */
  public setDelayInit(delayInit: boolean): FTSessionReplayConfig {
    this.delayInit = delayInit;
    return this;
  }

  public isDelayInit(): boolean {
    return this.delayInit;
  }

  public setMaxNodesPerSnapshot(maxNodes: number): FTSessionReplayConfig {
    this.maxNodesPerSnapshot = Math.max(1, Math.floor(maxNodes));
    return this;
  }

  public getMaxNodesPerSnapshot(): number {
    return this.maxNodesPerSnapshot;
  }

  /**
   * Controls the bounded structural polling cadence for a visible ArkUI root.
   * The collector emits an Incremental Snapshot only when its wireframe tree
   * changes, so unchanged intervals do not create protocol records.
   */
  public setSnapshotIntervalMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.snapshotIntervalMs = Math.max(100, Math.min(10000, Math.floor(intervalMs)));
    return this;
  }

  public getSnapshotIntervalMs(): number {
    return this.snapshotIntervalMs;
  }

  /** Bounds all retained on-device Replay segments. Default: 10 MiB. */
  public setStorageMaxBytes(maxBytes: number): FTSessionReplayConfig {
    if (!Number.isFinite(maxBytes)) {
      return this;
    }
    this.storageMaxBytes = Math.max(1024 * 1024, Math.min(100 * 1024 * 1024, Math.floor(maxBytes)));
    return this;
  }

  public getStorageMaxBytes(): number {
    return this.storageMaxBytes;
  }

  /** Caps the number of protocol records written into one atomic segment. */
  public setMaxRecordsPerSegment(maxRecords: number): FTSessionReplayConfig {
    if (!Number.isFinite(maxRecords)) {
      return this;
    }
    this.maxRecordsPerSegment = Math.max(1, Math.min(500, Math.floor(maxRecords)));
    return this;
  }

  public getMaxRecordsPerSegment(): number {
    return this.maxRecordsPerSegment;
  }

  /**
   * Overrides the core SDK intake route for Replay records. This is useful for
   * a controlled proxy or an isolated backend verification environment.
   */
  public setUploadUrl(uploadUrl: string): FTSessionReplayConfig {
    this.uploadUrl = uploadUrl.trim();
    return this;
  }

  public getUploadUrl(): string {
    return this.uploadUrl;
  }

  /**
   * Schedules automatic draining of durable Replay segments. Set to zero to
   * disable automatic network activity and use `flush()` explicitly instead.
   */
  public setUploadIntervalMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.uploadIntervalMs = intervalMs <= 0 ? 0 : Math.max(1000, Math.min(300000, Math.floor(intervalMs)));
    return this;
  }

  public getUploadIntervalMs(): number {
    return this.uploadIntervalMs;
  }
}

function clampRate(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.min(1, value));
}
