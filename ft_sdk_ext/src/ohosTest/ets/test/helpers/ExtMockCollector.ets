// Share the device-test transport seam so both suites exercise the real upload Worker.
export { MockCollector as ExtMockCollector, runTestCleanup } from
  '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/MockCollector';
