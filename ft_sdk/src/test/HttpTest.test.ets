/**
 * HTTP request test
 * Reference: com.ft.sdk.tests.HttpTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { HttpBuilder, HttpPayloadCompressor } from '../main/ets/components/http/HttpBuilder';
import { FTResponseData } from '../main/ets/components/http/FTResponseData';
import { FTSDKConfig } from '../main/ets/components/Configs';
import { Constants } from '../main/ets/components/Constants';
import { MockWebServer } from './MockWebServer';
import { MockResponse } from './MockResponse';

class FakePayloadCompressor implements HttpPayloadCompressor {
  public contentEncoding: string = 'deflate';
  public callCount: number = 0;
  public lastData: string = '';
  public readonly compressedPayload: ArrayBuffer;
  private shouldFail: boolean;

  constructor(shouldFail: boolean = false) {
    this.shouldFail = shouldFail;
    this.compressedPayload = new ArrayBuffer(3);
    const bytes = new Uint8Array(this.compressedPayload);
    bytes[0] = 1;
    bytes[1] = 2;
    bytes[2] = 3;
  }

  compress(data: string): Promise<ArrayBuffer> {
    this.callCount++;
    this.lastData = data;
    if (this.shouldFail) {
      return Promise.reject(new Error('compression failed'));
    }
    return Promise.resolve(this.compressedPayload);
  }
}

export default function httpTest() {
  /**
   * Simulate successful JSON return
   */
  const SUCCESS_WITH_JSON_RESPONSE: string = "{\"code\":200,\"errorCode\":\"\",\"message\":\"\"}";

  /**
   * Simulate no data return
   */
  const EMPTY_RESPONSE: string = "";
  const FORMAT_REQUEST_HOST_WITH_PORT: string = "http://127.0.0.1:%s/";

  describe('HttpTest', () => {
    let mMockWebServer: MockWebServer;
    let sdkConfig: FTSDKConfig;

    beforeAll(() => {
      console.info('HttpTest', 'beforeAll called');
      // Initialize SDK config for testing
      sdkConfig = FTSDKConfig.builder('http://127.0.0.1:8080');
    });

    beforeEach(async () => {
      console.info('HttpTest', 'beforeEach called');
      // Create MockWebServer before each test
      mMockWebServer = new MockWebServer();
      // Enable test mode for HttpBuilder
      HttpBuilder.enableTestMode();
      HttpBuilder.resetPayloadCompressorForTest();
    });

    afterEach(async () => {
      console.info('HttpTest', 'afterEach called');
      // Shutdown MockWebServer after each test
      await mMockWebServer.shutdown();
      // Disable test mode
      HttpBuilder.disableTestMode();
      HttpBuilder.resetPayloadCompressorForTest();
    });

    afterAll(() => {
      console.info('HttpTest', 'afterAll called');
    });

    /**
     * Simulate network 200 situation
     */
    it('mockedRequest200', 0, async () => {
      const mockResponse: MockResponse = new MockResponse();
      mockResponse.setBody(EMPTY_RESPONSE);
      mockResponse.setResponseCode(200);
      mMockWebServer.enqueue(mockResponse);
      await mMockWebServer.play();

      const url: string = FORMAT_REQUEST_HOST_WITH_PORT.replace("%s", mMockWebServer.getPort().toString());

      // Set mock response for test mode
      const expectedResponse = new FTResponseData(200, EMPTY_RESPONSE);
      HttpBuilder.setMockResponse(expectedResponse);

      const result: FTResponseData = await HttpBuilder.Builder(sdkConfig)
        .setUrl(url)
        .setMethod(http.RequestMethod.POST)
        .setBodyString("")
        .executeSync();

      expect(result.getCode()).assertEqual(200);
      expect(result.getMessage()).assertEqual(EMPTY_RESPONSE);
      expect(mockResponse.toHttpResponse().includes('HTTP/1.1 200 OK')).assertTrue();
      expect(mockResponse.toHttpResponse().includes('Content-Length: 0')).assertTrue();
      console.info('HttpTest', 'mockedRequest200 passed');
    });

    /**
     * Simulate network 400 situation
     */
    it('mockedRequest400', 0, async () => {
      const mockResponse: MockResponse = new MockResponse();
      mockResponse.setBody(EMPTY_RESPONSE);
      mockResponse.setResponseCode(400);
      mMockWebServer.enqueue(mockResponse);
      await mMockWebServer.play();

      const url: string = FORMAT_REQUEST_HOST_WITH_PORT.replace("%s", mMockWebServer.getPort().toString());

      // Set mock response for test mode
      const expectedResponse = new FTResponseData(400, EMPTY_RESPONSE);
      HttpBuilder.setMockResponse(expectedResponse);

      const result: FTResponseData = await HttpBuilder.Builder(sdkConfig)
        .setUrl(url)
        .setMethod(http.RequestMethod.POST)
        .setBodyString("")
        .executeSync();

      expect(result.getCode()).assertEqual(400);
      expect(result.getMessage()).assertEqual(EMPTY_RESPONSE);
      expect(mockResponse.toHttpResponse().includes('HTTP/1.1 400 Bad Request')).assertTrue();
      console.info('HttpTest', 'mockedRequest400 passed');
    });

    /**
     * Simulate network 200 and return data in correct JSON format
     */
    it('mockedRequestJSON', 0, async () => {
      const mockResponse: MockResponse = new MockResponse();
      mockResponse.setBody(SUCCESS_WITH_JSON_RESPONSE);
      mockResponse.setResponseCode(200);
      mMockWebServer.enqueue(mockResponse);
      await mMockWebServer.play();

      const url: string = FORMAT_REQUEST_HOST_WITH_PORT.replace("%s", mMockWebServer.getPort().toString());

      // Set mock response for test mode
      const expectedResponse = new FTResponseData(200, SUCCESS_WITH_JSON_RESPONSE);
      HttpBuilder.setMockResponse(expectedResponse);

      const result: FTResponseData = await HttpBuilder.Builder(sdkConfig)
        .setUrl(url)
        .setMethod(http.RequestMethod.POST)
        .setBodyString("")
        .executeSync();

      expect(result.getCode()).assertEqual(200);
      expect(result.getMessage()).assertEqual(SUCCESS_WITH_JSON_RESPONSE);
      expect(JSON.parse(result.getMessage())['code']).assertEqual(200);
      expect(mockResponse.toHttpResponse().includes('Content-Type: application/json')).assertTrue();
      expect(mockResponse.toHttpResponse().includes(`Content-Length: ${SUCCESS_WITH_JSON_RESPONSE.length}`)).assertTrue();
      console.info('HttpTest', 'mockedRequestJSON passed');
    });

    it('builderShouldPreserveRequestHeadersAndBodyBeforeExecute', 0, () => {
      const headers: Map<string, string> = new Map();
      headers.set('X-Test-Header', 'test-value');

      const builder = HttpBuilder.Builder(sdkConfig)
        .setUrl('http://127.0.0.1:8080')
        .setMethod(http.RequestMethod.POST)
        .setBodyString('body-content')
        .setHeadParams(headers)
        .addHeadParam('X-Second-Header', 'second-value');

      expect(builder.getMethod()).assertEqual(http.RequestMethod.POST);
      expect(builder.getBodyString()).assertEqual('body-content');
      expect(builder.getHeadParams().get('X-Test-Header')).assertEqual('test-value');
      expect(builder.getHeadParams().get('X-Second-Header')).assertEqual('second-value');
    });

    it('builderShouldBuildDatakitAndDatawayUrls', 0, () => {
      const datakitBuilder = HttpBuilder.Builder(FTSDKConfig.builder('http://datakit.local'))
        .setModel('rum');
      const datawayConfig = FTSDKConfig.builder('https://dataway.example.com', 'client-token');
      const datawayBuilder = HttpBuilder.Builder(datawayConfig)
        .setModel('logs');
      const emptyModelBuilder = HttpBuilder.Builder(datawayConfig)
        .setModel('  ');

      expect(datakitBuilder.getHost()).assertEqual('http://datakit.local');
      expect(datakitBuilder.getUrl()).assertEqual('http://datakit.local/rum?precision=ns');
      expect(datawayBuilder.getHost()).assertEqual('https://dataway.example.com');
      expect(datawayBuilder.getUrl()).assertEqual('https://dataway.example.com/logs?token=client-token&to_headless=true&precision=ns');
      expect(emptyModelBuilder.getUrl()).assertEqual('https://dataway.example.com');
    });

    it('builderShouldExposeTimeouts', 0, () => {
      const builder = HttpBuilder.Builder(sdkConfig)
        .setSendOutTime(123)
        .setReadOutTime(456);

      let methodThrown = false;
      try {
        builder.getMethod();
      } catch (error) {
        methodThrown = true;
      }

      expect(methodThrown).assertTrue();
      expect(builder.getSendOutTime()).assertEqual(123);
      expect(builder.getReadOutTime()).assertEqual(456);
      expect(builder.getModel()).assertEqual(null);
      expect(builder.getBodyString()).assertEqual(null);
    });

    it('builderShouldCaptureDefaultAndCustomContentTypeInTestMode', 0, async () => {
      HttpBuilder.resetCapturedRequests();
      expect(HttpBuilder.getLastCapturedRequest()).assertEqual(null);
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .executeSync();

      const customHeaders: Map<string, string> = new Map();
      customHeaders.set('Content-Type', 'application/json');
      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setHeadParams(customHeaders)
        .executeSync();

      const requests = HttpBuilder.getCapturedRequests();
      expect(requests.length).assertEqual(2);
      expect(requests[0].headers['Content-Type']).assertEqual('text/plain');
      expect(requests[1].headers['Content-Type']).assertEqual('application/json');
      expect(requests[0].headers['User-Agent'].length > 0).assertTrue();
      expect(requests[0].headers['Date'].length > 0).assertTrue();
    });

    it('executeSyncWithCompressionShouldFallbackWithoutCompressor', 0, async () => {
      HttpBuilder.resetCapturedRequests();
      HttpBuilder.resetPayloadCompressorForTest();
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .executeSyncWithCompression();

      const request = HttpBuilder.getLastCapturedRequest();
      expect(request !== null).assertTrue();
      if (request !== null) {
        expect(request.bodyString).assertEqual('payload');
        expect(typeof request.extraData).assertEqual('string');
        expect(request.extraData as string).assertEqual('payload');
        expect(Object.keys(request.headers).indexOf(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER)).assertEqual(-1);
      }
    });

    it('executeSyncWithCompressionShouldUseInjectedCompressor', 0, async () => {
      const compressor = new FakePayloadCompressor();
      HttpBuilder.resetCapturedRequests();
      HttpBuilder.setPayloadCompressorForTest(compressor);
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .executeSyncWithCompression();

      const request = HttpBuilder.getLastCapturedRequest();
      expect(request !== null).assertTrue();
      expect(compressor.callCount).assertEqual(1);
      expect(compressor.lastData).assertEqual('payload');
      if (request !== null) {
        expect(request.headers[Constants.SYNC_DATA_CONTENT_ENCODING_HEADER]).assertEqual('deflate');
        expect(request.extraData instanceof ArrayBuffer).assertTrue();
        expect((request.extraData as ArrayBuffer).byteLength).assertEqual(compressor.compressedPayload.byteLength);
      }
    });

    it('executeSyncWithCompressionShouldFallbackWhenCompressorFails', 0, async () => {
      const compressor = new FakePayloadCompressor(true);
      HttpBuilder.resetCapturedRequests();
      HttpBuilder.setPayloadCompressorForTest(compressor);
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .executeSyncWithCompression();

      const request = HttpBuilder.getLastCapturedRequest();
      expect(request !== null).assertTrue();
      expect(compressor.callCount).assertEqual(1);
      if (request !== null) {
        expect(typeof request.extraData).assertEqual('string');
        expect(request.extraData as string).assertEqual('payload');
        expect(Object.keys(request.headers).indexOf(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER)).assertEqual(-1);
      }
    });

    it('executeSyncWithCompressionShouldRespectPresetContentEncoding', 0, async () => {
      const compressor = new FakePayloadCompressor();
      const headers: Map<string, string> = new Map();
      headers.set(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER, 'gzip');
      HttpBuilder.resetCapturedRequests();
      HttpBuilder.setPayloadCompressorForTest(compressor);
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .setHeadParams(headers)
        .executeSyncWithCompression();

      const request = HttpBuilder.getLastCapturedRequest();
      expect(request !== null).assertTrue();
      expect(compressor.callCount).assertEqual(0);
      if (request !== null) {
        expect(request.headers[Constants.SYNC_DATA_CONTENT_ENCODING_HEADER]).assertEqual('gzip');
        expect(typeof request.extraData).assertEqual('string');
        expect(request.extraData as string).assertEqual('payload');
      }
    });

    it('responseDataShouldExposeErrorBodyForBadRequest', 0, () => {
      const errorBody = '{"message":"bad request","errorCode":"bad_request"}';
      const response = new FTResponseData(400, errorBody);

      expect(response.getCode()).assertEqual(400);
      expect(response.getMessage()).assertEqual(errorBody);
      expect(response.getErrorCode()).assertEqual('');
    });
  });
}
