export const KEY_STRESS_SERVICE_STATE = 'stress_service_state';
export const KEY_STRESS_SERVICE_LAST_EVENT = 'stress_service_last_event';
export const KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS = 'stress_service_last_event_time_ms';
export const KEY_STRESS_SERVICE_START_ID = 'stress_service_start_id';
export const KEY_STRESS_SERVICE_REQUEST_COUNT = 'stress_service_request_count';
export const KEY_STRESS_SERVICE_STOP_REASON = 'stress_service_stop_reason';
export const KEY_STRESS_SERVICE_LAST_ERROR = 'stress_service_last_error';

export const STRESS_SERVICE_STATE_IDLE = 'idle';
export const STRESS_SERVICE_STATE_STARTING = 'starting';
export const STRESS_SERVICE_STATE_STARTED = 'started';
export const STRESS_SERVICE_STATE_KEEPALIVE = 'keepalive';
export const STRESS_SERVICE_STATE_STOPPING = 'stopping';
export const STRESS_SERVICE_STATE_STOPPED = 'stopped';
export const STRESS_SERVICE_STATE_DESTROYED = 'destroyed';
export const STRESS_SERVICE_STATE_UNSUPPORTED = 'unsupported';
export const STRESS_SERVICE_STATE_ERROR = 'error';

const DEFAULT_START_ID = -1;

function getNumberValue(key: string, defaultValue: number): number {
  const value: number | undefined = AppStorage.get<number>(key);
  if (value !== undefined) {
    return value;
  }
  return defaultValue;
}

function setServiceValue(key: string, value: string | number): void {
  AppStorage.setOrCreate(key, value);
}

export function resetStressServiceStatus(): void {
  setServiceValue(KEY_STRESS_SERVICE_STATE, STRESS_SERVICE_STATE_IDLE);
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT, 'none');
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS, 0);
  setServiceValue(KEY_STRESS_SERVICE_START_ID, DEFAULT_START_ID);
  setServiceValue(KEY_STRESS_SERVICE_REQUEST_COUNT, 0);
  setServiceValue(KEY_STRESS_SERVICE_STOP_REASON, 'none');
  setServiceValue(KEY_STRESS_SERVICE_LAST_ERROR, '');
}

export function markStressServiceStarting(): void {
  setServiceValue(KEY_STRESS_SERVICE_STATE, STRESS_SERVICE_STATE_STARTING);
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT, 'startAppServiceExtensionAbility');
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS, Date.now());
  setServiceValue(KEY_STRESS_SERVICE_STOP_REASON, 'none');
  setServiceValue(KEY_STRESS_SERVICE_LAST_ERROR, '');
}

export function markStressServiceEvent(
  state: string,
  event: string,
  startId: number = DEFAULT_START_ID,
  stopReason: string = 'none',
  errorMessage: string = ''
): void {
  setServiceValue(KEY_STRESS_SERVICE_STATE, state);
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT, event);
  setServiceValue(KEY_STRESS_SERVICE_LAST_EVENT_TIME_MS, Date.now());
  if (startId >= 0) {
    setServiceValue(KEY_STRESS_SERVICE_START_ID, startId);
  }
  if (event === 'onRequest') {
    setServiceValue(KEY_STRESS_SERVICE_REQUEST_COUNT,
      getNumberValue(KEY_STRESS_SERVICE_REQUEST_COUNT, 0) + 1);
  }
  if (stopReason.length > 0) {
    setServiceValue(KEY_STRESS_SERVICE_STOP_REASON, stopReason);
  }
  setServiceValue(KEY_STRESS_SERVICE_LAST_ERROR, errorMessage);
}

export function markStressServiceError(event: string, errorMessage: string, startId: number = DEFAULT_START_ID): void {
  markStressServiceEvent(STRESS_SERVICE_STATE_ERROR, event, startId, 'error', errorMessage);
}

export function markStressServiceUnsupported(event: string, errorMessage: string): void {
  markStressServiceEvent(STRESS_SERVICE_STATE_UNSUPPORTED, event, DEFAULT_START_ID, 'unsupported', errorMessage);
}
