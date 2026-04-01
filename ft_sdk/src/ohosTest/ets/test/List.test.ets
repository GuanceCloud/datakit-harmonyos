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

export default function testsuite() {

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
}
