import { UIContext } from '@kit.ArkUI';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
import { FTSessionReplayPOC, SessionReplayCapture } from './FTSessionReplayPOC';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';
import { SessionReplaySamplingMode } from './SessionReplaySampler';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from './SessionReplaySegmentStore';
import { SessionReplayUploader, SessionReplayUploadResult } from './SessionReplayUploader';
import { SessionReplayResourceStore, SessionReplayStoredResource } from './SessionReplayResourceStore';
import { SessionReplayResourceUploader, SessionReplayResourceUploadResult } from './SessionReplayResourceUploader';

/**
 * Process-wide entry point for the optional Session Replay HAR.
 *
 * The manager deliberately owns the core bridge registration. Applications can
 * enable Replay once during startup and only bind the currently visible ArkUI
 * root as pages change. This removes the POC-page-only lifecycle while keeping
 * the core SDK independent from the optional HAR.
 */
export class FTSessionReplay {
  private static readonly MAX_UPLOAD_RETRY_DELAY_MS: number = 60_000;
  private static instance: FTSessionReplay | null = null;

  private config: FTSessionReplayConfig = new FTSessionReplayConfig();
  private recorder: FTSessionReplayPOC | null = null;
  private storage: SessionReplaySegmentStore | null = null;
  private errorSampleStorage: SessionReplaySegmentStore | null = null;
  private uploader: SessionReplayUploader | null = null;
  private resourceStorage: SessionReplayResourceStore | null = null;
  private errorSampleResourceStorage: SessionReplayResourceStore | null = null;
  private resourceUploader: SessionReplayResourceUploader | null = null;
  private uploadTimer: number = -1;
  private uploadInFlight: boolean = false;
  private resourceUploadInFlight: boolean = false;
  private uploadRetryCount: number = 0;

  public static getInstance(): FTSessionReplay {
    if (FTSessionReplay.instance === null) {
      FTSessionReplay.instance = new FTSessionReplay();
    }
    return FTSessionReplay.instance;
  }

  /**
   * Stores configuration and starts Replay unless delayed initialization was
   * requested. Call `start()` later when `setDelayInit(true)` is used.
   */
  public init(config: FTSessionReplayConfig, filesDir: string = ''): void {
    this.disable();
    this.config = config;
    this.configureStorage(filesDir);
    if (!config.isDelayInit()) {
      this.start();
    }
  }

  /** Starts core RUM bridge registration using the configured privacy policy. */
  public start(): void {
    if (this.recorder !== null) {
      return;
    }
    const recorder = new FTSessionReplayPOC(
      this.config,
      this.storage,
      this.errorSampleStorage,
      (sessionId: string, timestamp: number): boolean => this.promoteErrorSampleResources(sessionId, timestamp),
      (context: SessionReplayContext, data: Uint8Array, mimeType: string): string | null =>
        this.queueResource(context, data, mimeType)
    );
    recorder.start();
    this.recorder = recorder;
    this.startUploadSchedule();
  }

  /** Convenience form for applications that enable Replay during startup. */
  public enable(config?: FTSessionReplayConfig, filesDir: string = ''): void {
    if (config !== undefined) {
      if (this.recorder !== null) {
        this.disable();
      }
      this.config = config;
      this.configureStorage(filesDir);
    }
    this.start();
  }

  /** Stops collection and removes the optional bridge from the core SDK. */
  public disable(): void {
    if (this.recorder === null) {
      this.stopUploadSchedule();
      return;
    }
    this.recorder.stop();
    this.recorder = null;
    this.stopUploadSchedule();
  }

  public isEnabled(): boolean {
    return this.recorder !== null;
  }

  /** Binds the ArkUI root currently eligible for Replay collection. */
  public registerRoot(uiContext: UIContext, rootId: string, vpToPxScale: number = 1): boolean {
    if (this.recorder === null) {
      return false;
    }
    this.recorder.registerRoot(uiContext, rootId, vpToPxScale);
    return true;
  }

  /** Removes the active ArkUI root without disabling global Replay. */
  public unregisterRoot(): void {
    if (this.recorder !== null) {
      this.recorder.unregisterRoot();
    }
  }

  /** Returns the latest protocol capture for diagnostics and the sample page. */
  public getLastCapture(): SessionReplayCapture | null {
    return this.recorder === null ? null : this.recorder.getLastCapture();
  }

  /** Returns the last bridge capture failure, when collection could not begin. */
  public getLastCaptureFailure(): string | null {
    return this.recorder === null ? 'Session Replay is disabled.' : this.recorder.getLastCaptureFailure();
  }

  /** Returns the bounded in-memory stream for diagnostics before persistence is enabled. */
  public getRecordedRecords(context: SessionReplayContext): Array<SessionReplayRecord> {
    return this.recorder === null ? [] : this.recorder.getRecordedRecords(context);
  }

  /** Lists valid durable segments restored from the application's private files directory. */
  public getStoredSegments(): Array<SessionReplayStoredSegment> {
    return this.storage === null ? [] : this.storage.list();
  }

  public getStorageRoot(): string | null {
    return this.storage === null ? null : this.storage.getRoot();
  }

