import { describe, beforeAll, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { HttpBuilder, HttpPayloadCompressor } from '../../main/ets/components/http/HttpBuilder';
import { HttpInternalTestAccess } from '../../main/ets/components/internal/testaccess/HttpInternalTestAccess';
import { FTResponseData } from '../../main/ets/components/http/FTResponseData';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';

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
  describe('HttpTest', () => {
    let sdkConfig: FTSDKConfig;

    beforeAll(() => {
      sdkConfig = FTSDKConfig.builder('http://127.0.0.1:8080');
    });

    beforeEach(() => {
      HttpBuilder.enableTestMode();
      HttpBuilder.resetCapturedRequests();
      HttpInternalTestAccess.resetPayloadCompressor();
      HttpBuilder.setMockResponse(new FTResponseData(200, 'ok'));
    });

    afterEach(() => {
      HttpBuilder.disableTestMode();
      HttpBuilder.resetCapturedRequests();
      HttpInternalTestAccess.resetPayloadCompressor();
    });

    it('builderShouldBuildDatakitAndDatawayUrls', 0, () => {
      const datakitBuilder = HttpBuilder.Builder(FTSDKConfig.builder('http://datakit.local')).setModel('rum');
      const datawayConfig = FTSDKConfig.builder('https://dataway.example.com', 'client-token');
      const datawayBuilder = HttpBuilder.Builder(datawayConfig).setModel('logs');
      const emptyModelBuilder = HttpBuilder.Builder(datawayConfig).setModel('  ');
      const remoteConfigBuilder = HttpBuilder.Builder(FTSDKConfig.builder('http://datakit.local'))
        .setModel('v1/env_variable')
        .addQueryParam('app_id', 'rum app/id');

      expect(datakitBuilder.getUrl()).assertEqual('http://datakit.local/rum?precision=ns');
      expect(datawayBuilder.getUrl()).assertEqual('https://dataway.example.com/logs?token=client-token&to_headless=true&precision=ns');
      expect(emptyModelBuilder.getUrl()).assertEqual('https://dataway.example.com');
      expect(remoteConfigBuilder.getUrl()).assertEqual('http://datakit.local/v1/env_variable?precision=ns&app_id=rum%20app%2Fid');
    });

    it('builderShouldCaptureContentType', 0, async () => {
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

    it('compressionShouldFallbackWithoutCodec', 0, async () => {
      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .executeSyncWithCompression();

      const request = HttpBuilder.getLastCapturedRequest();
      expect(request !== null).assertTrue();
      if (request !== null) {
        expect(request.bodyString).assertEqual('payload');
        expect(request.extraData as string).assertEqual('payload');
        expect(Object.keys(request.headers).indexOf(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER)).assertEqual(-1);
      }
    });

    it('compressionShouldUseInjectedCodec', 0, async () => {
      const compressor = new FakePayloadCompressor();
      HttpInternalTestAccess.setPayloadCompressor(compressor);

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
      }
    });

    it('compressionShouldFallbackOnFailure', 0, async () => {
      const compressor = new FakePayloadCompressor(true);
      HttpInternalTestAccess.setPayloadCompressor(compressor);

      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .executeSyncWithCompression();

      const failedRequest = HttpBuilder.getLastCapturedRequest();
      expect(compressor.callCount).assertEqual(1);
      expect(failedRequest !== null).assertTrue();
      if (failedRequest !== null) {
        expect(failedRequest.extraData as string).assertEqual('payload');
        expect(Object.keys(failedRequest.headers).indexOf(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER)).assertEqual(-1);
      }

      const headers: Map<string, string> = new Map();
      headers.set(Constants.SYNC_DATA_CONTENT_ENCODING_HEADER, 'gzip');
      await HttpBuilder.Builder(sdkConfig)
        .setMethod(http.RequestMethod.POST)
        .setBodyString('payload')
        .setHeadParams(headers)
        .executeSyncWithCompression();

      const presetRequest = HttpBuilder.getLastCapturedRequest();
      expect(compressor.callCount).assertEqual(1);
      if (presetRequest !== null) {
        expect(presetRequest.headers[Constants.SYNC_DATA_CONTENT_ENCODING_HEADER]).assertEqual('gzip');
        expect(presetRequest.extraData as string).assertEqual('payload');
      }
    });

    it('responseDataShouldExposeErrorBody', 0, () => {
      const errorBody = '{"message":"bad request","errorCode":"bad_request"}';
      const response = new FTResponseData(400, errorBody);

      expect(response.getCode()).assertEqual(400);
      expect(response.getMessage()).assertEqual(errorBody);
      expect(response.getErrorCode()).assertEqual('');
    });
  });
}
