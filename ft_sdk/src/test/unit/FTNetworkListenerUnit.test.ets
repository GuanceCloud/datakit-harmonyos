import { describe, expect, it } from '@ohos/hypium';
import connection from '@ohos.net.connection';
import {
  FTNetworkListener,
  isKnownWifiSignalLevel,
  shouldApplyWifiSignalSnapshot
} from '../../main/ets/components/utils/FTNetworkListener';

class FakeSnapshotNetworkListener extends FTNetworkListener {
  public netId: number = 1;
  public failureStage: string = '';
  public platformReads: number = 0;
  public capabilities: connection.NetCapabilities = {
    bearerTypes: [],
    networkCap: [connection.NetCap.NET_CAPABILITY_VALIDATED],
    linkDownBandwidthKbps: 1200,
    linkUpBandwidthKbps: 600
  };

  constructor() { super(); }

  public refresh(): void { this.refreshSnapshotFromDefaultNetwork(); }

  protected hasDefaultNetwork(): boolean {
    this.platformReads++;
    if (this.failureStage === 'availability') throw new Error('permission denied');
    return this.netId > 0;
  }

  protected getDefaultNetworkHandle(): connection.NetHandle {
    this.platformReads++;
    if (this.failureStage === 'handle') throw new Error('unsupported API');
    const handle = new Object() as connection.NetHandle;
    handle.netId = this.netId;
    return handle;
  }

  protected getNetworkCapabilities(_handle: connection.NetHandle): connection.NetCapabilities {
    this.platformReads++;
    if (this.failureStage === 'capabilities') throw new Error('invalid network handle');
    return this.capabilities;
  }
}

export default function ftNetworkListenerUnitTest() {
  describe('FTNetworkListenerUnit', () => {
    it('newDefaultNetworkShouldDiscardOldMetricsWhenCapabilitiesFail', 0, () => {
      const listener = new FakeSnapshotNetworkListener();
      listener.refresh();
      const startedSnapshot = listener.getResourceNetworkSnapshot();
      listener.netId = 2;
      listener.failureStage = 'capabilities';
      listener.refresh();
      const current = listener.getResourceNetworkSnapshot();
      expect(current.available).assertTrue();
      expect(current.validated === undefined).assertTrue();
      expect(current.downlinkKbps === undefined).assertTrue();
      expect(current.uplinkKbps === undefined).assertTrue();
      expect(current.signalStrength === undefined).assertTrue();
      expect(startedSnapshot.downlinkKbps).assertEqual(1200);
      expect(startedSnapshot.validated).assertTrue();
    });

    it('confirmedAvailabilityShouldSurviveInitialCapabilityFailure', 0, () => {
      const listener = new FakeSnapshotNetworkListener();
      listener.failureStage = 'capabilities';
      listener.refresh();
      expect(listener.getResourceNetworkSnapshot().available).assertTrue();
      expect(Object.keys(listener.getResourceNetworkSnapshot()).length).assertEqual(1);
    });

    it('permissionAndUnsupportedApiFailuresShouldOmitUnverifiedMetrics', 0, () => {
      for (const failure of ['availability', 'handle', 'capabilities']) {
        const listener = new FakeSnapshotNetworkListener();
        listener.refresh();
        listener.failureStage = failure;
        listener.refresh();
        expect(listener.getResourceNetworkSnapshot().available).assertTrue();
        expect(Object.keys(listener.getResourceNetworkSnapshot()).length).assertEqual(1);
      }
      const initial = new FakeSnapshotNetworkListener();
      initial.failureStage = 'availability';
      initial.refresh();
      expect(initial.getResourceNetworkSnapshot().available).assertFalse();
    });

    it('snapshotsShouldBeIndependentAndPerformNoPlatformReads', 0, () => {
      const listener = new FakeSnapshotNetworkListener();
      listener.refresh();
      const reads = listener.platformReads;
      const snapshot = listener.getResourceNetworkSnapshot();
      snapshot.downlinkKbps = 99;
      expect(listener.getResourceNetworkSnapshot().downlinkKbps).assertEqual(1200);
      expect(listener.platformReads).assertEqual(reads);
    });

    it('networkLossAndRecoveryShouldReplaceAllOptionalMetrics', 0, () => {
      const listener = new FakeSnapshotNetworkListener();
      listener.refresh();
      listener.netId = 0;
      listener.refresh();
      expect(listener.getResourceNetworkSnapshot().available).assertFalse();
      expect(Object.keys(listener.getResourceNetworkSnapshot()).length).assertEqual(1);
      listener.netId = 2;
      listener.capabilities = { bearerTypes: [], networkCap: [], linkDownBandwidthKbps: 300 };
      listener.refresh();
      expect(listener.getResourceNetworkSnapshot().available).assertTrue();
      expect(listener.getResourceNetworkSnapshot().validated).assertFalse();
      expect(listener.getResourceNetworkSnapshot().downlinkKbps).assertEqual(300);
      expect(listener.getResourceNetworkSnapshot().uplinkKbps === undefined).assertTrue();
    });

    it('checkingConnectivityAndBandwidthSentinelsShouldRemainUnknown', 0, () => {
      const listener = new FakeSnapshotNetworkListener();
      listener.capabilities = {
        bearerTypes: [], networkCap: [connection.NetCap.NET_CAPABILITY_CHECKING_CONNECTIVITY],
        linkDownBandwidthKbps: 0, linkUpBandwidthKbps: -1
      };
      listener.refresh();
      expect(listener.getResourceNetworkSnapshot().available).assertTrue();
      expect(Object.keys(listener.getResourceNetworkSnapshot()).length).assertEqual(1);
    });

    it('wifiSignalCallbackShouldRequireTheCapturedNetworkRevision', 0, () => {
      expect(shouldApplyWifiSignalSnapshot(42, 7, true, 42, 7)).assertTrue();
      expect(shouldApplyWifiSignalSnapshot(43, 7, true, 42, 7)).assertFalse();
      // netId can theoretically be reused; the revision still rejects a
      // callback that started before a disconnect/reconnect cycle.
      expect(shouldApplyWifiSignalSnapshot(42, 8, true, 42, 7)).assertFalse();
      expect(shouldApplyWifiSignalSnapshot(42, 7, false, 42, 7)).assertFalse();
      expect(shouldApplyWifiSignalSnapshot(0, 7, true, 0, 7)).assertFalse();
    });

    it('wifiSignalLevelShouldKeepOnlyPlatformDefinedLevels', 0, () => {
      expect(isKnownWifiSignalLevel(0)).assertTrue();
      expect(isKnownWifiSignalLevel(4)).assertTrue();
      expect(isKnownWifiSignalLevel(-1)).assertFalse();
      expect(isKnownWifiSignalLevel(5)).assertFalse();
      expect(isKnownWifiSignalLevel(1.5)).assertFalse();
    });
  });
}
