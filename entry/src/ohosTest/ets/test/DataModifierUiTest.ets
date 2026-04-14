/**
 * DataModifier UI Automation Test
 *
 * Purpose: Automated UI test for DataModifier functionality
 * Using UiDriver framework to automatically navigate and test
 *
 * This test automatically:
 * 1. Launches the application
 * 2. Navigates to DataModifierTestPage
 * 3. Clicks test buttons
 * 4. Verifies results
 *
 * Reference: Android SDK DataModifierTest
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { Driver, ON, BY, Component } from '@ohos.UiDriver';
import { UiDriver } from '@ohos.UiDriver';

export default function dataModifierUiTest() {
  describe('DataModifierUiTest', () => {
    let driver: Driver = undefined;

    beforeAll(async () => {
      console.info('[DataModifierUiTest] beforeAll called');
      // Create Driver instance
      driver = Driver.create();

      // Force quit any existing instances
      await driver.forceDriverQuit();
    });

    beforeEach(() => {
      console.info('[DataModifierUiTest] beforeEach called');
    });

    afterEach(() => {
      console.info('[DataModifierUiTest] afterEach called');
    });

    afterAll(async () => {
      console.info('[DataModifierUiTest] afterAll called');
      // Clean up
      if (driver !== undefined) {
        await driver.forceDriverQuit();
      }
    });

    /**
     * Automated test for RUM data modification
     * Aligned with Android SDK: rumAppDataTest
     *
     * Test steps:
     * 1. Launch application
     * 2. Wait for app to load
     * 3. Click "Run RUM Test" button
     * 4. Wait for test to complete
     * 5. Verify "✅ RUM Test Passed" is displayed
     */
    it('automatedRumTest', 0, async () => {
      console.info('[DataModifierUiTest] Starting automated RUM test');

      // Step 1: Launch application (if not already running)
      try {
        await driver.launchApplication(
          'com.example.entry' // Replace with actual bundle name
        );
        console.info('[DataModifierUiTest] Application launched');
      } catch (error) {
        console.info('[DataModifierUiTest] App may already be running, continuing...');
      }

      // Step 2: Wait for page to load
      await driver.waitForMilliseconds(2000);

      // Step 3: Find and click "Run RUM Test" button
      try {
        const rumTestButton = await driver.findComponent(BY.text('Run RUM Test').type('Button'));
        await rumTestButton.click();
        console.info('[DataModifierUiTest] Clicked RUM test button');
      } catch (error) {
        console.error('[DataModifierUiTest] Failed to find RUM test button:', error);
        expect().assertFail();
        return;
      }

      // Step 4: Wait for test to complete (RUM test takes ~2 seconds + processing)
      await driver.waitForMilliseconds(5000);

      // Step 5: Verify success message
      try {
        const resultText = await driver.findComponent(
          ON.byTextSubstring('RUM Test Passed')
        );
        const text = await resultText.getText();
        console.info('[DataModifierUiTest] RUM test result: ' + text);

        // Verify test passed
        expect(text).toContain('✅');
      } catch (error) {
        console.error('[DataModifierUiTest] RUM test verification failed:', error);
        expect().assertFail();
      }

      console.info('[DataModifierUiTest] automatedRumTest passed');
    });

    /**
     * Automated test for Log data modification
     * Aligned with Android SDK: logDataTest
     *
     * Test steps:
     * 1. Click "Run Log Test" button
     * 2. Wait for test to complete
     * 3. Verify "✅ Log Test Passed" is displayed
     */
    it('automatedLogTest', 0, async () => {
      console.info('[DataModifierUiTest] Starting automated Log test');

      // Step 1: Click "Run Log Test" button
      try {
        const logTestButton = await driver.findComponent(BY.text('Run Log Test').type('Button'));
        await logTestButton.click();
        console.info('[DataModifierUiTest] Clicked Log test button');
      } catch (error) {
        console.error('[DataModifierUiTest] Failed to find Log test button:', error);
        expect().assertFail();
        return;
      }

      // Step 2: Wait for test to complete (Log test takes ~3.5 seconds + processing)
      await driver.waitForMilliseconds(6000);

      // Step 3: Verify success message
      try {
        const resultText = await driver.findComponent(
          ON.byTextSubstring('Log Test Passed')
        );
        const text = await resultText.getText();
        console.info('[DataModifierUiTest] Log test result: ' + text);

        // Verify test passed
        expect(text).toContain('✅');
      } catch (error) {
        console.error('[DataModifierUiTest] Log test verification failed:', error);
        expect().assertFail();
      }

      console.info('[DataModifierUiTest] automatedLogTest passed');
    });

    /**
     * Automated test for running all tests
     *
     * Test steps:
     * 1. Click "Run All Tests" button
     * 2. Wait for all tests to complete
     * 3. Verify both RUM and Log tests passed
     */
    it('automatedAllTests', 0, async () => {
      console.info('[DataModifierUiTest] Starting automated all tests');

      // Step 1: Click "Run All Tests" button
      try {
        const runAllButton = await driver.findComponent(BY.text('Run All Tests').type('Button'));
        await runAllButton.click();
        console.info('[DataModifierUiTest] Clicked run all button');
      } catch (error) {
        console.error('[DataModifierUiTest] Failed to find run all button:', error);
        expect().assertFail();
        return;
      }

      // Step 2: Wait for all tests to complete
      await driver.waitForMilliseconds(8000);

      // Step 3: Verify both tests passed
      try {
        const rumResult = await driver.findComponent(
          ON.byTextSubstring('RUM Test Passed')
        );

        const logResult = await driver.findComponent(
          ON.byTextSubstring('Log Test Passed')
        );

        const rumText = await rumResult.getText();
        const logText = await logResult.getText();

        console.info('[DataModifierUiTest] RUM test result: ' + rumText);
        console.info('[DataModifierUiTest] Log test result: ' + logText);

        // Verify both tests passed
        expect(rumText).toContain('✅');
        expect(logText).toContain('✅');
      } catch (error) {
        console.error('[DataModifierUiTest] All tests verification failed:', error);
        expect().assertFail();
      }

      console.info('[DataModifierUiTest] automatedAllTests passed');
    });
  });
}
