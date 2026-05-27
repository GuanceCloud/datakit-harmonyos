/**
 * FT SDK Test Suite Entry Point
 *
 * This file aggregates all test modules and serves as the main entry point
 * for running the complete test suite.
 *
 * @author FT SDK Team
 */

import configTest from './ConfigTest.test';
import dataFormatTest from './DataFormatTest.test';
import dataIntegerCompatibleTest from './DataIntegerCompatibleTest.test';
import dataModifierTest from './DataModifierTest.test';
import dataSyncTest from './DataSyncTest.test';
import deviceUtilsTest from './DeviceUtilsTest.test';
import ftDBManagerDeviceTest from './FTDBManagerDeviceTest.test';
import ftDBManagerTest from './FTDBManagerTest.test';
import innerLogTest from './InnerLogTest.test';
import logGlobalContextTest from './LogGlobalContextTest.test';
import logTest from './LogTest.test';
import monitorConfigTest from './MonitorConfigTest.test';
import remoteConfigTest from './RemoteConfigTest.test';
import syncUploadChainDeviceTest from './SyncUploadChainDeviceTest.test';
import threadPoolBenchmarkDeviceTest from './ThreadPoolBenchmarkDeviceTest.test';
import userDataManagerPersistenceTest from './UserDataManagerPersistenceTest.test';

export default function testsuite() {

  // Core pure logic P0 tests are maintained in ft_sdk/src/test/unit.

  // Config Tests (adapted from Android SDK)
  configTest();

  // Data Format Tests (adapted from Android SDK)
  dataFormatTest();

  // Data Integer Compatible Tests (adapted from Android SDK)
  dataIntegerCompatibleTest();

  // Data Modifier Tests (adapted from Android SDK)
  dataModifierTest();

  // Data Sync Tests (adapted from Android SDK)
  dataSyncTest();

  // Database Manager Tests
  ftDBManagerTest();

  // Device-level database persistence and cleanup Tests
  ftDBManagerDeviceTest();

  // Device-level user preferences persistence Tests
  userDataManagerPersistenceTest();

  // Device-level upload retry, queue, batch delete and recovery Tests
  syncUploadChainDeviceTest();

  // Device-level thread pool benchmark metrics
  threadPoolBenchmarkDeviceTest();

  // Device Utility Tests
  deviceUtilsTest();

  // Inner Log Tests
  innerLogTest();

  // Log Tests
  logTest();

  // Log Global Context Tests
  logGlobalContextTest();

  // Monitor Config Tests
  monitorConfigTest();

  // Remote Config Tests
  remoteConfigTest();
}
