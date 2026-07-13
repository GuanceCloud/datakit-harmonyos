import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import { http } from '@kit.NetworkKit';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKDataUploadWorkerRequest,
  SDKUploadWorkerHttpExecutor,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKDedicatedPoolType,
  SDKUploadHttpRequestDTO,
  SDKUploadHttpResultDTO,
  SDKWorkerRequest
} from '../SDKWorkerProtocol';
import { NetCodeStatus } from '../../http/HttpEngine';
import { awaitDataUploadHttpResult } from './DataUploadSoftTimeout';
import { createDataUploadHeaders, getDataUploadRequestBody } from './DataUploadHttpRequest';

const UPLOAD_CONNECT_TIMEOUT_MAX_MS = 60_000;
const UPLOAD_READ_TIMEOUT_MAX_MS = 60_000;
const UPLOAD_SOFT_TIMEOUT_MAX_MS = 125_000;

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.DATA_UPLOAD, 'DataUploadWorker', 'thread-worker');

class DataUploadHttpExecutor implements SDKUploadWorkerHttpExecutor {
  async execute(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO> {
    return await executeUploadHttpInWorker(request);
  }
}

const uploadHttpExecutor: SDKUploadWorkerHttpExecutor = new DataUploadHttpExecutor();

workerPort.onmessage = async (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  const response = await handleSDKDataUploadWorkerRequest(request, runtimeState, uploadHttpExecutor);
  workerPort.postMessage(response);
};

workerPort.onmessageerror = (_event: MessageEvents) => {
};

workerPort.onerror = (_event: ErrorEvent) => {
};

async function executeUploadHttpInWorker(request: SDKUploadHttpRequestDTO): Promise<SDKUploadHttpResultDTO> {
  const startedAt = Date.now();
  const httpRequest = http.createHttp();
  const softTimeoutMs = normalizeUploadTimeout(request.softTimeoutMs, UPLOAD_SOFT_TIMEOUT_MAX_MS);
  try {
    const requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      connectTimeout: normalizeUploadTimeout(request.connectTimeoutMs, UPLOAD_CONNECT_TIMEOUT_MAX_MS),
      readTimeout: normalizeUploadTimeout(request.readTimeoutMs, UPLOAD_READ_TIMEOUT_MAX_MS),
      header: createDataUploadHeaders(request)
    };
    const requestBody = getDataUploadRequestBody(request);
    if (requestBody !== undefined) {
      requestOptions.extraData = requestBody;
    }

    const requestTask: Promise<SDKUploadHttpResultDTO> = httpRequest
      .request(createUploadUrl(request), requestOptions)
      .then((response: http.HttpResponse) => {
        const result: SDKUploadHttpResultDTO = {
          code: response.responseCode,
          message: abbreviateHttpResponse(response.result.toString(), 4096),
          errorCode: '',
          elapsedMs: Math.max(0, Date.now() - startedAt),
          softTimedOut: false
        };
        return result;
      })
      .catch((error: Error) => {
        return createUploadHttpErrorResult(error, startedAt, false);
      });
    return await awaitDataUploadHttpResult(
      requestTask,
      softTimeoutMs,
      () => destroyUploadHttpRequest(httpRequest),
      () => {
        return {
          code: NetCodeStatus.FILE_TIMEOUT_CODE,
          message: `Request soft timeout after ${softTimeoutMs}ms`,
          errorCode: String(NetCodeStatus.FILE_TIMEOUT_CODE),
          elapsedMs: Math.max(0, Date.now() - startedAt),
          softTimedOut: true
        };
      }
    );
  } catch (error) {
    return createUploadHttpErrorResult(error, startedAt, false);
  } finally {
    destroyUploadHttpRequest(httpRequest);
  }
}

function createUploadUrl(request: SDKUploadHttpRequestDTO): string {
  const datakitUrl = request.datakitUrl || '';
  const datawayUrl = request.datawayUrl || '';
  const host = datakitUrl.length > 0 ? datakitUrl : datawayUrl;
  if (!request.model || request.model.trim().length === 0) {
    return host;
  }
  if (datakitUrl.length > 0) {
    return `${host}/${request.model}?precision=ns`;
  }
  return `${host}/${request.model}?token=${request.clientToken || ''}&to_headless=true&precision=ns`;
}

function createUploadHttpErrorResult(
  error: object | string | number | boolean | null | undefined,
  startedAt: number,
  softTimedOut: boolean
): SDKUploadHttpResultDTO {
  const message = error instanceof Error ? error.message : String(error);
  const normalized = message.toLowerCase();
  let code = NetCodeStatus.UNKNOWN_EXCEPTION_CODE;
  if (normalized.includes('timeout') || normalized.includes('2300028')) {
    code = NetCodeStatus.FILE_TIMEOUT_CODE;
  } else if (normalized.includes('network') || normalized.includes('2300007') || normalized.includes('2300006')) {
    code = NetCodeStatus.NETWORK_EXCEPTION_CODE;
  }
  return {
    code,
    message: abbreviateHttpResponse(message, 4096),
    errorCode: String(code),
    elapsedMs: Math.max(0, Date.now() - startedAt),
    softTimedOut
  };
}

function destroyUploadHttpRequest(httpRequest: http.HttpRequest): void {
  try {
    httpRequest.destroy();
  } catch (_) {
  }
}

function abbreviateHttpResponse(value: string, limit: number): string {
  if (!value || value.length === 0) {
    return '';
  }
  return value.length <= limit ? value : `${value.substring(0, limit)}...`;
}

function normalizeUploadTimeout(value: number, maximum: number): number {
  if (value !== value || value <= 0) {
    return maximum;
  }
  return Math.min(maximum, Math.max(1, Math.floor(value)));
}
