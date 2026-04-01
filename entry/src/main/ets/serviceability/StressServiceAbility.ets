import rpc from "@ohos.rpc";
import Want from "@ohos.app.ability.Want";
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "StressServiceAbility";

/**
 * ServiceAbility Stub for RPC communication
 */
class StressServiceAbilityStub extends rpc.RemoteObject {
  constructor(des: string | object) {
    if (typeof des === 'string') {
      super(des);
    } else {
      return;
    }
  }
}

/**
 * ServiceAbility interface for type definition
 */
interface ServiceAbilityInterface {
  onStart(want: Want): void;
  onStop(): void;
  onCommand(want: Want, startId: number): void;
  onConnect(want: Want): rpc.RemoteObject;
  onDisconnect(want: Want): void;
}

/**
 * StressServiceAbility - Service for running stress tests in background
 */
class StressServiceAbility implements ServiceAbilityInterface {
  private shouldStop: boolean = false;

  onStart(want: Want): void {
    DemoLogger.i(TAG, "StressServiceAbility onStart");
    this.shouldStop = false;
  }

  onStop(): void {
    DemoLogger.i(TAG, "StressServiceAbility onStop");
    this.shouldStop = true;
  }

  onCommand(want: Want, startId: number): void {
    DemoLogger.i(TAG, `StressServiceAbility onCommand, startId: ${startId}`);
    
    // Check if this is a stop command
    const actionParam = want.parameters?.['action'];
    if (actionParam !== null && actionParam !== undefined) {
      const action = String(actionParam);
      if (action === 'stop') {
        DemoLogger.i(TAG, "Received stop command, service will stop");
        this.shouldStop = true;
        // Note: In FA mode, the service will be stopped by the system
        // when onStop() is called, or we can set a flag and let the service
        // stop naturally when the current command completes
        return;
      }
    }
    
    // Handle start command with duration
    const durationParam = want.parameters?.['duration'];
    if (durationParam !== null && durationParam !== undefined) {
      const duration = Number(durationParam);
      if (!isNaN(duration) && duration > 0) {
        DemoLogger.i(TAG, `Starting stress test for ${duration} minutes`);
        // TODO: Implement stress test logic here
      }
    }
  }

  onConnect(want: Want): rpc.RemoteObject {
    DemoLogger.i(TAG, "StressServiceAbility onConnect");
    return new StressServiceAbilityStub('test');
  }

  onDisconnect(want: Want): void {
    DemoLogger.i(TAG, "StressServiceAbility onDisconnect");
  }
}

export default new StressServiceAbility();
