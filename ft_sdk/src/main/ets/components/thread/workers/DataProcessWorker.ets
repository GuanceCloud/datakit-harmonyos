import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKBackgroundMetricsRequestDTO,
  SDKDedicatedPoolType,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from '../SDKWorkerProtocol';
import { collectBackgroundMetricsInWorker } from './BackgroundWorkerOperations';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.DATA_PROCESS, 'DataProcessWorker', 'thread-worker');

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  if (request.command !== SDKWorkerCommand.BACKGROUND_COLLECT_METRICS) {
    workerPort.postMessage(handleSDKWorkerRequest(request, runtimeState));
    return;
  }

  try {
    const response: SDKWorkerResponse = {
      id: request.id,
      ok: true,
      payload: collectBackgroundMetricsInWorker(
        request.payload as Object as SDKBackgroundMetricsRequestDTO
      ) as Object
    };
    workerPort.postMessage(response);
  } catch (error) {
    const errorDTO = toSDKWorkerErrorDTO(error);
    const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
    const response: SDKWorkerResponse = {
      id: request.id,
      ok: false,
      errorMessage: errorDTO.message,
      payload: errorPayload
    };
    workerPort.postMessage(response);
  }
};

workerPort.onmessageerror = (_event: MessageEvents) => {
};

workerPort.onerror = (_event: ErrorEvent) => {
};
