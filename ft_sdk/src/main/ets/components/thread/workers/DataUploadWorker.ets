import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKDedicatedPoolType,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from '../SDKWorkerProtocol';
import { DataUploadWorkerBridgeRuntime } from './DataUploadWorkerBridgeRuntime';
import { DataUploadWorkerExecutor } from './DataUploadWorkerExecutor';
import { DataUploadConsumeOptions } from './DataUploadWorkerRuntime';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.DATA_UPLOAD, 'DataUploadWorker', 'thread-worker');
const uploadBridgeRuntime = new DataUploadWorkerBridgeRuntime(workerPort);
const uploadExecutor = new DataUploadWorkerExecutor();

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  if (uploadBridgeRuntime.handleBridgeResponse(message.data)) {
    return;
  }

  const request = message.data as Object as SDKWorkerRequest;
  if (request.command === SDKWorkerCommand.UPLOAD_CONSUME) {
    handleUploadConsumeRequest(request).then((response: SDKWorkerResponse) => {
      workerPort.postMessage(response);
    });
    return;
  }

  workerPort.postMessage(handleSDKWorkerRequest(request, runtimeState));
};

workerPort.onmessageerror = (_event: MessageEvents) => {
};

workerPort.onerror = (_event: ErrorEvent) => {
};

async function handleUploadConsumeRequest(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
  try {
    const options = normalizeConsumeOptions(request.payload);
    uploadBridgeRuntime.beginRequest(request.id, options.stopped === true);
    const result = await uploadExecutor.consume(uploadBridgeRuntime, options);
    return {
      id: request.id,
      ok: true,
      payload: result as Object as SDKWorkerPayload
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
  } finally {
    uploadBridgeRuntime.endRequest(request.id);
  }
}

function normalizeConsumeOptions(payload: SDKWorkerPayload | undefined): DataUploadConsumeOptions {
  const record = payload && typeof payload === 'object' ?
    payload as Object as Record<string, object | string | number | boolean | null | undefined> :
    new Object() as Record<string, object | string | number | boolean | null | undefined>;

  return {
    taskName: typeof record['taskName'] === 'string' ? record['taskName'] as string : 'upload.poll',
    pageSize: typeof record['pageSize'] === 'number' ? record['pageSize'] as number : 50,
    syncSleepTime: typeof record['syncSleepTime'] === 'number' ? record['syncSleepTime'] as number : 0,
    errorTimeLine: typeof record['errorTimeLine'] === 'number' ? record['errorTimeLine'] as number : -1,
    stopped: record['stopped'] === true
  };
}
