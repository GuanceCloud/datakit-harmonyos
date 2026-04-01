/**
 * HTTP request test
 * Reference: com.ft.sdk.tests.HttpTest (Android SDK)
 *
 * @author FT SDK Team
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { HttpBuilder } from '../main/ets/components/http/HttpBuilder';
import { FTResponseData } from '../main/ets/components/http/FTResponseData';
import { FTSDKConfig } from '../main/ets/components/Configs';
import { MockWebServer } from './MockWebServer';
import { MockResponse } from './MockResponse';

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
    });

    afterEach(async () => {
      console.info('HttpTest', 'afterEach called');
      // Shutdown MockWebServer after each test
      await mMockWebServer.shutdown();
      // Disable test mode
      HttpBuilder.disableTestMode();
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
      console.info('HttpTest', 'mockedRequestJSON passed');
    });
  });
}
