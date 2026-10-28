import { describe, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { AsyncCallback, BusinessError } from '@kit.BasicServicesKit';
import { FTHttpRequestObserver } from '../../main/ets/components/network/FTHttpRequestObserver';

class FailingHttpRequest {
  error: BusinessError;

  constructor(error: BusinessError) { this.error = error; }

  request(_url: string, callback: AsyncCallback<http.HttpResponse>): void;
  request(_url: string, options: http.HttpRequestOptions, callback: AsyncCallback<http.HttpResponse>): void;
  request(_url: string, options?: http.HttpRequestOptions): Promise<http.HttpResponse>;
  request(_url: string, options?: http.HttpRequestOptions | AsyncCallback<http.HttpResponse>,
    callback?: AsyncCallback<http.HttpResponse>): void | Promise<http.HttpResponse> {
    const completion = typeof options === 'function' ? options : callback;
    if (completion) {
      completion(this.error, {} as http.HttpResponse);
      return;
    }
    return Promise.reject<http.HttpResponse>(this.error);
  }

  requestInStream(_url: string, callback: AsyncCallback<number>): void;
  requestInStream(_url: string, options: http.HttpRequestOptions, callback: AsyncCallback<number>): void;
  requestInStream(_url: string, options?: http.HttpRequestOptions): Promise<number>;
  requestInStream(_url: string, options?: http.HttpRequestOptions | AsyncCallback<number>,
    callback?: AsyncCallback<number>): void | Promise<number> {
    const completion = typeof options === 'function' ? options : callback;
    if (completion) {
      completion(this.error, 0);
      return;
    }
    return Promise.reject<number>(this.error);
  }
}

export default function httpRequestObserverUnitTest() {
  describe('HttpRequestObserverUnit', () => {
    it('observerShouldNotDefaultAnUnspecifiedMethod', 0, async () => {
      const failure = new Error('native failure') as BusinessError;
      const request = new FailingHttpRequest(failure) as Object as http.HttpRequest;
      let starts = 0;
      const observer = new FTHttpRequestObserver(request, () => {}, () => {}, (_url, options): void => {
        starts++;
        expect(options?.method === undefined).assertTrue();
      });
      const options: http.HttpRequestOptions = {};
      try { await request.request('https://example.com', options); } catch (error) {
        expect(error === failure).assertTrue();
      }
      try { await request.requestInStream('https://example.com'); } catch (error) {
        expect(error === failure).assertTrue();
      }
      expect(starts).assertEqual(2);
      expect(options.method === undefined).assertTrue();
      expect(Object.keys(options).length).assertEqual(0);
      observer.dispose();
    });

    it('observerShouldPreserveRequestAndStreamPromiseFailures', 0, async () => {
      const failure = new Error('native failure') as BusinessError;
      failure.code = 2300006;
      const request = new FailingHttpRequest(failure) as Object as http.HttpRequest;
      const originalRequest = request.request;
      const originalStream = request.requestInStream;
      let calls = 0;
      let settled = 0;
      const observer = new FTHttpRequestObserver(request, error => {
        calls++;
        expect(error === failure).assertTrue();
        // Consumer telemetry failure must not replace the native rejection.
        throw new Error('telemetry failure');
      }, () => { settled++; });
      let rejections = 0;
      try { await request.request('https://example.com'); } catch (error) {
        rejections++;
        expect(error === failure).assertTrue();
      }
      try { await request.requestInStream('https://example.com'); } catch (error) {
        rejections++;
        expect(error === failure).assertTrue();
      }
      expect(rejections).assertEqual(2);
      expect(calls).assertEqual(2);
      expect(settled).assertEqual(2);
      observer.dispose();
      observer.dispose();
      expect(request.request === originalRequest).assertTrue();
      expect(request.requestInStream === originalStream).assertTrue();
    });

    it('observerShouldPreserveAllCallbackOverloads', 0, () => {
      const failure = new Error('native timeout') as BusinessError;
      failure.code = 2300028;
      const request = new FailingHttpRequest(failure) as Object as http.HttpRequest;
      let observed = 0;
      let callbacks = 0;
      const observer = new FTHttpRequestObserver(request, error => {
        observed++;
        expect(error === failure).assertTrue();
      }, () => {});
      const responseCallback: AsyncCallback<http.HttpResponse> = (error, _response): void => {
        callbacks++;
        expect(error === failure).assertTrue();
      };
      const streamCallback: AsyncCallback<number> = (error, _status): void => {
        callbacks++;
        expect(error === failure).assertTrue();
      };
      request.request('https://example.com', responseCallback);
      request.request('https://example.com', {}, responseCallback);
      request.requestInStream('https://example.com', streamCallback);
      request.requestInStream('https://example.com', {}, streamCallback);
      expect(observed).assertEqual(4);
      expect(callbacks).assertEqual(4);
      observer.dispose();
    });
  });
}
