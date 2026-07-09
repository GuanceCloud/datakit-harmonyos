import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import { SDKDedicatedPoolType, SDKWorkerRequest } from '../SDKWorkerProtocol';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.CRASH_FILE, 'CrashFileWorker', 'thread-worker');

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  workerPort.postMessage(handleSDKWorkerRequest(request, runtimeState));
};

workerPort.onmessageerror = (_event: MessageEvents) => {
};

workerPort.onerror = (_event: ErrorEvent) => {
};
