import { FTResponseData } from '../../../../main/ets/components/http/FTResponseData';
import { HttpBuilder } from '../../../../main/ets/components/http/HttpBuilder';
import { SyncTaskManager } from '../../../../main/ets/components/SyncTaskManager';
import { DefaultSyncTaskManagerRuntime } from '../../../../main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '../../../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import {
  SDKUploadExecutePageDTO,
  SDKUploadExecutePageResultDTO,
  SDKUploadHttpConfigDTO,
  SDKUploadHttpResultDTO,
  SDKWorkerCommand,
  SDKWorkerRequest,
  SDKWorkerResponse
} from '../../../../main/ets/components/thread/SDKWorkerProtocol';
import { WaitUtils } from './WaitUtils';

/** Run every isolation step and preserve the first failure for Hypium. */
export async function runTestCleanup(steps: Array<() => void | Promise<void>>): Promise<void> {
  let firstError: Error | null = null;
  for (const step of steps) {
    try {
      await step();
    } catch (error) {
      if (firstError === null) firstError = error instanceof Error ? error : new Error(String(error));
    }
  }
  if (firstError !== null) throw firstError;
}

export interface MockUploadRequest {
  httpConfig: SDKUploadHttpConfigDTO;
  bodyString: string;
}

/** Keep the real Worker and database commit path; replace only the HTTP result. */
export class MockUploadRuntime extends DefaultSyncTaskManagerRuntime {
  public requests: MockUploadRequest[] = [];
  public responseCode: number = 200;
  public responseBody: string = '';

  takeInjectedUploadHttpResult(): SDKUploadHttpResultDTO | undefined {
    return {
      code: this.responseCode,
      message: this.responseBody,
      errorCode: '',
      elapsedMs: 1,
      softTimedOut: false
    };
  }

  async executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const response = await super.executeUploadWorkerCommand(request);
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE && response.ok && response.payload) {
      const input = request.payload as Object as SDKUploadExecutePageDTO;
      const result = response.payload as Object as SDKUploadExecutePageResultDTO;
      if (result.shouldUpload) {
        this.requests.push({ httpConfig: input.httpConfig, bodyString: result.bodyPreview });
      }
    }
    return response;
  }
}

export class MockCollector {
  private runtime: MockUploadRuntime = new MockUploadRuntime();
  private responseCode: number = 200;
  private responseBody: string = '';

  constructor(code: number = 200, body: string = "") {
    this.setResponse(code, body);
  }

  start(runtime?: MockUploadRuntime): void {
    if (runtime) {
      this.runtime = runtime;
    }
    this.runtime.responseCode = this.responseCode;
    this.runtime.responseBody = this.responseBody;
    SyncInternalTestAccess.setRuntime(this.runtime);
    SyncTaskManager.getInstance().resume();
    HttpBuilder.enableTestMode();
    HttpBuilder.setMockResponse(new FTResponseData(this.responseCode, this.responseBody));
    this.clearRequests();
  }

  async stop(): Promise<void> {
    await runTestCleanup([
      async () => {
        const manager = SyncTaskManager.getInstance();
        manager.stop();
        if (!await this.waitForUploadStopped(manager)) {
          throw new Error('MockCollector cleanup timed out waiting for the upload Worker');
        }
      },
      () => SyncInternalTestAccess.resetRuntime(),
      () => HttpBuilder.disableTestMode()
    ]);
  }

  protected async waitForUploadStopped(manager: SyncTaskManager): Promise<boolean> {
    return await WaitUtils.waitUntil(async () => {
      return !manager.getStatus().uploadLaneStatus.isRunning;
    }, 5000);
  }

  setResponse(code: number, body: string = ""): void {
    this.responseCode = code;
    this.responseBody = body;
    this.runtime.responseCode = code;
    this.runtime.responseBody = body;
    HttpBuilder.setMockResponse(new FTResponseData(code, body));
  }

  clearRequests(): void {
    this.runtime.requests = [];
    HttpBuilder.resetCapturedRequests();
  }

  getRequests(): MockUploadRequest[] {
    return this.runtime.requests.slice();
  }

  getLastPayload(): string {
    const requests = this.getRequests();
    const request = requests.length > 0 ? requests[requests.length - 1] : undefined;
    return request?.bodyString ?? "";
  }

  async waitForPayloadContaining(fragments: string[], timeoutMs: number = 5000): Promise<string> {
    let payload = "";
    const found = await WaitUtils.waitUntil(async () => {
      const requests = this.getRequests();
      for (const request of requests) {
        if (this.containsAll(request.bodyString, fragments)) {
          payload = request.bodyString;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? payload : "";
  }

  private containsAll(value: string, fragments: string[]): boolean {
    for (const fragment of fragments) {
      if (!value.includes(fragment)) {
        return false;
      }
    }
    return true;
  }
}
