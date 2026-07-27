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
import ftDataFilterUnitTest from './unit/FTDataFilterUnit.test';
import ftDBSpoolUnitTest from './unit/FTDBSpoolUnit.test';
import ftSDKExtensionBridgeUnitTest from './unit/FTSDKExtensionBridgeUnit.test';
import httpTest from './unit/HttpTest.test';
import httpAutoTrackAxiosUnitTest from './unit/HttpAutoTrackAxiosUnit.test';
import httpAutoTrackRcpConfigUnitTest from './unit/HttpAutoTrackRcpConfigUnit.test';
import httpAutoTrackSharedUnitTest from './unit/HttpAutoTrackSharedUnit.test';
import lineProtocolEscapeTest from './unit/LineProtocolEscapeTest.test';
import samplingUnitTest from './unit/SamplingUnit.test';
import sdkDedicatedPoolManagerUnitTest from './unit/SDKDedicatedPoolManagerUnit.test';
import sdkWorkerRetryPolicyUnitTest from './unit/SDKWorkerRetryPolicyUnit.test';
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
  ftDataFilterUnitTest();

  // Small high-risk internal guardrails retained to prevent regressions.
  samplingUnitTest();
  sdkDedicatedPoolManagerUnitTest();
  sdkWorkerRetryPolicyUnitTest();
  ftExceptionHandlerUnitTest();
  ftDBSpoolUnitTest();
  cachePolicyUnitTest();
  syncTaskManagerUnitTest();
  userDataUnitTest();
}
