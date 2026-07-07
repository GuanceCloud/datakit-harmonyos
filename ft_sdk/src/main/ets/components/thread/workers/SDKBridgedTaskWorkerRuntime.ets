import { ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  SDK_WORKER_BRIDGE_RUN_TASK_COMMAND,
  SDKWorkerBridgeTaskPayload
} from '../SDKWorkerTaskBridge';
import {
  SDKWorkerBridgeRequest,
  SDKWorkerBridgeResponse,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from '../SDKWorkerProtocol';

type BridgePayloadRecord = Record<string, object | string | number | boolean | null | undefined>;

interface PendingTaskBridgeRequest {
  id: string;
  sourceRequestId: string;
  resolve: (payload: SDKWorkerPayload | undefined) => void;
  reject: (error: Error) => void;
}

export class SDKBridgedTaskWorkerRuntime {
  private readonly workerPort: ThreadWorkerGlobalScope;
  private bridgeSequence: number = 0;
  private pending: PendingTaskBridgeRequest | null = null;

  constructor(workerPort: ThreadWorkerGlobalScope) {
    this.workerPort = workerPort;
  }

  public handleBridgeResponse(message: object | string | number | boolean | null | undefined): boolean {
    if (!this.isBridgeResponse(message)) {
      return false;
    }

    const response = message as Object as SDKWorkerBridgeResponse;
    const pending = this.pending;
    if (!pending || response.id !== pending.id || response.sourceRequestId !== pending.sourceRequestId) {
      return true;
    }

    this.pending = null;
    if (response.ok) {
      pending.resolve(response.payload);
    } else {
      pending.reject(new Error(response.errorMessage || 'SDK worker task bridge failed'));
    }
    return true;
  }

  public async executeBridgedTask(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    try {
      const payload = await this.sendBridgeRequest(request);
      return {
        id: request.id,
        ok: true,
        payload
      };
    } catch (error) {
      const errorDTO = toSDKWorkerErrorDTO(error);
      const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
      return {
        id: request.id,
        ok: false,
        errorMessage: errorDTO.message,
        payload: errorPayload
      };
    }
  }

  private sendBridgeRequest(request: SDKWorkerRequest): Promise<SDKWorkerPayload | undefined> {
    if (this.pending) {
      return Promise.reject(new Error('SDK worker task bridge already has a pending request'));
    }

    this.bridgeSequence++;
    const bridgePayload: SDKWorkerBridgeTaskPayload = {
      lane: request.pool,
      name: this.readString(request.payload, 'name', request.id),
      command: request.command
    };
    const bridgeRequest: SDKWorkerBridgeRequest = {
      id: `${request.id}:taskBridge:${this.bridgeSequence}`,
      sourceRequestId: request.id,
      command: SDK_WORKER_BRIDGE_RUN_TASK_COMMAND,
      payload: bridgePayload as Object as SDKWorkerPayload
    };

    return new Promise<SDKWorkerPayload | undefined>((resolve, reject) => {
      this.pending = {
        id: bridgeRequest.id,
        sourceRequestId: bridgeRequest.sourceRequestId,
        resolve,
        reject
      };
      try {
        this.workerPort.postMessage(bridgeRequest);
      } catch (error) {
        this.pending = null;
        const normalized = error instanceof Error ? error : new Error(String(error));
        reject(normalized);
      }
    });
  }

  private readString(payload: SDKWorkerPayload | undefined, key: string, fallback: string): string {
    if (!payload || typeof payload !== 'object') {
      return fallback;
    }
    const record = payload as Object as BridgePayloadRecord;
    const value = record[key];
    return typeof value === 'string' ? value as string : fallback;
  }

  private isBridgeResponse(message: object | string | number | boolean | null | undefined): boolean {
    if (!message || typeof message !== 'object') {
      return false;
    }
    const record = message as Object as BridgePayloadRecord;
    return typeof record['id'] === 'string' &&
      typeof record['sourceRequestId'] === 'string' &&
      typeof record['ok'] === 'boolean';
  }
}
