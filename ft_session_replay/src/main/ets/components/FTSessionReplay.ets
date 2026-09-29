import { UIContext } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { FTSDK } from '@guancecloud/ft_sdk';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
import { FTSessionReplayPOC, SessionReplayCapture } from './FTSessionReplayPOC';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';
import { SessionReplaySamplingMode } from './SessionReplaySampler';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from './SessionReplaySegmentStore';
import { SessionReplayUploadResult, SessionReplayUploadRoute } from './SessionReplayUploader';
import { ReplayUploadReady, SessionReplayUploadQueue } from './SessionReplayUploadQueue';
import { SessionReplayResourceStore, SessionReplayStoredResource } from './SessionReplayResourceStore';
import { SessionReplayResourceUploadResult } from './SessionReplayResourceUploader';

/**
 * Process-wide entry point for the optional Session Replay HAR.
 *
 * The manager deliberately owns the core bridge registration. Applications can
 * enable Replay once during startup and only bind the currently visible ArkUI
 * root as pages change. This removes the POC-page-only lifecycle while keeping
 * the core SDK independent from the optional HAR.
 */
export class FTSessionReplay {
  private static instance: FTSessionReplay | null = null;

  private config: FTSessionReplayConfig = new FTSessionReplayConfig();
  private recorder: FTSessionReplayPOC | null = null;
  private retiringRecorder: FTSessionReplayPOC | null = null;
  private storage: SessionReplaySegmentStore | null = null;
  private errorSampleStorage: SessionReplaySegmentStore | null = null;
  private uploadQueue: SessionReplayUploadQueue | null = null;
  private resourceStorage: SessionReplayResourceStore | null = null;
  private errorSampleResourceStorage: SessionReplayResourceStore | null = null;
  private uploadPromise: Promise<SessionReplayUploadResult> | null = null;
  private resourceUploadInFlight: boolean = false;

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
    this.retiringRecorder = this.recorder;
    const retiring = this.recorder;
    retiring.drainWrites().then((): void => {
      if (this.retiringRecorder === retiring) this.retiringRecorder = null;
    });
    this.recorder = null;
    this.stopUploadSchedule();
  }

  public isEnabled(): boolean {
    return this.recorder !== null;
  }

  /** Binds the ArkUI root currently eligible for Replay collection. */
  public registerRoot(
    uiContext: UIContext,
    rootId: string,
    vpToPxScale: number = 1
  ): boolean {
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
  public flush(): Promise<SessionReplayUploadResult> {
    if (this.uploadPromise !== null) {
      return this.uploadPromise;
    }
    const task = this.flushPending();
    this.uploadPromise = task;
    const clear = (): void => {
      if (this.uploadPromise === task) {
        this.uploadPromise = null;
      }
    };
    task.then(clear, clear);
    return task;
  }

  private async flushPending(): Promise<SessionReplayUploadResult> {
    const uploadQueue = this.uploadQueue;
    if (uploadQueue === null) {
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
    return uploadQueue.flush();
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

  /**
   * Signals that the active ArkUI page produced a stable visual/layout change.
   * It is intentionally a signal rather than a capture call: the recorder
   * coalesces it and emits an Incremental Snapshot only if the wireframe tree
   * actually differs.
   */
  public notifyPageChanged(): void {
    this.recorder?.notifyPageChanged();
  }

  /** Defers collection until a scrolling gesture has settled. */
  public notifyScroll(): void {
    this.recorder?.notifyMotion();
  }

  /** Defers collection until an animation or page transition has settled. */
  public notifyTransition(): void {
    this.recorder?.notifyTransition();
  }

  private requireRecorder(): FTSessionReplayPOC {
    if (this.recorder === null) {
      throw new Error('Session Replay is disabled. Call enable() before capturing.');
    }
    return this.recorder;
  }

  private configureStorage(filesDir: string): void {
    this.uploadQueue?.close();
    this.uploadQueue = null;
    if (filesDir.trim().length === 0) {
      this.storage = null;
      this.errorSampleStorage = null;
      this.resourceStorage = null;
      this.errorSampleResourceStorage = null;
      return;
    }
    this.storage = new SessionReplaySegmentStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      this.config.getMaxRecordsPerSegment(),
      'segments',
      false
    );
    this.errorSampleStorage = new SessionReplaySegmentStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      this.config.getMaxRecordsPerSegment(),
      'error_segments',
      false
    );
    const segmentStorage = this.storage;
    this.resourceStorage = new SessionReplayResourceStore(filesDir, this.config.getStorageMaxBytes(), 'resources');
    this.errorSampleResourceStorage = new SessionReplayResourceStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      'error_resources'
    );
    const resourceStorage = this.resourceStorage;
    this.uploadQueue = new SessionReplayUploadQueue(
      filesDir, this.config.getStorageMaxBytes(), this.config.getMaxRecordsPerSegment(),
      async (): Promise<ReplayUploadReady> => {
        let segmentIds: Array<string> | null = null;
        const recorder = this.recorder;
        if (recorder !== null && recorder.getStorageFilesDir() === filesDir) {
          segmentIds = await recorder.listPendingSegmentIds();
        } else {
          const retiring = this.retiringRecorder;
          if (retiring !== null && retiring.getStorageFilesDir() === filesDir) await retiring.drainWrites();
        }
        return { segmentIds, route: this.getUploadRoute(), resourceTouchEpoch: resourceStorage.getTouchEpoch() };
      },
      async (id: string): Promise<boolean> => {
        const recorder = this.recorder;
        if (recorder !== null && recorder.getStorageFilesDir() === filesDir) {
          return recorder.removeUploadedSegments([id]);
        }
        const retiring = this.retiringRecorder;
        if (retiring !== null && retiring.getStorageFilesDir() === filesDir) await retiring.drainWrites();
        return segmentStorage.remove([id]);
      },
      (ids: Array<string>, touchEpoch: number): Promise<boolean> => {
        if (resourceStorage.wasTouchedAfter(ids, touchEpoch)) return Promise.resolve(false);
        return Promise.resolve(resourceStorage.remove(ids));
      }
    );
  }

  private getUploadRoute(): SessionReplayUploadRoute {
    const installed = FTSDK.getSDKConfig();
    let appVersion: string = '';
    try {
      appVersion = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).versionName;
    } catch (_) { }
    return {
      datakitUrl: installed?.getDatakitUrl() ?? '',
      datawayUrl: installed?.getDatawayUrl() ?? '',
      clientToken: installed?.getClientToken() ?? '',
      env: installed?.getEnv() ?? 'prod',
      uploadUrl: this.config.getUploadUrl(),
      appVersion
    };
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
    if (this.uploadQueue === null) {
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
        remainingResources: 0
      };
    }
    this.resourceUploadInFlight = true;
    try {
      return await this.uploadQueue.flushResources();
    } finally {
      this.resourceUploadInFlight = false;
    }
  }

  private startUploadSchedule(): void {
    this.uploadQueue?.schedule(this.config.getUploadIntervalMs());
  }

  private stopUploadSchedule(): void {
    this.uploadQueue?.schedule(0);
  }
}
