import { FTResponseData } from './FTResponseData';
import { http } from '@kit.NetworkKit';
import { FTSDKConfig } from '../Configs';
import { NetworkUtils } from '../utils/NetworkUtils';
import { NetCodeStatus } from './HttpEngine';
import { Constants } from '../Constants';
import BuildProfile from '../../../../../BuildProfile';
import { StringUtils } from '../utils/StringUtils';
import { DateUtils } from '../utils/DateUtils';
import { FTInnerLogger } from '../log/FTLogger';

export interface HttpBuilderTestRequest {
  url: string;
  model: string;
  method: http.RequestMethod | null;
  bodyString: string;
  headers: Record<string, string>;
  extraData?: string | ArrayBuffer;
}

export interface HttpPayloadCompressor {
  contentEncoding: string;
  compress(data: string): Promise<ArrayBuffer>;
}

const CHARSET = "UTF-8";
const CONTENT_TYPE = "text/plain";

export class HttpBuilder {
  private host: string | null = null;
  private model: string | null = null;
  private method: http.RequestMethod | null = null;
  private bodyString: string | null = null;
  private sendOutTime: number = 60000;
  private readOutTime: number = 60000;
  private isDataway: boolean = false;
  private readonly headParams: Map<string, string> = new Map();
  private readonly queryParams: Map<string, string> = new Map();
  private sdkConfig: FTSDKConfig;

  // Test mode support
  private static testMode: boolean = false;
  private static mockResponse: FTResponseData | null = null;
  private static capturedRequests: HttpBuilderTestRequest[] = [];
  private static payloadCompressor: HttpPayloadCompressor | null = null;

  /**
   * Enable test mode for unit testing
   * When enabled, executeSync will return mock responses
   */
  static enableTestMode(): void {
    HttpBuilder.testMode = true;
  }

  /**
   * Disable test mode
   */
  static disableTestMode(): void {
    HttpBuilder.testMode = false;
    HttpBuilder.mockResponse = null;
    HttpBuilder.capturedRequests = [];
  }

  /**
   * Set mock response for testing
   * @param response Mock response to return
   */
  static setMockResponse(response: FTResponseData): void {
    HttpBuilder.mockResponse = response;
  }

  /**
   * Check if test mode is enabled
   * @returns true if test mode is enabled
   */
  static isTestMode(): boolean {
    return HttpBuilder.testMode;
  }

  static resetCapturedRequests(): void {
    HttpBuilder.capturedRequests = [];
  }

  static getCapturedRequests(): HttpBuilderTestRequest[] {
    return HttpBuilder.capturedRequests.slice();
  }

  static getLastCapturedRequest(): HttpBuilderTestRequest | null {
    if (HttpBuilder.capturedRequests.length === 0) {
      return null;
    }
    return HttpBuilder.capturedRequests[HttpBuilder.capturedRequests.length - 1];
  }

  static setPayloadCompressorInternal(compressor: HttpPayloadCompressor | null): void {
    HttpBuilder.payloadCompressor = compressor;
  }

  static resetPayloadCompressorInternal(): void {
    HttpBuilder.payloadCompressor = null;
  }

  private captureTestRequest(header: Record<string, string>, extraData?: string | ArrayBuffer): void {
    HttpBuilder.capturedRequests.push({
      url: this.getUrl(),
      model: this.model ?? "",
      method: this.method,
      bodyString: this.bodyString ?? "",
      headers: header,
      extraData: extraData
    });
  }

  static Builder(sdkConfig: FTSDKConfig): HttpBuilder {
    return new HttpBuilder(sdkConfig);
  }

  constructor(sdkConfig: FTSDKConfig) {
    this.sdkConfig = sdkConfig;
  }

  getHost(): string {
    if (this.host === null) {
      if (StringUtils.isNotEmpty(this.sdkConfig?.getDatakitUrl())) {
        this.host = this.sdkConfig.getDatakitUrl();
      } else {
        this.isDataway = true;
        this.host = this.sdkConfig.getDatawayUrl();
      }
    }
    return this.host;
  }

  getMethod(): http.RequestMethod {
    if (this.method === null) {
      throw new Error("method not initialized");
    }
    return this.method;
  }

  getUrl(): string {
    let url: string = this.getHost();
    if (this.model != null && this.model.trim() !== "") {
      if (!this.isDataway) {
        url += `/${this.model}?precision=ns`;
      } else {
        const token = this.sdkConfig.getClientToken?.() || "";
        url += `/${this.model}?token=${token}&to_headless=true&precision=ns`;
      }
    }
    if (this.queryParams.size > 0) {
      const query: Array<string> = [];
      this.queryParams.forEach((value, key) => {
        query.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
      });
      url += url.indexOf('?') >= 0 ? '&' : '?';
      url += query.join('&');
    }
    return url;
  }

