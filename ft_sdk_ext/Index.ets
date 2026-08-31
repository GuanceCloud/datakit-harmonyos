/**
 *  HarmonyOS SDK - Extension API Exports
 *
 * This module contains APIs that rely on newer HarmonyOS compiler or platform
 * capabilities and should stay isolated from the core `ft_sdk` package.
 */

export {
  createFTHttpInterceptorChain,
  applyFTAxiosChainMethodBridge,
  applyFTHttpTrack,
  HttpInitialRequestInterceptor,
  HttpFinalResponseInterceptor
} from './src/main/ets/components/network/FTHttpAutoTrackExt';

/** API 22 real first-frame observation for cold-launch timing. */
export { observeFTAppFirstFrame } from './src/main/ets/components/monitor/FTFirstFrameMonitor';