  /** Adds a binary asset for a Replay record and returns its SHA-256 file name. */
  public queueResource(
    context: SessionReplayContext,
    data: ArrayBuffer | Uint8Array,
    mimeType: string = 'application/octet-stream'
  ): string | null {
    if (this.recorder === null || this.resourceStorage === null) {
      return null;
    }
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    const sampling = this.recorder.getSamplingMode(context.sessionId);
    if (sampling === SessionReplaySamplingMode.NONE) {
      return null;
    }
    const isDeferredErrorSample = sampling === SessionReplaySamplingMode.ERROR &&
      !this.recorder.isErrorSampledSessionPromoted(context.sessionId);
    const store = isDeferredErrorSample ? this.errorSampleResourceStorage : this.resourceStorage;
    const fileName = store === null ? null : store.put(context, bytes, mimeType);
    if (fileName !== null && isDeferredErrorSample) {
      this.errorSampleResourceStorage?.pruneBefore(Date.now() - this.config.getErrorSampleWindowMs());
    }
    return fileName;
  }

  /** Lists resource assets that still need a check/upload acknowledgement. */
  public getStoredResources(): Array<SessionReplayStoredResource> {
    return this.resourceStorage === null ? [] : this.resourceStorage.list();
  }

  public getResourceStorageRoot(): string | null {
    return this.resourceStorage === null ? null : this.resourceStorage.getRoot();
  }

  /**
   * Associates image bytes with an ArkUI Image `.id()` value or its public
   * source string. On its next snapshot the collector persists the asset,
   * inserts the resulting resource id into the image wireframe, and flushes
   * it before its replay segment.
   */
  public registerImageAsset(
    componentId: string,
    data: ArrayBuffer | Uint8Array,
    mimeType: string = 'image/png'
  ): boolean {
    return this.recorder === null ? false : this.recorder.registerImageAsset(componentId, data, mimeType);
  }

  public unregisterImageAsset(componentId: string): void {
    this.recorder?.unregisterImageAsset(componentId);
  }

  /** Lists error-sampled assets awaiting a same-session RUM Error promotion. */
  public getDeferredErrorResources(): Array<SessionReplayStoredResource> {
    return this.errorSampleResourceStorage === null ? [] : this.errorSampleResourceStorage.list();
  }

  /** Lists error-sampled segments that await a RUM Error before promotion. */
  public getDeferredErrorSegments(): Array<SessionReplayStoredSegment> {
    return this.errorSampleStorage === null ? [] : this.errorSampleStorage.list();
  }

  /**
   * Sends durable segments to the Android-compatible Replay intake. Segments
   * are deleted only after HTTP 200; any failure leaves them for a later call.
   */
  public async flush(): Promise<SessionReplayUploadResult> {
    if (this.uploader === null) {
      return {
        success: false,
        code: 0,
        message: 'Session Replay storage is not configured. Pass context.filesDir to init() or enable().',
        retryable: false,
        endpointBlocked: false,
        attemptedSegments: 0,
        uploadedSegments: 0,
        remainingSegments: 0
      };
    }
    if (this.uploadInFlight) {
      return {
        success: false,
        code: 0,
        message: 'A Session Replay upload is already in progress.',
        retryable: true,
        endpointBlocked: false,
        attemptedSegments: 0,
        uploadedSegments: 0,
        remainingSegments: this.storage === null ? 0 : this.storage.list().length
      };
    }
    this.uploadInFlight = true;
    try {
      const resources = await this.flushResourcesInternal();
      if (!resources.success) {
        return {
          success: false,
          code: resources.code,
          message: resources.message,
          retryable: resources.retryable,
          endpointBlocked: resources.endpointBlocked,
          attemptedSegments: 0,
          uploadedSegments: 0,
          remainingSegments: this.storage === null ? 0 : this.storage.list().length
        };
      }
      return await this.uploader.uploadPending();
    } finally {
      this.uploadInFlight = false;
    }
  }

  /** Explicitly drains Replay assets before their record references are uploaded. */
  public async flushResources(): Promise<SessionReplayResourceUploadResult> {
    return this.flushResourcesInternal();
  }

  /** Captures a manual Full Snapshot only while the global switch is enabled. */
  public captureFullSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture {
    return this.requireRecorder().captureFullSnapshot(uiContext, rootId, context, vpToPxScale);
  }

  /** Captures a manual structural mutation only while the global switch is enabled. */
  public captureIncrementalSnapshot(
    uiContext: UIContext,
    rootId: string,
    context: SessionReplayContext,
    vpToPxScale: number = 1
  ): SessionReplayCapture | null {
    return this.requireRecorder().captureIncrementalSnapshot(uiContext, rootId, context, vpToPxScale);
  }

  /** Records Focus for the currently active sampled native RUM View. */
  public recordFocus(hasFocus: boolean): SessionReplayCapture | null {
    return this.recorder === null ? null : this.recorder.recordActiveFocus(hasFocus);
  }

  /** Records the current native viewport in physical px for the active sampled RUM View. */
  public recordViewport(width: number, height: number, scale: number = 1): SessionReplayCapture | null {
    return this.recorder === null ? null : this.recorder.recordActiveViewport(width, height, scale);
  }

