import {
  SDKDedicatedPoolType,
  SDKWorkerBridgeRequest,
  SDKWorkerBridgeResponse,
  SDKWorkerCommand,
  SDKWorkerErrorPayload,
  SDKWorkerPayload,
  SDKWorkerRequest,
  toSDKWorkerErrorDTO,
  toSDKWorkerErrorPayload
} from './SDKWorkerProtocol';

export const SDK_WORKER_BRIDGE_RUN_TASK_COMMAND = 'sdk.bridge.runTask';

export type SDKWorkerBridgeTaskRunner = () => void | Promise<void>;
export type SDKWorkerBridgeHandler =
  (request: SDKWorkerBridgeRequest) => SDKWorkerBridgeResponse | Promise<SDKWorkerBridgeResponse>;
export type SDKDedicatedCommandRunner = () => SDKWorkerPayload | Promise<SDKWorkerPayload>;

export interface SDKWorkerBridgeTaskPayload {
  lane: string;
  name: string;
  command: string;
}

export interface SDKWorkerBridgeTaskResultPayload {
  lane: string;
  name: string;
  command: string;
  completed: boolean;
}

export function createSDKWorkerTaskRequest(
  pool: SDKDedicatedPoolType,
  command: SDKWorkerCommand,
  name: string,
  priority: number,
  payload?: SDKWorkerPayload
): SDKWorkerRequest {
  const bridgePayload: SDKWorkerBridgeTaskPayload = {
    lane: pool,
    name,
    command
  };
  return {
    id: `${command}:${name}:${Date.now()}`,
    pool,
    command,
    priority,
    createdAt: Date.now(),
    payload: payload || (bridgePayload as Object as SDKWorkerPayload)
  };
}

export function createSDKWorkerTaskBridgeHandler(
  name: string,
  command: SDKWorkerCommand,
  runner: SDKWorkerBridgeTaskRunner
): SDKWorkerBridgeHandler {
  return async (request: SDKWorkerBridgeRequest): Promise<SDKWorkerBridgeResponse> => {
    if (request.command !== SDK_WORKER_BRIDGE_RUN_TASK_COMMAND) {
      return createBridgeTaskErrorResponse(request, `Unsupported task bridge command: ${request.command}`);
    }

    try {
      await Promise.resolve(runner());
      const resultPayload: SDKWorkerBridgeTaskResultPayload = {
        lane: readBridgePayloadString(request.payload, 'lane', ''),
        name,
        command,
        completed: true
      };
      return {
        id: request.id,
        sourceRequestId: request.sourceRequestId,
        ok: true,
        payload: resultPayload as Object as SDKWorkerPayload
      };
    } catch (error) {
      return createBridgeTaskErrorResponse(request, String(error));
    }
  };
}

export function createSDKWorkerTaskFallbackRunner(
  name: string,
  command: SDKWorkerCommand,
  runner: SDKWorkerBridgeTaskRunner
): SDKDedicatedCommandRunner {
  return async (): Promise<SDKWorkerPayload> => {
    await Promise.resolve(runner());
    const resultPayload: SDKWorkerBridgeTaskResultPayload = {
      lane: '',
      name,
      command,
      completed: true
    };
    return resultPayload as Object as SDKWorkerPayload;
  };
}

export function isSDKWorkerBridgeTaskCommand(command: string): boolean {
  return command === SDKWorkerCommand.EVENT_RUN ||
    command === SDKWorkerCommand.LOG_RUN ||
    command === SDKWorkerCommand.DATA_RUN ||
    command === SDKWorkerCommand.CRASH_FILE_RUN ||
    command === SDKWorkerCommand.ANR_RUN ||
    command === SDKWorkerCommand.CUSTOM_RUN ||
    command === SDKWorkerCommand.INNER_LOG_FILE_RUN;
}

function createBridgeTaskErrorResponse(
  request: SDKWorkerBridgeRequest,
  message: string
): SDKWorkerBridgeResponse {
  const errorDTO = toSDKWorkerErrorDTO(new Error(message));
  const errorPayload: SDKWorkerErrorPayload = toSDKWorkerErrorPayload(errorDTO);
  return {
    id: request.id,
    sourceRequestId: request.sourceRequestId,
    ok: false,
    errorMessage: errorDTO.message,
    payload: errorPayload
  };
}

function readBridgePayloadString(payload: SDKWorkerPayload | undefined, key: string, fallback: string): string {
  if (!payload || typeof payload !== 'object') {
    return fallback;
  }
  const record = payload as Object as Record<string, object | string | number | boolean | null | undefined>;
  const value = record[key];
  return typeof value === 'string' ? value as string : fallback;
}
