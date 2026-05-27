/**
 * FT SDK Test Suite Entry Point
 *
 * This file aggregates all test modules and serves as the main entry point
 * for running the complete test suite.
 *
 * @author FT SDK Team
 */

import lineProtocolEscapeTest from './LineProtocolEscapeTest.test';
import httpTest from './HttpTest.test';
import storeDataFormatTest from './StoreDataFormatTest.test';
import threadPoolTest from './ThreadPoolTest.test';
import threadPoolBenchmarkTest from './ThreadPoolBenchmarkTest.test';
import utilsTest from './UtilsTest.test';
import beanModelUnitTest from './unit/BeanModelUnit.test';
import cachePolicyUnitTest from './unit/CachePolicyUnit.test';
import configUnitTest from './unit/ConfigUnit.test';
import dataModifierUnitTest from './unit/DataModifierUnit.test';
import dbBeanModelUnitTest from './unit/DbBeanModelUnit.test';
import dbRuntimeUnitTest from './unit/DbRuntimeUnit.test';
import ftExceptionHandlerUnitTest from './unit/FTExceptionHandlerUnit.test';
import ftSDKUnitTest from './unit/FTSDKUnit.test';
import ftTrackInnerUnitTest from './unit/FTTrackInnerUnit.test';
import ftInTakeUrlHandlerUnitTest from './unit/FTInTakeUrlHandlerUnit.test';
import ftSDKExtensionBridgeUnitTest from './unit/FTSDKExtensionBridgeUnit.test';
import httpAutoTrackAxiosUnitTest from './unit/HttpAutoTrackAxiosUnit.test';
import httpAutoTrackSharedUnitTest from './unit/HttpAutoTrackSharedUnit.test';
import samplingUnitTest from './unit/SamplingUnit.test';
import syncDataHelperUnitTest from './unit/SyncDataHelperUnit.test';
import syncTaskManagerUnitTest from './unit/SyncTaskManagerUnit.test';
import traceHeaderUnitTest from './unit/TraceHeaderUnit.test';
import userDataUnitTest from './unit/UserDataUnit.test';
import utilsCoreUnitTest from './unit/UtilsCoreUnit.test';

export default function testsuite() {

  // Validates SDK, RUM, logger, and trace configuration defaults and boundary handling.
  configUnitTest();
  // Validates sync payload assembly, Line Protocol formatting, and context merging.
  syncDataHelperUnitTest();
  // Validates sync task scheduling, upload retry/discard flows, cleanup, and callbacks.
  syncTaskManagerUnitTest();
  // Validates sampling boundaries, error sampling fallback, and session collection decisions.
  samplingUnitTest();
  // Validates trace header generation, reuse, and interceptor behavior across supported protocols.
  traceHeaderUnitTest();
  // Validates user data models, extension fields, binding state, and RUM dynamic tags.
  userDataUnitTest();
  // Validates Axios auto-tracking state cleanup after successful and failed responses.
  httpAutoTrackAxiosUnitTest();
  // Validates shared HTTP auto-tracking headers, resource IDs, state stores, and reset logic.
  httpAutoTrackSharedUnitTest();
  // Validates base content, log, status, and Line Protocol bean behavior.
  beanModelUnitTest();
  // Validates database Action, View, and SyncData bean fields, JSON, cloning, and counters.
  dbBeanModelUnitTest();
  // Validates database helper, DB manager, and FTDB manager lifecycle and failure branches.
  dbRuntimeUnitTest();
  // Validates data masking and chained Line Protocol data modifier behavior.
  dataModifierUnitTest();
  // Validates ArkTS exception observation, crash handling, window closing, and native crash setup.
  ftExceptionHandlerUnitTest();
  // Validates FTSDK initialization, config installation, feature switches, context, and utilities.
  ftSDKUnitTest();
  // Validates internal tracking entry points, RUM/log persistence, sync triggers, and shutdown.
  ftTrackInnerUnitTest();
  // Validates Intake URL default filtering, custom matching rules, and rule management.
  ftInTakeUrlHandlerUnitTest();
  // Validates database cache size/count limits, discard strategies, and cleanup branches.
  cachePolicyUnitTest();
  // Validates SDK extension bridge header normalization, request preparation, and response completion.
  ftSDKExtensionBridgeUnitTest();
  // Validates generic utility helpers for formatting, guards, cloning, arrays, timing, and device fallbacks.
  utilsCoreUnitTest();
  // Line Protocol Escape Tests
  lineProtocolEscapeTest();
  // HTTP Tests
  httpTest();
  // Store Data Format Tests
  storeDataFormatTest();
  // Thread Pool Tests
  threadPoolTest();
  // Thread Pool Benchmark Tests
  threadPoolBenchmarkTest();
  // Utils legacy tests
  utilsTest();
}
