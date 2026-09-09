import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import { http } from '@kit.NetworkKit';
import axios, { AxiosInstance, AxiosResponse } from '@ohos/axios';
import { applyFTAxiosTrack } from '@guancecloud/ft_sdk/Index';
import { applyFTAxiosChainMethodBridge, createFTHttpInterceptorChain } from '@guancecloud/ft_sdk_ext/Index';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import {
  RumAttributeAssert,
  RumAttributePoint
} from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/RumAttributeAssert';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryWaitUtils } from './helpers/EntryWaitUtils';
import { UiTestUtils } from './helpers/UiTestUtils';

interface AxiosRuntimeTimingResponse {
  performanceTiming?: http.PerformanceTiming;
}

interface AxiosRuntimeErrorResponse {
  status?: number;
  performanceTiming?: http.PerformanceTiming;
}

interface AxiosRuntimeError {
  response?: AxiosRuntimeErrorResponse;
}

class AxiosTimingClientConfig {
  timeout: number = 10000;
  interceptorChain?: http.HttpInterceptorChain;
}

function appendMarker(url: string, marker: string): string {
  const separator = url.includes('?') ? '&' : '?';
  return `${url}${separator}ft_axios_timing=${marker}`;
}

function responseTiming(response: AxiosResponse<string>): http.PerformanceTiming | undefined {
  return (response as Object as AxiosRuntimeTimingResponse).performanceTiming;
}

function assertTimingShape(timing: http.PerformanceTiming | undefined, description: string): http.PerformanceTiming {
  if (timing === undefined) {
    throw new Error(`${description}: @ohos/axios did not expose performanceTiming`);
  }
  const values: number[] = [
    timing.dnsTiming,
    timing.tcpTiming,
    timing.tlsTiming,
    timing.firstSendTiming,
    timing.firstReceiveTiming,
    timing.totalFinishTiming
  ];
  for (let index = 0; index < values.length; index++) {
    expect(Number.isFinite(values[index]) && values[index] >= 0).assertTrue();
  }
  return timing;
}

function createAxiosClient(mode: 'compat' | 'chain'): AxiosInstance {
  const config = new AxiosTimingClientConfig();
  if (mode === 'chain') {
    config.interceptorChain = createFTHttpInterceptorChain({
      enableTraceInterceptor: false,
      enableResourceInterceptor: true
    });
  }
  const client = axios.create(config);
  if (mode === 'compat') {
    applyFTAxiosTrack(client, {
      enableTraceInterceptor: false,
      enableResourceInterceptor: true
    });
  } else {
    applyFTAxiosChainMethodBridge(client);
  }
  return client;
}

async function request(client: AxiosInstance, url: string): Promise<AxiosResponse<string>> {
  return await client.get<string, AxiosResponse<string>, Object>(url);
}

async function waitForResources(url: string, expectedCount: number): Promise<RumAttributePoint[]> {
  let matched: RumAttributePoint[] = [];
  const found = await EntryWaitUtils.waitUntil(async () => {
    const records = await EntryDBAssert.querySyncRecords([DataType.RUM_APP], 1000, true);
    const candidates: RumAttributePoint[] = [];
    for (let index = 0; index < records.length; index++) {
      const record = records[index];
      if (!record.getDataString().startsWith('resource,')) {
        continue;
      }
      const point = RumAttributeAssert.record(record, { measurement: 'resource' });
      if (point.tags.get('resource_url') === url) {
        candidates.push(point);
      }
    }
    matched = candidates;
    return matched.length === expectedCount;
  }, 15000, 150);
  if (!found) {
    throw new Error(`Expected ${expectedCount} Resource record(s) for ${url}, found ${matched.length}`);
  }
  return matched;
}

function assertMappedResource(point: RumAttributePoint, timing: http.PerformanceTiming): void {
  expect(point.fields.get('duration')).assertEqual(timing.totalFinishTiming * 1000000);
  if (timing.firstReceiveTiming > timing.firstSendTiming) {
    expect(point.fields.get('resource_ttfb')).assertEqual(
      (timing.firstReceiveTiming - timing.firstSendTiming) * 1000000
    );
  }
  if (timing.totalFinishTiming > timing.firstReceiveTiming) {
    const rawDownload = point.fields.get('resource_download_time');
    expect(typeof rawDownload).assertEqual('string');
    const download = JSON.parse(String(rawDownload)) as Record<string, number>;
    expect(download['start']).assertEqual(timing.firstReceiveTiming * 1000000);
    expect(download['duration']).assertEqual(
      (timing.totalFinishTiming - timing.firstReceiveTiming) * 1000000
    );
  }
  if (timing.tlsTiming > 0 && timing.totalFinishTiming >= timing.tlsTiming) {
    expect(point.fields.get('resource_trans')).assertEqual(
      (timing.totalFinishTiming - timing.tlsTiming) * 1000000
    );
  }
}

/**
 * Uses real @ohos/axios@2.2.8 requests. It is intentionally opt-in because
 * the device needs caller-controlled HTTP and HTTPS endpoints.
 *
 * Required launch arguments when enabled:
 * - entryAxiosTimingHttpUrl: successful HTTP endpoint
 * - entryAxiosTimingHttpsUrl: successful HTTPS endpoint
 * - entryAxiosTimingClientErrorUrl: endpoint returning HTTP 404
 * - entryAxiosTimingNoResponseUrl: unreachable endpoint
 */
