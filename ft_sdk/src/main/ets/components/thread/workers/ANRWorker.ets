import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKANRParseRequestDTO,
  SDKDedicatedPoolType,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from '../SDKWorkerProtocol';
import { parseANREventInWorker } from './ANRWorkerOperations';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.ANR, 'ANRWorker', 'thread-worker');

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  if (request.command !== SDKWorkerCommand.ANR_PARSE_EVENT) {
    workerPort.postMessage(handleSDKWorkerRequest(request, runtimeState));
    return;
  }
  try {
    const response: SDKWorkerResponse = {
      id: request.id,
      ok: true,
      payload: parseANREventInWorker(request.payload as Object as SDKANRParseRequestDTO) as Object
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
