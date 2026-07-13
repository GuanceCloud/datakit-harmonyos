import { SDKWorkerCommand } from './SDKWorkerProtocol';

export const SDK_WORKER_MAX_RESTART_ATTEMPTS = 3;
export const SDK_WORKER_MAX_MESSAGE_REPLAY_ATTEMPTS = 1;
// Apply host-side backpressure instead of evicting unresolved messages.
export const SDK_WORKER_MAILBOX_REPLAY_CAPACITY = 512;

/**
 * Only deterministic commands without external side effects may be retried
 * after the current ThreadWorker is terminated.
 */
export function isSDKWorkerInFlightReplaySafe(command: string): boolean {
  switch (command) {
    case SDKWorkerCommand.PING:
    case SDKWorkerCommand.RESET:
    case SDKWorkerCommand.LINE_CONTEXT_UPDATE:
    case SDKWorkerCommand.EVENT_RUM_COMMAND:
    case SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION:
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH:
    case SDKWorkerCommand.EVENT_RUM_SNAPSHOT:
    case SDKWorkerCommand.LOG_ENQUEUE:
    case SDKWorkerCommand.LOG_FLUSH:
    case SDKWorkerCommand.DATA_CREATE_LINE_PROTOCOL:
    case SDKWorkerCommand.DATA_PARSE_CRASH_TEXT:
    case SDKWorkerCommand.ANR_PARSE_EVENT:
    case SDKWorkerCommand.BACKGROUND_COLLECT_METRICS:
    case SDKWorkerCommand.UPLOAD_FORMAT_BODY:
      return true;
    default:
      return false;
  }
}

/** Mailbox commands remain journaled until their matching response arrives. */
export function isSDKWorkerMailboxReplaySafe(command: string): boolean {
  switch (command) {
    case SDKWorkerCommand.PING:
    case SDKWorkerCommand.RESET:
    case SDKWorkerCommand.LINE_CONTEXT_UPDATE:
    case SDKWorkerCommand.EVENT_RUM_COMMAND:
    case SDKWorkerCommand.EVENT_RUM_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_ERROR_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_RESOURCE_COMMAND_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION:
    case SDKWorkerCommand.EVENT_RUM_COMPLETED_ACTION_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_UPDATE_BATCH:
    case SDKWorkerCommand.EVENT_RUM_COUNTER_FLUSH:
    case SDKWorkerCommand.EVENT_RUM_SNAPSHOT:
    case SDKWorkerCommand.LOG_ENQUEUE:
    case SDKWorkerCommand.LOG_FLUSH:
      return true;
    default:
      return false;
  }
}

export function isSDKWorkerExternalSideEffectCommand(command: string): boolean {
  return command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE ||
    command === SDKWorkerCommand.UPLOAD_COMMIT_PAGE ||
    command === SDKWorkerCommand.UPLOAD_CONSUME ||
    command === SDKWorkerCommand.UPLOAD_CONSUME_FINISH ||
    command === SDKWorkerCommand.UPLOAD_ROUND_FINISH ||
    command === SDKWorkerCommand.UPLOAD_SCHEDULE;
}
