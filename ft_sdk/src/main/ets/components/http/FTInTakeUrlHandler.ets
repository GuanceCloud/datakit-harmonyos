import { FTInnerLogger } from "../log/FTLogger";

/**
 * URL collection handler configuration interface
 */
interface InTakeUrlHandlerConfig {
  ignoreInternalUrls?: boolean;
  ignoreDefaultPatterns?: boolean;
  enableLogging?: boolean;
  customIgnorePatterns?: (string | RegExp)[];
  customIgnoreUrls?: string[];
}

/**
 * URL collection handler configuration information interface
 */
interface InTakeUrlHandlerConfigInfo {
  ignoreInternalUrls: boolean;
  ignoreDefaultPatterns: boolean;
  customIgnorePatternsCount: number;
  customIgnoreUrlsCount: number;
}

const TAG = "FTInTakeUrlHandler";

/**
 * URL collection handler
 *
 * //TODO to implement
 * Determines which URLs should be monitored
 */
export class FTInTakeUrlHandler {
  // Default ignored URL patterns
  private static readonly DEFAULT_IGNORE_PATTERNS = [
    /^data:/i,
    /^blob:/i,
    /^file:/i,
    /^chrome:/i,
    /^chrome-extension:/i,
    /^moz-extension:/i,
    /^safari-extension:/i,
    /\.webmanifest$/i,
    /\/favicon\.ico$/i
  ];
  
  // Internal SDK URL patterns
  private static readonly INTERNAL_URL_PATTERNS = [
    /dataway-us1\.guance\.com/i,
    /dataway\.guance\.com/i,
    /static\.guance\.com/i,
    /dataflux-apm/i,
    /ft-gateway/i
  ];
  
  // User-defined ignore patterns
  private customIgnorePatterns: RegExp[] = [];
  private customIgnoreUrls: Set<string> = new Set();
  
  // Configuration options
  private ignoreInternalUrls: boolean = true;
  private ignoreDefaultPatterns: boolean = true;
  private enableLogging: boolean = false;

  constructor(config?: InTakeUrlHandlerConfig) {
    if (config) {
      this.ignoreInternalUrls = config.ignoreInternalUrls ?? true;
      this.ignoreDefaultPatterns = config.ignoreDefaultPatterns ?? true;
      this.enableLogging = config.enableLogging ?? false;

      if (config.customIgnorePatterns) {
        this.addIgnorePatterns(config.customIgnorePatterns);
      }
      
      if (config.customIgnoreUrls) {
        this.addIgnoreUrls(config.customIgnoreUrls);
      }
    }
  }
  
  /**
   * Whether to collect data for this URL
   *
   * @param url URL address, for example url="https://www.guance.com/"
   * @return true to skip collection, false to collect
   */
  public isInTakeUrl(url: string): boolean {
    try {
      if (!url || typeof url !== 'string') {
        return true; // Do not collect invalid URLs
      }
      
      const normalizedUrl = url.trim().toLowerCase();
      
      // Check exactly matched ignored URLs
      if (this.customIgnoreUrls.has(normalizedUrl)) {
        this.logDecision(url, true, 'Custom ignore URL');
        return true;
      }
      
      // Check default ignore patterns
      if (this.ignoreDefaultPatterns) {
        for (const pattern of FTInTakeUrlHandler.DEFAULT_IGNORE_PATTERNS) {
          if (pattern.test(normalizedUrl)) {
            this.logDecision(url, true, `Default pattern: ${pattern.source}`);
            return true;
          }
        }
      }
      
      // Check internal URL patterns
      if (this.ignoreInternalUrls) {
        for (const pattern of FTInTakeUrlHandler.INTERNAL_URL_PATTERNS) {
          if (pattern.test(normalizedUrl)) {
            this.logDecision(url, true, `Internal pattern: ${pattern.source}`);
            return true;
          }
        }
      }
      
      // Check custom ignore patterns
      for (const pattern of this.customIgnorePatterns) {
        if (pattern.test(normalizedUrl)) {
          this.logDecision(url, true, `Custom pattern: ${pattern.source}`);
          return true;
        }
      }
      
      // Collect by default
      this.logDecision(url, false, 'No ignore rule matched');
      return false;
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error checking URL ${url}: ${error}`);
      return true; // Do not collect when an error occurs
    }
  }
  
  /**
   * Add an ignore pattern
   */
  public addIgnorePatterns(patterns: (string | RegExp)[]): void {
    try {
      for (const pattern of patterns) {
        if (typeof pattern === 'string') {
          this.customIgnorePatterns.push(new RegExp(pattern, 'i'));
        } else if (pattern instanceof RegExp) {
          this.customIgnorePatterns.push(pattern);
        }
      }
      
      FTInnerLogger.d(TAG, `Added ${patterns.length} ignore patterns`);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding ignore patterns: ${error}`);
    }
  }
  
  /**
   * Add an ignored URL
   */
  public addIgnoreUrls(urls: string[]): void {
    try {
      for (const url of urls) {
        if (url && typeof url === 'string') {
          this.customIgnoreUrls.add(url.trim().toLowerCase());
        }
      }
      
      FTInnerLogger.d(TAG, `Added ${urls.length} ignore URLs`);
      
    } catch (error) {
      FTInnerLogger.e(TAG, `Error adding ignore URLs: ${error}`);
    }
  }
  
  /**
   * Remove an ignore pattern
   */
  public removeIgnorePattern(pattern: RegExp): void {
    const index = this.customIgnorePatterns.findIndex(p => p.source === pattern.source);
    if (index >= 0) {
      this.customIgnorePatterns.splice(index, 1);
      FTInnerLogger.d(TAG, `Removed ignore pattern: ${pattern.source}`);
    }
  }
  
  /**
   * Remove an ignored URL
   */
  public removeIgnoreUrl(url: string): void {
    const normalizedUrl = url.trim().toLowerCase();
    if (this.customIgnoreUrls.delete(normalizedUrl)) {
      FTInnerLogger.d(TAG, `Removed ignore URL: ${url}`);
    }
  }
  
  /**
   * Clear all custom rules
   */
  public clearCustomRules(): void {
    this.customIgnorePatterns = [];
    this.customIgnoreUrls.clear();
    FTInnerLogger.d(TAG, "Cleared all custom ignore rules");
  }
  
  /**
   * Get configuration information
   */
  public getConfig(): InTakeUrlHandlerConfigInfo {
    return {
      ignoreInternalUrls: this.ignoreInternalUrls,
      ignoreDefaultPatterns: this.ignoreDefaultPatterns,
      customIgnorePatternsCount: this.customIgnorePatterns.length,
      customIgnoreUrlsCount: this.customIgnoreUrls.size
    };
  }
  
  /**
   * Update the configuration
   */
  public updateConfig(config: Partial<InTakeUrlHandlerConfig>): void {
    if (config.ignoreInternalUrls !== undefined) {
      this.ignoreInternalUrls = config.ignoreInternalUrls;
    }
    
    if (config.ignoreDefaultPatterns !== undefined) {
      this.ignoreDefaultPatterns = config.ignoreDefaultPatterns;
    }
    
    if (config.enableLogging !== undefined) {
      this.enableLogging = config.enableLogging;
    }
    
    FTInnerLogger.d(TAG, `Updated config: ${JSON.stringify(this.getConfig())}`);
  }
  

  /**
   * Record the decision log
   */
  private logDecision(url: string, ignored: boolean, reason: string): void {
    if (this.enableLogging) {
      FTInnerLogger.d(TAG, `URL ${ignored ? 'IGNORED' : 'COLLECTED'}: ${url} (${reason})`);
    }
  }
  
}
