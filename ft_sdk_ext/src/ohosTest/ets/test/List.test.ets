import httpChainModeDeviceTest from './HttpChainModeDeviceTest.test';
import ftFirstFrameMonitorDeviceTest from './FTFirstFrameMonitorDeviceTest.test';

export default function testsuite() {
  httpChainModeDeviceTest();
  ftFirstFrameMonitorDeviceTest();
}
