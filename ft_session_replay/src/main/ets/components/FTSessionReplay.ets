import { UIContext } from '@kit.ArkUI';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
import { FTSessionReplayPOC, SessionReplayCapture } from './FTSessionReplayPOC';
import { SessionReplayContext, SessionReplayRecord } from './SessionReplayProtocol';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from './SessionReplaySegmentStore';
import { SessionReplayUploader, SessionReplayUploadResult } from './SessionReplayUploader';

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
  private storage: SessionReplaySegmentStore | null = null;
  private uploader: SessionReplayUploader | null = null;
  private uploadTimer: number = -1;
  private uploadInFlight: boolean = false;

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
    const recorder = new FTSessionReplayPOC(this.config, this.storage);
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
        attemptedSegments: 0,
        uploadedSegments: 0,
        remainingSegments: this.storage === null ? 0 : this.storage.list().length
      };
    }
    this.uploadInFlight = true;
    try {
      return await this.uploader.uploadPending();
    } finally {
      this.uploadInFlight = false;
    }
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

  private requireRecorder(): FTSessionReplayPOC {
    if (this.recorder === null) {
      throw new Error('Session Replay is disabled. Call enable() before capturing.');
    }
    return this.recorder;
  }

  private configureStorage(filesDir: string): void {
    if (filesDir.trim().length === 0) {
      this.storage = null;
      this.uploader = null;
      return;
    }
    this.storage = new SessionReplaySegmentStore(
      filesDir,
      this.config.getStorageMaxBytes(),
      this.config.getMaxRecordsPerSegment()
    );
    this.uploader = new SessionReplayUploader(this.storage, this.config);
  }

  private startUploadSchedule(): void {
    this.stopUploadSchedule();
    if (this.uploader === null || this.config.getUploadIntervalMs() <= 0) {
      return;
    }
    this.uploadTimer = setInterval((): void => {
      this.flush().then((): void => {
      }).catch((): void => {
      });
    }, this.config.getUploadIntervalMs());
  }

  private stopUploadSchedule(): void {
    if (this.uploadTimer !== -1) {
      clearInterval(this.uploadTimer);
      this.uploadTimer = -1;
    }
  }
}