  /** Records a physical-px viewport/rotation boundary and a fresh Full Snapshot when possible. */
  public recordViewportResize(width: number, height: number): SessionReplayCapture | null {
    return this.recorder === null ? null : this.recorder.recordActiveViewportResize(width, height);
  }

  /** Records a physical-px pointer interaction for the active RUM View when touch privacy permits it. */
  public recordTouch(
    pointerEventType: 'down' | 'up' | 'move',
    pointerId: number,
    x: number,
    y: number
  ): SessionReplayCapture | null {
    return this.recorder === null ? null : this.recorder.recordActiveTouch(pointerEventType, pointerId, x, y);
  }

  private requireRecorder(): FTSessionReplayPOC {
    if (this.recorder === null) {
      throw new Error('Session Replay is disabled. Call enable() before capturing.');
    }
    return this.recorder;
  }

  private configureStorage(filesDir: string): void {
    if (filesDir.trim().length === 0) {
      this.storage = null;
      this.errorSampleStorage = null;
      this.uploader = null;
      this.resourceStorage = null;
      this.errorSampleResourceStorage = null;
      this.resourceUploader = null;
      return;
    }
    this.storage = new SessionReplaySegmentStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      this.config.getMaxRecordsPerSegment()
    );
    this.errorSampleStorage = new SessionReplaySegmentStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      this.config.getMaxRecordsPerSegment(),
      'error_segments'
    );
    this.uploader = new SessionReplayUploader(this.storage, this.config);
    this.resourceStorage = new SessionReplayResourceStore(filesDir, this.config.getStorageMaxBytes());
    this.errorSampleResourceStorage = new SessionReplayResourceStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      'error_resources'
    );
    this.resourceUploader = new SessionReplayResourceUploader(this.resourceStorage);
  }

  private promoteErrorSampleResources(sessionId: string, timestamp: number): boolean {
    if (this.resourceStorage === null || this.errorSampleResourceStorage === null) {
      return false;
    }
    return this.errorSampleResourceStorage.promoteSessionWindow(
      sessionId,
      timestamp,
      this.config.getErrorSampleWindowMs(),
      this.resourceStorage
    );
  }

  private async flushResourcesInternal(): Promise<SessionReplayResourceUploadResult> {
    if (this.resourceUploader === null) {
      return {
        success: true,
        code: 200,
        message: 'Session Replay resource storage is not configured.',
        retryable: false,
        endpointBlocked: false,
        attemptedResources: 0,
        uploadedResources: 0,
        remainingResources: 0
      };
    }
    if (this.resourceUploadInFlight) {
      return {
        success: false,
        code: 0,
        message: 'A Session Replay resource upload is already in progress.',
        retryable: true,
        endpointBlocked: false,
        attemptedResources: 0,
        uploadedResources: 0,
        remainingResources: this.resourceStorage === null ? 0 : this.resourceStorage.list().length
      };
    }
    this.resourceUploadInFlight = true;
    try {
      return await this.resourceUploader.uploadPending();
    } finally {
      this.resourceUploadInFlight = false;
    }
  }

  private startUploadSchedule(): void {
    this.stopUploadSchedule();
    this.uploadRetryCount = 0;
    if (this.uploader === null || this.config.getUploadIntervalMs() <= 0) {
      return;
    }
    this.scheduleNextUpload(this.config.getUploadIntervalMs());
  }

  private stopUploadSchedule(): void {
    if (this.uploadTimer !== -1) {
      clearTimeout(this.uploadTimer);
      this.uploadTimer = -1;
    }
  }

  private scheduleNextUpload(delayMs: number): void {
    if (this.uploader === null || this.config.getUploadIntervalMs() <= 0) {
      return;
    }
    this.stopUploadSchedule();
    this.uploadTimer = setTimeout((): void => {
      this.uploadTimer = -1;
      this.flush().then((result: SessionReplayUploadResult): void => {
        this.scheduleNextUpload(this.nextUploadDelay(result));
      }).catch((): void => {
        this.uploadRetryCount++;
        this.scheduleNextUpload(this.getRetryDelay());
      });
    }, Math.max(0, delayMs));
  }

  private nextUploadDelay(result: SessionReplayUploadResult): number {
    if (result.success) {
      this.uploadRetryCount = 0;
      return this.config.getUploadIntervalMs();
    }
    if (result.endpointBlocked) {
      this.uploadRetryCount = 0;
      return FTSessionReplay.MAX_UPLOAD_RETRY_DELAY_MS;
    }
    if (result.retryable) {
      this.uploadRetryCount++;
      return this.getRetryDelay();
    }
    this.uploadRetryCount = 0;
    return this.config.getUploadIntervalMs();
  }

  private getRetryDelay(): number {
    const multiplier = Math.pow(2, Math.max(0, this.uploadRetryCount - 1));
    return Math.min(
      FTSessionReplay.MAX_UPLOAD_RETRY_DELAY_MS,
      this.config.getUploadIntervalMs() * multiplier
    );
  }
}
