import { batteryInfo } from '@kit.BasicServicesKit';

export const REPLAY_MIN_UPLOAD_BATTERY_SOC: number = 20;
const REPLAY_BATTERY_PLUGGED_NONE: number = 0;
const REPLAY_BATTERY_CHARGING: number = 1;
const REPLAY_BATTERY_FULL: number = 3;

/** Primitive battery snapshot used to keep the HarmonyOS-aligned rule testable. */
export interface ReplayBatteryState {
  batterySOC: number;
  chargingStatus: number;
  pluggedType: number;
  isBatteryPresent: boolean;
}

/**
 * HarmonyOS uploads above 20% or whenever external power is present, charging is
 * active/full, or the device has no battery (for example, some TVs/emulators).
 */
export function isReplayBatteryHealthy(state: ReplayBatteryState): boolean {
  // Battery enums have stable numeric wire values. Using those values here
  // also keeps this pure predicate independent of incomplete local-test mocks.
  const externallyPowered = state.pluggedType > REPLAY_BATTERY_PLUGGED_NONE;
  const charging = state.chargingStatus === REPLAY_BATTERY_CHARGING ||
    state.chargingStatus === REPLAY_BATTERY_FULL;
  return state.batterySOC > REPLAY_MIN_UPLOAD_BATTERY_SOC || externallyPowered ||
    !state.isBatteryPresent || charging;
}

/** Platform read failures are unknown state and fail open, as HarmonyOS does before its first battery broadcast. */
export function readReplayBatteryHealthy(): boolean {
  try {
    return isReplayBatteryHealthy({
      batterySOC: batteryInfo.batterySOC,
      chargingStatus: batteryInfo.chargingStatus,
      pluggedType: batteryInfo.pluggedType,
      isBatteryPresent: batteryInfo.isBatteryPresent
    });
  } catch (_) {
    return true;
  }
}

/** Unknown network state fails open; only an observed offline state blocks I/O. */
export function canStartReplayUpload(networkAvailable: boolean | null, batteryHealthy: boolean): boolean {
  return networkAvailable !== false && batteryHealthy;
}
