import { FTInnerLogger } from '../log/FTLogger';

const TAG = "ApplicationUUIDGenerator";

/**
 * Application UUID Generator
 * Generates deterministic UUID based on seed (package name + version)
 * 
 * Aligned with Android's PACKAGE_UUID (compile-time generation)
 * Since HarmonyOS doesn't support compile-time code injection like Android ASM,
 * we use runtime generation with deterministic algorithm to ensure:
 * - Same package name + version → same UUID
 * - Same UUID for all installations of the same build
 */
export class ApplicationUUIDGenerator {
  /**
   * Generate deterministic UUID based on package name and version
   * @param packageName Package name (e.g., "com.example.app")
   * @param versionName Version name (e.g., "1.0.0")
   * @returns UUID v4 format string
   */
  public static generateFromPackageInfo(packageName: string, versionName: string): string {
    const seed: string = `${packageName}_${versionName}`;
    // FTInnerLogger.d(TAG, `Generating UUID from seed: ${seed}`);
    return ApplicationUUIDGenerator.generateDeterministicUUID(seed);
  }

  /**
   * Generate deterministic UUID based on seed string
   * Uses a simple hash function + LCG (Linear Congruential Generator) for pseudo-random generation
   * 
   * Algorithm:
   * 1. Convert seed string to numeric seed using hash function
   * 2. Use LCG to generate pseudo-random numbers
   * 3. Format as UUID v4: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
   * 
   * @param seed Seed string (package name + version or any fixed string)
   * @returns UUID v4 format string
   */
  public static generateDeterministicUUID(seed: string): string {
    // Convert seed string to numeric seed using hash function
    // Similar to Java's String.hashCode() algorithm
    let hashSeed: number = 0;
    for (let i = 0; i < seed.length; i++) {
      const char: number = seed.charCodeAt(i);
      hashSeed = ((hashSeed << 5) - hashSeed) + char;
      hashSeed = hashSeed & hashSeed; // Convert to 32-bit integer
    }
    
    // Ensure positive seed
    if (hashSeed < 0) {
      hashSeed = -hashSeed;
    }
    if (hashSeed === 0) {
      hashSeed = 1; // Avoid zero seed
    }
    
    // LCG parameters (Linear Congruential Generator)
    // Similar to Java's Random class: a = 1664525, c = 1013904223
    // These parameters ensure good distribution and period
    const a: number = 1664525;
    const c: number = 1013904223;
    let state: number = hashSeed;
    
    // Generate random number function using LCG
    // Formula: state = (a * state + c) mod 2^32
    const nextRandom = (): number => {
      state = (a * state + c) >>> 0; // Unsigned 32-bit
      return state / 0xFFFFFFFF; // Normalize to 0-1
    };
    
    // Generate UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    // Format specification:
    // - Position 14: Version 4 identifier (always '4')
    // - Position 19: Variant identifier (8, 9, a, or b)
    // - Other positions: Random hex digits (0-f)
    let uuid: string = '';
    for (let i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        // Hyphen separators
        uuid += '-';
      } else if (i === 14) {
        // Version 4: set version bits to 0100
        uuid += '4';
      } else if (i === 19) {
        // Variant bits: 10xx (8, 9, a, b)
        // This ensures the UUID follows RFC 4122 variant specification
        const variantValue: number = Math.floor(nextRandom() * 4);
        const variantChars: string[] = ['8', '9', 'a', 'b'];
        uuid += variantChars[variantValue];
      } else {
        // Random hex digit (0-f)
        const hexDigit: number = Math.floor(nextRandom() * 16);
        uuid += hexDigit.toString(16);
      }
    }
    
    FTInnerLogger.d(TAG, `Generated PACKAGE UUID: ${uuid}`+`,seed:${seed}`);
    return uuid;
  }
}

