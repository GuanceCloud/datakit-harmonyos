import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import ftnativecrash from 'libftnativecrash.so';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKDedicatedPoolType,
  SDKNativeCrashLogBatchDTO,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerRequest,
  SDKWorkerResponse,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from '../SDKWorkerProtocol';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState = createSDKWorkerRuntimeStateWithBackend(
  SDKDedicatedPoolType.NATIVE_CRASH_LOG,
  'NativeCrashLogWorker',
  'thread-worker'
);

interface NativeCrashLogAppendResult {
  accepted: number;
}

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  if (request.command !== SDKWorkerCommand.NATIVE_CRASH_LOG_APPEND) {
    workerPort.postMessage(handleSDKWorkerRequest(request, runtimeState));
    return;
  }

  try {
    const payload = request.payload as Object as SDKNativeCrashLogBatchDTO;
    const logs = payload && payload.logs ? payload.logs : [];
    for (let i = 0; i < logs.length; i++) {
      const log = logs[i];
      ftnativecrash.addLog(log.level, log.tag, log.message);
    }
    const result: NativeCrashLogAppendResult = { accepted: logs.length };
    const response: SDKWorkerResponse = {
      id: request.id,
      ok: true,
      payload: result as Object
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
