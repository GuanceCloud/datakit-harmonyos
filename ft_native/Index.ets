/**
 * DataFlux Native Crash Monitoring Module for HarmonyOS
 *
 * This module provides native C++ crash detection and monitoring capabilities.
 * It uses HarmonyOS HiAppEvent NDK API to subscribe to crash events.
 */

import BuildProfile from './BuildProfile';

// ============================================================================
// Module Version
// ============================================================================

export const HAR_VERSION: string = BuildProfile.HAR_VERSION;
