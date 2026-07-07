import { SDKDedicatedPoolType } from './SDKWorkerProtocol';

export interface SDKWorkerPathInfo {
  pool: SDKDedicatedPoolType;
  workerName: string;
  sourceOptionPath: string;
  scriptUrlCandidates: string[];
}

const WORKER_BASE_SOURCE_PATH = './src/main/ets/components/thread/workers';
const WORKER_BASE_RELATIVE_PATH = './workers';
const WORKER_BASE_RUNTIME_PATH = 'ft_sdk/ets/components/thread/workers';
const WORKER_BASE_HAR_RUNTIME_PATH = '@ft_sdk/ets/components/thread/workers';
const PACKAGE_RUNTIME_PREFIX = '@guancecloud/ft_sdk/ets/components/thread/workers';

export class SDKWorkerPathResolver {
  public static readonly EVENT_CONSUMER_SOURCE_PATH =
    `${WORKER_BASE_SOURCE_PATH}/EventConsumerWorker.ets`;
  public static readonly LOG_CONSUMER_SOURCE_PATH =
    `${WORKER_BASE_SOURCE_PATH}/LogConsumerWorker.ets`;
  public static readonly DATA_PROCESS_SOURCE_PATH =
    `${WORKER_BASE_SOURCE_PATH}/DataProcessWorker.ets`;
  public static readonly DATA_UPLOAD_SOURCE_PATH =
    `${WORKER_BASE_SOURCE_PATH}/DataUploadWorker.ets`;

  public static getWorkerInfo(pool: SDKDedicatedPoolType): SDKWorkerPathInfo {
    switch (pool) {
      case SDKDedicatedPoolType.EVENT_CONSUMER:
        return SDKWorkerPathResolver.createInfo(pool, 'EventConsumerWorker');
      case SDKDedicatedPoolType.LOG_CONSUMER:
        return SDKWorkerPathResolver.createInfo(pool, 'LogConsumerWorker');
      case SDKDedicatedPoolType.DATA_PROCESS:
        return SDKWorkerPathResolver.createInfo(pool, 'DataProcessWorker');
      case SDKDedicatedPoolType.DATA_UPLOAD:
      default:
        return SDKWorkerPathResolver.createInfo(pool, 'DataUploadWorker');
    }
  }

  public static getAllSourceOptionPaths(): string[] {
    return [
      SDKWorkerPathResolver.EVENT_CONSUMER_SOURCE_PATH,
      SDKWorkerPathResolver.LOG_CONSUMER_SOURCE_PATH,
      SDKWorkerPathResolver.DATA_PROCESS_SOURCE_PATH,
      SDKWorkerPathResolver.DATA_UPLOAD_SOURCE_PATH
    ];
  }

  private static createInfo(pool: SDKDedicatedPoolType, workerName: string): SDKWorkerPathInfo {
    const fileName = `${workerName}.ets`;
    const sourceOptionPath = `${WORKER_BASE_SOURCE_PATH}/${fileName}`;
    return {
      pool,
      workerName,
      sourceOptionPath,
      scriptUrlCandidates: [
        `${WORKER_BASE_RELATIVE_PATH}/${fileName}`,
        `${WORKER_BASE_RUNTIME_PATH}/${fileName}`,
        `${WORKER_BASE_HAR_RUNTIME_PATH}/${fileName}`,
        `${PACKAGE_RUNTIME_PREFIX}/${fileName}`,
        `${WORKER_BASE_RELATIVE_PATH}/${workerName}`,
        `${WORKER_BASE_RUNTIME_PATH}/${workerName}`,
        `${WORKER_BASE_HAR_RUNTIME_PATH}/${workerName}`,
        `${PACKAGE_RUNTIME_PREFIX}/${workerName}`,
        `components/thread/workers/${fileName}`,
        sourceOptionPath,
        sourceOptionPath.substring(2)
      ]
    };
  }
}
