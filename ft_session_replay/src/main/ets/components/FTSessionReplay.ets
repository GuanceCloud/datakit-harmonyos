import { UIContext } from '@kit.ArkUI';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
import { FTSessionReplayPOC, SessionReplayCapture } from './FTSessionReplayPOC';
import { SessionReplayContext } from './SessionReplayProtocol';

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
  public init(config: FTSessionReplayConfig): void {
    this.disable();
    this.config = config;
    if (!config.isDelayInit()) {
      this.start();
    }
  }

  /** Starts core RUM bridge registration using the configured privacy policy. */
  public start(): void {
    if (this.recorder !== null) {
      return;
    }
    const recorder = new FTSessionReplayPOC(this.config);
    recorder.start();
    this.recorder = recorder;
  }

  /** Convenience form for applications that enable Replay during startup. */
  public enable(config?: FTSessionReplayConfig): void {
    if (config !== undefined) {
      if (this.recorder !== null) {
        this.disable();
      }
      this.config = config;
    }
    this.start();
  }

  /** Stops collection and removes the optional bridge from the core SDK. */
  public disable(): void {
    if (this.recorder === null) {
      return;
    }
    this.recorder.stop();
    this.recorder = null;
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
}
