import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

export const BACKGROUND_LAUNCH_WORK_ID = 1001;
export const BACKGROUND_LAUNCH_WORK_ABILITY = 'BackgroundLaunchWorkSchedulerAbility';

const PREFERENCES_NAME = 'background_launch_work_status';
const KEY_PHASE = 'phase';
const KEY_WORK_ID = 'work_id';
const KEY_SCHEDULED_AT_MS = 'scheduled_at_ms';
const KEY_DELAY_MS = 'delay_ms';
const KEY_STARTED_AT_MS = 'started_at_ms';
const KEY_CLASSIFIED_AT_MS = 'classified_at_ms';
const KEY_STOPPED_AT_MS = 'stopped_at_ms';
const KEY_WORK_PID = 'work_pid';
const KEY_RUM_READY = 'rum_ready';
const KEY_APP_LAUNCH_TYPE = 'app_launch_type';
const KEY_NO_UI_CREATED = 'no_ui_created';
const KEY_MESSAGE = 'message';
const KEY_WORK_INFO = 'work_info';
const KEY_SCHEDULED_PID = 'scheduled_pid';
const KEY_EXIT_REQUESTED_AT_MS = 'exit_requested_at_ms';
const KEY_LAUNCH_REPORTED = 'launch_reported';
const KEY_REPORTED_AT_MS = 'reported_at_ms';

// Classification, RUM readiness and report callbacks can arrive in either
// order. Serialize each process's writes before refreshing Preferences.
let pendingUpdate: Promise<void> = Promise.resolve();

export interface BackgroundLaunchWorkStatus {
  phase: string;
  workId: number;
  scheduledAtMs: number;
  delayMs: number;
  startedAtMs: number;
  classifiedAtMs: number;
  stoppedAtMs: number;
  workPid: number;
  rumReady: boolean;
  appLaunchType: string;
  noUiCreated: boolean;
  message: string;
  workInfo: string;
  scheduledPid: number;
  exitRequestedAtMs: number;
  launchReported: boolean;
  reportedAtMs: number;
}

async function getFreshStore(context: Context): Promise<preferences.Preferences> {
  try {
    await preferences.removePreferencesFromCache(context, PREFERENCES_NAME);
  } catch (_error) {
    // The cache may not exist in a newly created process.
  }
  return preferences.getPreferences(context, PREFERENCES_NAME);
}

function updateStatus(
  context: Context,
  update: (store: preferences.Preferences) => Promise<void>
): Promise<void> {
  const result = pendingUpdate.then(async (): Promise<void> => {
    const store = await getFreshStore(context);
    await update(store);
    await store.flush();
  });
  pendingUpdate = result.catch((): void => {});
  return result;
}

export async function resetBackgroundLaunchWorkStatus(
  context: Context,
  delayMs: number,
  scheduledPid: number
): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.clear();
    await store.put(KEY_PHASE, 'scheduled');
    await store.put(KEY_WORK_ID, BACKGROUND_LAUNCH_WORK_ID);
    await store.put(KEY_SCHEDULED_AT_MS, Date.now());
    await store.put(KEY_DELAY_MS, delayMs);
    await store.put(KEY_SCHEDULED_PID, scheduledPid);
    await store.put(KEY_MESSAGE, 'Waiting for system scheduling');
  });
}

export async function markBackgroundLaunchExitRequested(context: Context): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_EXIT_REQUESTED_AT_MS, Date.now());
    await store.put(KEY_MESSAGE, 'Registration confirmed; exiting the current process');
  });
}

export async function markBackgroundLaunchWorkScheduleError(
  context: Context,
  message: string
): Promise<void> {
  await markBackgroundLaunchWorkError(context, 'schedule_error', message);
}

export async function markBackgroundLaunchWorkError(
  context: Context,
  phase: string,
  message: string
): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_PHASE, phase);
    await store.put(KEY_MESSAGE, message);
  });
}

export async function markBackgroundLaunchWorkStarted(
  context: Context,
  workPid: number,
  workInfo: string
): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_PHASE, 'started');
    await store.put(KEY_STARTED_AT_MS, Date.now());
    await store.put(KEY_WORK_PID, workPid);
    await store.put(KEY_RUM_READY, false);
    await store.put(KEY_LAUNCH_REPORTED, false);
    await store.put(KEY_REPORTED_AT_MS, 0);
    await store.put(KEY_CLASSIFIED_AT_MS, 0);
    await store.put(KEY_APP_LAUNCH_TYPE, 'pending');
    await store.put(KEY_NO_UI_CREATED, false);
    await store.put(KEY_MESSAGE, 'WorkSchedulerExtensionAbility.onWorkStart entered');
    await store.put(KEY_WORK_INFO, workInfo);
  });
}

