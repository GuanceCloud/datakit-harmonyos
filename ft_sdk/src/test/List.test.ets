/**
 * FT SDK Test Suite Entry Point
 *
 * This file aggregates all test modules and serves as the main entry point
 * for running the complete test suite.
 *
 * @author FT SDK Team
 */

import cachePolicyUnitTest from './unit/CachePolicyUnit.test';
import configUnitTest from './unit/ConfigUnit.test';
import dataModifierUnitTest from './unit/DataModifierUnit.test';
import ftExceptionHandlerUnitTest from './unit/FTExceptionHandlerUnit.test';
import ftSDKExtensionBridgeUnitTest from './unit/FTSDKExtensionBridgeUnit.test';
import httpTest from './unit/HttpTest.test';
import httpAutoTrackAxiosUnitTest from './unit/HttpAutoTrackAxiosUnit.test';
import httpAutoTrackRcpConfigUnitTest from './unit/HttpAutoTrackRcpConfigUnit.test';
import httpAutoTrackSharedUnitTest from './unit/HttpAutoTrackSharedUnit.test';
import lineProtocolEscapeTest from './unit/LineProtocolEscapeTest.test';
import samplingUnitTest from './unit/SamplingUnit.test';
import sdkThreadPoolCapabilityUnitTest from './unit/SDKThreadPoolCapabilityUnit.test';
import sdkTaskSchedulerUnitTest from './unit/SDKTaskSchedulerUnit.test';
import syncDataHelperUnitTest from './unit/SyncDataHelperUnit.test';
import syncTaskManagerUnitTest from './unit/SyncTaskManagerUnit.test';
import traceHeaderUnitTest from './unit/TraceHeaderUnit.test';
import userDataUnitTest from './unit/UserDataUnit.test';

export default function testsuite() {

  // User-facing config defaults, boundaries, and installed behavior.
  configUnitTest();

  // Data formatting, trace, HTTP, extension and auto-track protocol guards.
  lineProtocolEscapeTest();
  syncDataHelperUnitTest();
  traceHeaderUnitTest();
  httpTest();
  ftSDKExtensionBridgeUnitTest();
  httpAutoTrackAxiosUnitTest();
  httpAutoTrackRcpConfigUnitTest();
  httpAutoTrackSharedUnitTest();
  dataModifierUnitTest();

  // Small high-risk internal guardrails retained to prevent regressions.
  samplingUnitTest();
  sdkTaskSchedulerUnitTest();
  sdkThreadPoolCapabilityUnitTest();
  ftExceptionHandlerUnitTest();
  cachePolicyUnitTest();
  syncTaskManagerUnitTest();
  userDataUnitTest();
}
