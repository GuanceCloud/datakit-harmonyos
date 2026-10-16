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
 * Session Replay configuration that preserves Android's sampling and privacy
 * vocabulary. The collector reads only whitelisted visual fields and applies
 * these policies before any text or image bytes are retained or uploaded.
 */
export class FTSessionReplayConfig {
  private sampleRate: number = 1;
  private sessionReplayOnErrorSampleRate: number = 0;
  private textAndInputPrivacy: TextAndInputPrivacy = TextAndInputPrivacy.MASK_ALL;
  private captureVisiblePassword: boolean = false;
  private imagePrivacy: ImagePrivacy = ImagePrivacy.MASK_ALL;
  private touchPrivacy: TouchPrivacy = TouchPrivacy.HIDE;
  private rumLinkKeys: Array<string> = [];
  private maxNodesPerSnapshot: number = 1500;
  // Drawing and motion are sampled at about 30 fps by default. Idle pages
  // perform no polling once the motion tail has finished.
  private snapshotIntervalMs: number = 32;
  private performanceDiagnosticsEnabled: boolean = false;
  // Mirrors Android Replay's sparse checkpoint approach: normal traffic is
  // Incremental Snapshot records; a Full Snapshot is a periodic resync only.
  private fullSnapshotIntervalMs: number = 30_000;
  // Keep sampling after a gesture/transition signal to cover inertia and the
  // final state. Drawing notifications continue sampling longer animations.
  private motionQuietPeriodMs: number = 400;
  private storageMaxBytes: number = 10 * 1024 * 1024;
  private maxRecordsPerSegment: number = 100;
  // Android starts at 2.5 seconds, then adapts normal polling between 0.5 and
  // 5 seconds. Zero opts out and leaves flush() as the only upload trigger.
  private uploadIntervalMs: number = 2_500;
  // Android's error-sampled Replay keeps only the one-minute pre-error window
  // until an error promotes it to the normal upload queue.
  private errorSampleWindowMs: number = 60_000;
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

  /**
   * Opts into plaintext for TextInput passwords explicitly shown by the page.
   * Bind showPassword to state synchronized by onSecurityStateChange.
   * Defaults to false; MASK_ALL_INPUTS and MASK_ALL always retain masking.
   */
  public setCaptureVisiblePassword(capture: boolean): FTSessionReplayConfig {
    this.captureVisiblePassword = capture;
    return this;
  }

  public isCaptureVisiblePasswordEnabled(): boolean {
    return this.captureVisiblePassword;
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
   * Controls the debounce applied to coalesced UI-change notifications. It is
   * retained under its original name for source compatibility; it no longer
   * starts a periodic full-tree collector.
   */
  public setSnapshotIntervalMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.snapshotIntervalMs = Math.max(16, Math.min(10000, Math.floor(intervalMs)));
    return this;
  }

  /** Enables bounded aggregate timing logs for profiling; disabled by default. */
  public setPerformanceDiagnosticsEnabled(enabled: boolean): FTSessionReplayConfig {
    this.performanceDiagnosticsEnabled = enabled;
    return this;
  }

  public isPerformanceDiagnosticsEnabled(): boolean {
    return this.performanceDiagnosticsEnabled;
  }

  public getSnapshotIntervalMs(): number {
    return this.snapshotIntervalMs;
  }

  /** Sets the low-frequency Full Snapshot resynchronization interval. */
  public setFullSnapshotIntervalMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.fullSnapshotIntervalMs = Math.max(5_000, Math.min(300_000, Math.floor(intervalMs)));
    return this;
  }

  public getFullSnapshotIntervalMs(): number {
    return this.fullSnapshotIntervalMs;
  }

  /** Sets the quiet window before collecting a frame after motion settles. */
  public setMotionQuietPeriodMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.motionQuietPeriodMs = Math.max(50, Math.min(5_000, Math.floor(intervalMs)));
    return this;
  }

  public getMotionQuietPeriodMs(): number {
    return this.motionQuietPeriodMs;
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
   * Sets the initial normal polling delay. Runtime scheduling adapts it between
   * 500 and 5000 ms like Android. Set zero to use `flush()` explicitly instead.
   */
  public setUploadIntervalMs(intervalMs: number): FTSessionReplayConfig {
    if (!Number.isFinite(intervalMs)) {
      return this;
    }
    this.uploadIntervalMs = intervalMs <= 0 ? 0 : Math.max(500, Math.min(5000, Math.floor(intervalMs)));
    return this;
  }

  public getUploadIntervalMs(): number {
    return this.uploadIntervalMs;
  }

  public getErrorSampleWindowMs(): number {
    return this.errorSampleWindowMs;
  }
}

function clampRate(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.min(1, value));
}
