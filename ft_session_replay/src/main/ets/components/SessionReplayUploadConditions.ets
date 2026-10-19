import { batteryInfo } from '@kit.BasicServicesKit';

export const REPLAY_MIN_UPLOAD_BATTERY_SOC: number = 20;

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
  const externallyPowered = state.pluggedType === batteryInfo.BatteryPluggedType.AC ||
    state.pluggedType === batteryInfo.BatteryPluggedType.USB ||
    state.pluggedType === batteryInfo.BatteryPluggedType.WIRELESS;
  const charging = state.chargingStatus === batteryInfo.BatteryChargeState.ENABLE ||
    state.chargingStatus === batteryInfo.BatteryChargeState.FULL;
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