  private getLogUrl(): string {
    const url = this.getUrl();
    if (!this.isDataway) {
      return url;
    }

    const token = this.sdkConfig.getClientToken?.() || "";
    if (token.length === 0) {
      return url;
    }

    const visibleLength = Math.ceil(token.length / 2);
    // Use URL-safe masking chars so the logged URL remains linkable in log viewers.
    const maskedToken = `${token.substring(0, visibleLength)}${"x".repeat(token.length - visibleLength)}`;
    return url.replace(`token=${token}`, `token=${maskedToken}`);
  }

  getBodyString(): string | null {
    return this.bodyString;
  }

  getModel(): string | null {
    return this.model;
  }

  getSendOutTime(): number {
    return this.sendOutTime;
  }

  getReadOutTime(): number {
    return this.readOutTime;
  }

  getHeadParams(): Map<string, string> {
    return this.headParams;
  }

  setUrl(host: string): HttpBuilder {
    this.host = host;
    return this;
  }

  setMethod(method: http.RequestMethod): HttpBuilder {
    this.method = method;
    return this;
  }

  setBodyString(bodyString: string): HttpBuilder {
    this.bodyString = bodyString;
    return this;
  }

  setModel(model: string): HttpBuilder {
    this.model = model;
    return this;
  }

  setHeadParams(hashMap: Map<string, string>): HttpBuilder {
    hashMap.forEach((value, key) => {
      this.headParams.set(key, value);
    });
    return this;
  }

  addHeadParam(key: string, value: string): HttpBuilder {
    this.headParams.set(key, value);
    return this;
  }

  /**
   * Add a URL query parameter without changing the standard intake URL and
   * Dataway authentication handling. This is used by SDK control-plane APIs
   * such as remote configuration.
   */
  addQueryParam(key: string, value: string): HttpBuilder {
    if (key.length > 0) {
      this.queryParams.set(key, value);
    }
    return this;
  }

  /**
   * Build common request headers
   * @returns Record containing all request headers
   */
  private buildRequestHeaders(): Record<string, string> {
    const header: Record<string, string> = {};
    
    // Add user agent
    header["User-Agent"] = `${Constants.USER_AGENT};agent_${BuildProfile.HAR_VERSION}`;
    header["charset"] = CHARSET;
    
    // Add content type
    if (!this.headParams.has("Content-Type")) {
      header["Content-Type"] = CONTENT_TYPE;
    }
    
    // Add date
    header["Date"] = DateUtils.formatToGMT(new Date());
    
    // Add custom request headers
    this.headParams.forEach((value, key) => {
      header[key] = value;
    });
    
    return header;
  }

  /**
   * Execute HTTP request (common implementation)
   * @param requestOptions HTTP request options with body data
   * @param header Request headers
   * @returns HTTP response data
   */
  private async executeRequest(requestOptions: http.HttpRequestOptions, header: Record<string, string>): Promise<FTResponseData> {
    // Debug log: Print all HTTP headers including X-Pkg-Id
    FTInnerLogger.d("HttpBuilder", "========== HTTP Request Data ==========");
    FTInnerLogger.d("HttpBuilder", `URL: ${this.getLogUrl()}`);
    FTInnerLogger.d("HttpBuilder", "Headers:");
    Object.keys(header).forEach((key) => {
      FTInnerLogger.d("HttpBuilder", `  ${key}: ${header[key]}`);
    });
    // Highlight X-Pkg-Id for easy verification
    FTInnerLogger.d("HttpBuilder", "===========================================");

    if (this.bodyString) {
      if (requestOptions.extraData instanceof ArrayBuffer) {
        FTInnerLogger.d("HttpBuilder", `Request Body (compressed): original ${this.bodyString.length} -> ${requestOptions.extraData.byteLength} bytes`);
      } else {
        FTInnerLogger.d("HttpBuilder", `Request Body length: ${this.bodyString.length}`);
      }
    }

    // Execute HTTP request
    let httpRequest = http.createHttp();
    let httpResponse = await httpRequest.request(this.getUrl(), requestOptions);

    // FTInnerLogger.d("HttpBuilder", `Response code: ${httpResponse.responseCode}`);
    // FTInnerLogger.d("HttpBuilder", `Response body: ${httpResponse.result}`);

    return new FTResponseData(httpResponse.responseCode, httpResponse.result.toString());
  }

