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
import utilsTest from './UtilsTest.test';

export default function testsuite() {

  // Line Protocol Escape Tests
  lineProtocolEscapeTest();

  // HTTP Tests
  httpTest();

  // Store Data Format Tests
  storeDataFormatTest();

  // Thread Pool Tests
  threadPoolTest();

  // Utils Tests
  utilsTest();
}
