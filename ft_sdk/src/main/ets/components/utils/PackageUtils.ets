/**
 * Package utilities for HarmonyOS SDK
 * Similar to Android's PackageUtils.java
 * Used to detect native library support and get version information
 */

const TAG = "PackageUtils";

/**
 * Native SDK dependency main class package path
 * Similar to Android: com.ft.sdk.nativelib.NativeEngineInit
 */
const PACKAGE_NATIVE_ENGINE_CLASS = "com.ft.sdk.nativelib.NativeEngineInit";

/**
 * Whether to use native library
 * Similar to Android's PackageUtils.isNativeLibrarySupport()
 * 
 * @returns true if native library is available, false otherwise
 */
export function isNativeLibrarySupport(): boolean {
  try {
    // Try to import or access native library class
    // In HarmonyOS, we can't use Class.forName like Java, so we need to check differently
    // For now, return false as HarmonyOS may not have native library support yet
    // This can be implemented when native library is available
    return false;
  } catch (error) {
    return false;
  }
}

/**
 * Get native library version
 * Similar to Android's PackageUtils.getNativeLibVersion()
 * 
 * @returns Native library version string, or empty string if not available
 */
export function getNativeLibVersion(): string {
  try {
    // Try to get native library version
    // In HarmonyOS, we can't use reflection like Java, so we need to check differently
    // For now, return empty string as HarmonyOS may not have native library support yet
    // This can be implemented when native library is available
    // If native library exists, it should expose a BuildConfig-like object with VERSION_NAME
    return "";
  } catch (error) {
    return "";
  }
}