  /**
   * Data sync HTTP request (without compression)
   */
  async executeSync(): Promise<FTResponseData> {
    try {
      // Build request headers
      const header = this.buildRequestHeaders();

      // Build request options
      const requestOptions: http.HttpRequestOptions = {
        method: this.getMethod(),
        connectTimeout: this.sendOutTime,
        readTimeout: this.readOutTime,
        header: header
      };

      // Set request body (uncompressed)
      if (this.bodyString) {
        requestOptions.extraData = this.bodyString;
      }

      // Test mode: return mock response if available
      if (HttpBuilder.testMode && HttpBuilder.mockResponse !== null) {
        this.captureTestRequest(header, requestOptions.extraData as string | ArrayBuffer);
        FTInnerLogger.d("HttpBuilder", "[TEST MODE] Returning mock response");
        return HttpBuilder.mockResponse;
      }

      // Check network connection status
      if (!NetworkUtils.isConnected()) {
        return new FTResponseData(NetCodeStatus.NETWORK_EXCEPTION_CODE, "Network not available");
      }

      return await this.executeRequest(requestOptions, header);

    } catch (error) {
      FTInnerLogger.e("HttpBuilder", `HTTP request failed: ${error}`);
      
      // Return the corresponding status code based on the error type
      if (error.message?.includes('timeout')) {
        return new FTResponseData(NetCodeStatus.FILE_TIMEOUT_CODE, `Request timeout: ${error.message}`);
      } else if (error.message?.includes('network')) {
        return new FTResponseData(NetCodeStatus.NETWORK_EXCEPTION_CODE, `Network error: ${error.message}`);
      } else {
        return new FTResponseData(NetCodeStatus.UNKNOWN_EXCEPTION_CODE, `Unknown error: ${error.message}`);
      }
    }
  }

  /**
   * Data sync HTTP request with compression (deflate)
   * Uses an injected compressor when available, otherwise safely falls back to uncompressed data.
   */
  async executeSyncWithCompression(): Promise<FTResponseData> {
    try {
      // Build request headers
      const header = this.buildRequestHeaders();

      // Build request options
      const requestOptions: http.HttpRequestOptions = {
        method: this.getMethod(),
        connectTimeout: this.sendOutTime,
        readTimeout: this.readOutTime,
        header: header
      };

      // Compress request body if available
      if (this.bodyString) {
        // Check if Content-Encoding header is already set
        if (this.headParams.has(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER)) {
          FTInnerLogger.w("HttpBuilder", "[COMPRESSION] Content-Encoding header already set, using uncompressed data");
          requestOptions.extraData = this.bodyString;
        } else {
          const compressor = HttpBuilder.payloadCompressor;
          if (compressor === null) {
            FTInnerLogger.w("HttpBuilder", "[COMPRESSION] No payload compressor configured, using uncompressed data");
            requestOptions.extraData = this.bodyString;
          } else {
            try {
              const compressedData = await compressor.compress(this.bodyString);

              // Set compressed data as ArrayBuffer
              requestOptions.extraData = compressedData;

              // Add Content-Encoding header only after real compression succeeds.
              header[Constants.SYNC_DATA_CONTENT_ENCODING_HEADER] = compressor.contentEncoding;

              FTInnerLogger.d("HttpBuilder", `[COMPRESSION] Request body compressed: ${this.bodyString.length} -> ${compressedData.byteLength} bytes`);
            } catch (error) {
              FTInnerLogger.e("HttpBuilder", `[COMPRESSION] Compression failed, falling back to uncompressed: ${error}`);
              // Fallback to uncompressed data
              requestOptions.extraData = this.bodyString;
            }
          }
        }
      } else {
        FTInnerLogger.w("HttpBuilder", "[COMPRESSION] No request body to compress");
      }

      // Test mode: return mock response if available
      if (HttpBuilder.testMode && HttpBuilder.mockResponse !== null) {
        this.captureTestRequest(header, requestOptions.extraData as string | ArrayBuffer);
        FTInnerLogger.d("HttpBuilder", "[TEST MODE] Returning mock response");
        return HttpBuilder.mockResponse;
      }

      // Check network connection status
      if (!NetworkUtils.isConnected()) {
        return new FTResponseData(NetCodeStatus.NETWORK_EXCEPTION_CODE, "Network not available");
      }

      return await this.executeRequest(requestOptions, header);

    } catch (error) {
      FTInnerLogger.e("HttpBuilder", `[COMPRESSION] HTTP request failed: ${error}`);
      
      // Return the corresponding status code based on the error type
      if (error.message?.includes('timeout')) {
        return new FTResponseData(NetCodeStatus.FILE_TIMEOUT_CODE, `Request timeout: ${error.message}`);
      } else if (error.message?.includes('network')) {
        return new FTResponseData(NetCodeStatus.NETWORK_EXCEPTION_CODE, `Network error: ${error.message}`);
      } else {
        return new FTResponseData(NetCodeStatus.UNKNOWN_EXCEPTION_CODE, `Unknown error: ${error.message}`);
      }
    }
  }

  /**
   * Set the write timeout
   */
  setSendOutTime(timeout: number): HttpBuilder {
    this.sendOutTime = timeout;
    return this;
  }

  /**
   * Set the read timeout
   */
  setReadOutTime(timeout: number): HttpBuilder {
    this.readOutTime = timeout;
    return this;
  }
}
