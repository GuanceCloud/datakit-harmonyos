import { describe, it, expect } from '@ohos/hypium';
import {
  createFTNetStatusBean,
  createFTResourceTimingFromCumulative,
  createFTResourceTimingFromNetworkPerformance
} from '../../main/ets/components/network/FTHttpAutoTrackShared';

export default function resourceTimingUnitTest() {
  describe('ResourceTimingUnit', () => {
    it('connectionShouldIncludeTlsAndPreserveIndependentPhases', 0, () => {
      const timing = createFTResourceTimingFromCumulative({
        dnsEndTimeMs: 10,
        connectEndTimeMs: 30,
        tlsEndTimeMs: 80,
        firstByteWaitStartTimeMs: 100,
        firstByteTimeMs: 150,
        totalTimeMs: 180
      }, 999000000);
      const status = createFTNetStatusBean(timing);

      expect(status.getConnectStartTime()).assertEqual(10000000);
      expect(status.getTcpTime()).assertEqual(70000000);
      expect(timing.performanceMetrics.get('resourceTCP')).assertEqual(70000000);
      expect(status.getSslStartTime()).assertEqual(30000000);
      expect(status.getSSLTime()).assertEqual(50000000);
      expect(timing.performanceMetrics.get('resourceSSL')).assertEqual(50000000);
      expect(status.getDNSTime()).assertEqual(10000000);
      expect(status.getFirstByteStartTime()).assertEqual(100000000);
      expect(status.getFirstByteTime()).assertEqual(50000000);
      expect(status.getDownloadTimeStart()).assertEqual(150000000);
      expect(status.getDownloadTime()).assertEqual(30000000);
      expect(status.getResponseTime()).assertEqual(100000000);
      expect(status.getHoleRequestTime()).assertEqual(180000000);
    });

    it('networkPerformanceConnectionShouldIncludeTls', 0, () => {
      const timing = createFTResourceTimingFromNetworkPerformance({
        dnsTiming: 10,
        tcpTiming: 30,
        tlsTiming: 80,
        firstSendTiming: 100,
        firstReceiveTiming: 150,
        totalFinishTiming: 180
      }, 999000000);

      expect(timing.tcpPhase!.startTime).assertEqual(10000000);
      expect(timing.tcpPhase!.duration).assertEqual(70000000);
      expect(timing.sslPhase!.startTime).assertEqual(30000000);
      expect(timing.sslPhase!.duration).assertEqual(50000000);
      expect(timing.loadTime).assertEqual(180000000);
    });

    it('connectionShouldKeepTcpEndpointWithoutValidTls', 0, () => {
      const tlsEndpoints: Array<number | undefined> = [undefined, 0, 20, -1, Number.NaN, Number.POSITIVE_INFINITY];
      for (const tlsEndpoint of tlsEndpoints) {
        const timing = createFTResourceTimingFromCumulative({
          dnsEndTimeMs: 10,
          connectEndTimeMs: 30,
          tlsEndTimeMs: tlsEndpoint,
          firstByteWaitStartTimeMs: 50,
          firstByteTimeMs: 70,
          totalTimeMs: 90
        }, 999000000);
        const status = createFTNetStatusBean(timing);

        expect(status.getConnectStartTime()).assertEqual(10000000);
        expect(status.getTcpTime()).assertEqual(20000000);
        expect(timing.performanceMetrics.get('resourceTCP')).assertEqual(20000000);
        expect(timing.sslPhase === undefined).assertTrue();
        expect(status.getSSLTime()).assertEqual(-1);
        expect(status.getHoleRequestTime()).assertEqual(90000000);
      }
    });

    it('reusedConnectionShouldNotFabricateConnectionOrTlsDuration', 0, () => {
      const timing = createFTResourceTimingFromNetworkPerformance({
        dnsTiming: 0,
        tcpTiming: 0,
        tlsTiming: 0,
        firstSendTiming: 40,
        firstReceiveTiming: 70,
        totalFinishTiming: 100
      }, 999000000);
      const status = createFTNetStatusBean(timing);

      expect(timing.tcpPhase!.duration).assertEqual(0);
      expect(timing.sslPhase!.duration).assertEqual(0);
      expect(timing.performanceMetrics.has('resourceTCP')).assertFalse();
      expect(timing.performanceMetrics.has('resourceSSL')).assertFalse();
      expect(status.getTcpTime()).assertEqual(-1);
      expect(status.getSSLTime()).assertEqual(-1);
      expect(status.getFirstByteStartTime()).assertEqual(40000000);
      expect(status.getHoleRequestTime()).assertEqual(100000000);
    });
  });
}