export async function markBackgroundLaunchRumReady(
  context: Context,
  rumReady: boolean
): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_RUM_READY, rumReady);
    if (!Boolean(await store.get(KEY_LAUNCH_REPORTED, false))) {
      const classified = String(await store.get(KEY_APP_LAUNCH_TYPE, 'pending')) === 'background';
      await store.put(KEY_PHASE, rumReady ? (classified ? 'waiting_first_frame' : 'rum_ready') : 'rum_not_ready');
      await store.put(KEY_MESSAGE, rumReady
        ? 'SDK/RUM initialized; cold launch still requires a real first UI frame in the same process'
        : 'RUM was not initialized; configure and persist appId first');
    }
  });
}

export async function markBackgroundLaunchClassified(context: Context): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_CLASSIFIED_AT_MS, Date.now());
    await store.put(KEY_APP_LAUNCH_TYPE, 'background');
    await store.put(KEY_NO_UI_CREATED, true);
    if (!Boolean(await store.get(KEY_LAUNCH_REPORTED, false))) {
      await store.put(KEY_PHASE, Boolean(await store.get(KEY_RUM_READY, false))
        ? 'waiting_first_frame' : 'background_classified');
      await store.put(KEY_MESSAGE, 'Background origin classified; waiting for the same process first UI frame. A separate UI process cannot complete this cold launch.');
    }
  });
}

export async function markBackgroundColdLaunchReported(context: Context): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_LAUNCH_REPORTED, true);
    await store.put(KEY_REPORTED_AT_MS, Date.now());
    await store.put(KEY_PHASE, 'launch_submitted');
    await store.put(KEY_MESSAGE, 'launch_cold accepted by the RUM pipeline; upload requested. Check HTTP/backend logs for delivery.');
  });
}

export async function markBackgroundLaunchWorkStopped(
  context: Context,
  message: string
): Promise<void> {
  await updateStatus(context, async (store: preferences.Preferences): Promise<void> => {
    await store.put(KEY_STOPPED_AT_MS, Date.now());
    if (!Boolean(await store.get(KEY_LAUNCH_REPORTED, false))) {
      await store.put(KEY_PHASE, 'stopped');
      await store.put(KEY_MESSAGE, message);
    }
  });
}

export async function readBackgroundLaunchWorkStatus(
  context: Context
): Promise<BackgroundLaunchWorkStatus> {
  await pendingUpdate;
  const store = await getFreshStore(context);
  return {
    phase: String(await store.get(KEY_PHASE, 'not_scheduled')),
    workId: Number(await store.get(KEY_WORK_ID, BACKGROUND_LAUNCH_WORK_ID)),
    scheduledAtMs: Number(await store.get(KEY_SCHEDULED_AT_MS, 0)),
    delayMs: Number(await store.get(KEY_DELAY_MS, 0)),
    startedAtMs: Number(await store.get(KEY_STARTED_AT_MS, 0)),
    classifiedAtMs: Number(await store.get(KEY_CLASSIFIED_AT_MS, 0)),
    stoppedAtMs: Number(await store.get(KEY_STOPPED_AT_MS, 0)),
    workPid: Number(await store.get(KEY_WORK_PID, 0)),
    rumReady: Boolean(await store.get(KEY_RUM_READY, false)),
    appLaunchType: String(await store.get(KEY_APP_LAUNCH_TYPE, 'pending')),
    noUiCreated: Boolean(await store.get(KEY_NO_UI_CREATED, false)),
    message: String(await store.get(KEY_MESSAGE, 'No result yet')),
    workInfo: String(await store.get(KEY_WORK_INFO, '')),
    scheduledPid: Number(await store.get(KEY_SCHEDULED_PID, 0)),
    exitRequestedAtMs: Number(await store.get(KEY_EXIT_REQUESTED_AT_MS, 0)),
    launchReported: Boolean(await store.get(KEY_LAUNCH_REPORTED, false)),
    reportedAtMs: Number(await store.get(KEY_REPORTED_AT_MS, 0))
  };
}
