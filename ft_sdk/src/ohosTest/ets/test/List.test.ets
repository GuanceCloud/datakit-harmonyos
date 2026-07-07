/**
 * FT SDK Test Suite Entry Point
 *
 * This file aggregates all test modules and serves as the main entry point
 * for running the complete test suite.
 *
 * @author FT SDK Team
 */

import dataModifierTest from './DataModifierTest.test';
import dataSyncTest from './DataSyncTest.test';
import autoTrackDeviceTest from './AutoTrackDeviceTest.test';
import ftExceptionHandlerDeviceTest from './FTExceptionHandlerDeviceTest.test';
import ftNativeCrashHandlerDeviceTest from './FTNativeCrashHandlerDeviceTest.test';
import ftSDKLifecycleDeviceTest from './FTSDKLifecycleDeviceTest.test';
import ftDBManagerDeviceTest from './FTDBManagerDeviceTest.test';
import configTest from './ConfigTest.test';
import logGlobalContextTest from './LogGlobalContextTest.test';
import logTest from './LogTest.test';
import rcpAutoTrackDeviceTest from './RcpAutoTrackDeviceTest.test';
import resourceAutoTrackDeviceTest from './ResourceAutoTrackDeviceTest.test';
import realBackendSmokeTest from './RealBackendSmokeTest.test';
import syncUploadChainDeviceTest from './SyncUploadChainDeviceTest.test';
import userDataManagerPersistenceTest from './UserDataManagerPersistenceTest.test';
import webViewAutoTrackDeviceTest from './WebViewAutoTrackDeviceTest.test';
import workerIntegrationDeviceTest from './WorkerIntegrationDeviceTest.test';

export default function testsuite() {

  // User-facing config behavior that affects installed SDK state.
  configTest();
  ftExceptionHandlerDeviceTest();
  ftNativeCrashHandlerDeviceTest();
  ftSDKLifecycleDeviceTest();

  // Public API/demo-triggered data generation, persistence, upload and deletion chains.
  autoTrackDeviceTest();
  dataModifierTest();
  dataSyncTest();
  ftDBManagerDeviceTest();
  logTest();
  logGlobalContextTest();
  rcpAutoTrackDeviceTest();
  resourceAutoTrackDeviceTest();
  syncUploadChainDeviceTest();
  userDataManagerPersistenceTest();
  webViewAutoTrackDeviceTest();
  workerIntegrationDeviceTest();

  // Manual real backend smoke. Disabled by default unless explicitly enabled.
  realBackendSmokeTest();

}