export default function axiosPerformanceTimingE2ETest() {
  if (!UiTestUtils.isAxiosTimingE2EEnabled()) return;

  describe('AxiosPerformanceTimingE2ETest', () => {
    let driver: Driver;
    let httpUrl: string;
    let httpsUrl: string;
    let clientErrorUrl: string;
    let noResponseUrl: string;

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      await EntryDBAssert.resetAll();
      httpUrl = UiTestUtils.requireTestUrl('entryAxiosTimingHttpUrl');
      httpsUrl = UiTestUtils.requireTestUrl('entryAxiosTimingHttpsUrl');
      clientErrorUrl = UiTestUtils.requireTestUrl('entryAxiosTimingClientErrorUrl');
      noResponseUrl = UiTestUtils.requireTestUrl('entryAxiosTimingNoResponseUrl');
    });

    afterEach(async () => {
      await EntryDBAssert.cleanupAll();
    });

    it('compatShouldExposeAndMapHttpAndHttpsPerformanceTiming', 0, async () => {
      const compat = createAxiosClient('compat');
      const httpRequestUrl = appendMarker(httpUrl, `compat_http_${Date.now()}`);
      const httpsRequestUrl = appendMarker(httpsUrl, `compat_https_${Date.now()}`);

      const httpTiming = assertTimingShape(responseTiming(await request(compat, httpRequestUrl)), 'HTTP Compat');
      const httpsTiming = assertTimingShape(responseTiming(await request(compat, httpsRequestUrl)), 'HTTPS Compat');
      assertMappedResource((await waitForResources(httpRequestUrl, 1))[0], httpTiming);
      assertMappedResource((await waitForResources(httpsRequestUrl, 1))[0], httpsTiming);
    });

    it('compatShouldHandleClientErrorNoResponseAndReuseCandidate', 0, async () => {
      const compat = createAxiosClient('compat');
      const clientErrorRequestUrl = appendMarker(clientErrorUrl, `compat_404_${Date.now()}`);
      let clientError: AxiosRuntimeError | undefined;
      try {
        await request(compat, clientErrorRequestUrl);
      } catch (error) {
        clientError = error as AxiosRuntimeError;
      }
      expect(clientError !== undefined).assertTrue();
      expect(clientError!.response!.status).assertEqual(404);
      const clientErrorTiming = assertTimingShape(clientError!.response!.performanceTiming, 'HTTP 404 Compat');
      assertMappedResource((await waitForResources(clientErrorRequestUrl, 1))[0], clientErrorTiming);

      const reuseFirstUrl = appendMarker(httpsUrl, `compat_reuse_one_${Date.now()}`);
      const reuseSecondUrl = appendMarker(httpsUrl, `compat_reuse_two_${Date.now()}`);
      const reuseFirstTiming = assertTimingShape(responseTiming(await request(compat, reuseFirstUrl)), 'Reuse candidate first');
      const reuseSecondTiming = assertTimingShape(responseTiming(await request(compat, reuseSecondUrl)), 'Reuse candidate second');
      assertMappedResource((await waitForResources(reuseFirstUrl, 1))[0], reuseFirstTiming);
      const reusedResource = (await waitForResources(reuseSecondUrl, 1))[0];
      assertMappedResource(reusedResource, reuseSecondTiming);
      if (reuseSecondTiming.dnsTiming === 0 && reuseSecondTiming.tcpTiming === 0 && reuseSecondTiming.tlsTiming === 0) {
        expect(reusedResource.fields.has('resource_dns_time')).assertFalse();
        expect(reusedResource.fields.has('resource_connect_time')).assertFalse();
        expect(reusedResource.fields.has('resource_ssl_time')).assertFalse();
        expect(reusedResource.fields.has('resource_trans')).assertFalse();
      }

      const noResponseRequestUrl = appendMarker(noResponseUrl, `compat_no_response_${Date.now()}`);
      let noResponseError: AxiosRuntimeError | undefined;
      try {
        await request(compat, noResponseRequestUrl);
      } catch (error) {
        noResponseError = error as AxiosRuntimeError;
      }
      expect(noResponseError !== undefined).assertTrue();
      expect(noResponseError!.response === undefined).assertTrue();
      const noResponseResource = (await waitForResources(noResponseRequestUrl, 1))[0];
      expect(noResponseResource.tags.get('resource_status')).assertEqual('0');
      expect(Number(noResponseResource.fields.get('duration')) > 0).assertTrue();
    });

    it('compatAndChainShouldEachCreateExactlyOneResource', 0, async () => {
      const compatUrl = appendMarker(httpsUrl, `compat_single_${Date.now()}`);
      const chainUrl = appendMarker(httpsUrl, `chain_single_${Date.now()}`);
      const compatTiming = assertTimingShape(
        responseTiming(await request(createAxiosClient('compat'), compatUrl)),
        'Compat single Resource'
      );
      const chainTiming = assertTimingShape(
        responseTiming(await request(createAxiosClient('chain'), chainUrl)),
        'Interceptor-chain single Resource'
      );

      const compatResources = await waitForResources(compatUrl, 1);
      const chainResources = await waitForResources(chainUrl, 1);
      expect(compatResources.length).assertEqual(1);
      expect(chainResources.length).assertEqual(1);
      assertMappedResource(compatResources[0], compatTiming);
      assertMappedResource(chainResources[0], chainTiming);
    });
  });
}
