import worker, { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope } from '@ohos.worker';
import {
  createSDKWorkerRuntimeStateWithBackend,
  handleSDKWorkerRequest,
  SDKWorkerMessageData
} from '../SDKWorkerBusinessHandlers';
import {
  SDKDedicatedPoolType,
  SDK_EVENT_RESPONSE_SOFT_CREDITS,
  SDKWorkerCommand,
  SDKWorkerRequest,
  SDKWorkerResponse,
  SDKWorkerResponseCreditDTO
} from '../SDKWorkerProtocol';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
const runtimeState =
  createSDKWorkerRuntimeStateWithBackend(SDKDedicatedPoolType.EVENT_CONSUMER, 'EventConsumerWorker', 'thread-worker');
/**
 * A response is emitted only while the Host has credit. Computation continues
 * normally; completed responses remain FIFO here until the Host acknowledges
 * capacity. No worker-backlog hard limit is imposed at this stage.
 */
let responseCredits: number = SDK_EVENT_RESPONSE_SOFT_CREDITS;
let pendingResponses: SDKWorkerResponse[] = [];
let pendingResponseHead: number = 0;

function publishResponse(response: SDKWorkerResponse): void {
  if (pendingResponseHead < pendingResponses.length || responseCredits <= 0) {
    pendingResponses.push(response);
    return;
  }
  responseCredits--;
  workerPort.postMessage(response);
}

function grantResponseCredits(payload: SDKWorkerResponseCreditDTO | undefined): void {
  const requested = payload && payload.credits ? Math.floor(payload.credits) : 0;
  if (requested <= 0) {
    return;
  }
  responseCredits += requested;
  while (responseCredits > 0 && pendingResponseHead < pendingResponses.length) {
    const response = pendingResponses[pendingResponseHead];
    pendingResponseHead++;
    responseCredits--;
    workerPort.postMessage(response);
  }
  if (pendingResponseHead >= pendingResponses.length) {
    pendingResponses = [];
    pendingResponseHead = 0;
  }
}

workerPort.onmessage = (event: MessageEvents) => {
  const message = event as SDKWorkerMessageData;
  const request = message.data as Object as SDKWorkerRequest;
  if (request.command === SDKWorkerCommand.EVENT_RUM_RESPONSE_CREDIT) {
    grantResponseCredits(request.payload as Object as SDKWorkerResponseCreditDTO);
    return;
  }
  publishResponse(handleSDKWorkerRequest(request, runtimeState));
};

workerPort.onmessageerror = (_event: MessageEvents) => {
};

workerPort.onerror = (_event: ErrorEvent) => {
};
