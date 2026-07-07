import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import { isSDKWorkerBridgeTaskCommand } from '../SDKWorkerTaskBridge';
import { SDKDedicatedPoolType, SDKWorkerRequest, SDKWorkerResponse } from '../SDKWorkerProtocol';
import { SDKBridgedTaskWorkerRuntime } from './SDKBridgedTaskWorkerRuntime';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.EVENT_CONSUMER, 'EventConsumerWorker', 'thread-worker');
const bridgedTaskRuntime = new SDKBridgedTaskWorkerRuntime(workerPort);

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  if (bridgedTaskRuntime.handleBridgeResponse(message.data)) {
    return;
  }

  const request = message.data as Object as SDKWorkerRequest;
  if (isSDKWorkerBridgeTaskCommand(request.command)) {
    bridgedTaskRuntime.executeBridgedTask(request).then((response: SDKWorkerResponse) => {
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
