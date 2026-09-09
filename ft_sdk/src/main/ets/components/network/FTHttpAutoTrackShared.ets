import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { NetStatusBean } from '../rum/bean/NetStatusBean';
import { Utils } from '../utils/Utils';

const TAG = "FTHttpAutoTrack";
const FT_RESOURCE_ID_HEADER = 'X-FT-Resource-ID';
const HTTP_METHOD_UNKNOWN = 'UNKNOWN';

export interface PerformanceMetricValue {
  value: number;
}

/**
 * Cumulative NetworkKit timing points. `@ohos/axios` exposes the same shape
 * on supported response adapters, so callers can share one conversion path.
 */
export interface FTNetworkPerformanceTiming {
  dnsTiming?: number;
  tcpTiming?: number;
  tlsTiming?: number;
  firstSendTiming?: number;
  firstReceiveTiming?: number;
  totalFinishTiming?: number;
  redirectTiming?: number;
  responseHeaderTiming?: number;
  responseBodyTiming?: number;
  totalTiming?: number;
}

export interface FTResourceTimingPhase {
  startTime: number;
  duration: number;
}

export interface FTResourceTiming {
  performanceMetrics: Map<string, number>;
  dnsPhase?: FTResourceTimingPhase;
  tcpPhase?: FTResourceTimingPhase;
  sslPhase?: FTResourceTimingPhase;
  ttfbTime?: number;
  transTime?: number;
  firstBytePhase?: FTResourceTimingPhase;
  downloadPhase?: FTResourceTimingPhase;
  loadTime: number;
}

export interface FTCumulativeResourceTimingInput {
  dnsEndTimeMs?: number;
  connectEndTimeMs?: number;
  tlsEndTimeMs?: number;
  firstByteWaitStartTimeMs?: number;
  firstByteTimeMs?: number;
  totalTimeMs?: number;
}

const MS_TO_NS = 1000000;

function readTimePointNs(value: number | undefined): number | undefined {
  if (value === undefined || typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }
  return value * MS_TO_NS;
}

function createTimingPhase(
  startTime: number | undefined,
  endTime: number | undefined
): FTResourceTimingPhase | undefined {
  if (startTime === undefined || endTime === undefined || endTime < startTime) {
    return undefined;
  }
  return {
    startTime,
    duration: endTime - startTime
  };
}

function appendPositiveTimingMetric(metrics: Map<string, number>, key: string, value: number | undefined): void {
  if (value !== undefined && value > 0) {
    metrics.set(key, value);
  }
}

function appendPhaseMetric(
  metrics: Map<string, number>,
  key: string,
  phase: FTResourceTimingPhase | undefined
): void {
  if (phase !== undefined) {
    appendPositiveTimingMetric(metrics, key, phase.duration);
  }
}

function getLastKnownTimePoint(
  first: number | undefined,
  second: number | undefined,
  third: number | undefined
): number | undefined {
  if (third !== undefined) {
    return third;
  }
  if (second !== undefined) {
    return second;
  }
  return first;
}

export function createFallbackFTResourceTiming(fallbackLoadNs: number): FTResourceTiming {
  const performanceMetrics: Map<string, number> = new Map();
  appendPositiveTimingMetric(performanceMetrics, 'resourceLoad', fallbackLoadNs);
  return {
    performanceMetrics,
    loadTime: fallbackLoadNs
  };
}

/**
 * Converts validated cumulative time points into Resource phases. The first
 * byte wait starts at the protocol-provided send/ready point, never at a sum
 * rebuilt from other phase durations. Missing or reversed endpoints leave the
 * derived phase absent rather than fabricating a positive duration.
 */
export function createFTResourceTimingFromCumulative(
  input: FTCumulativeResourceTimingInput,
  fallbackLoadNs: number
): FTResourceTiming {
  const timing = createFallbackFTResourceTiming(fallbackLoadNs);
  const dnsEndTime = readTimePointNs(input.dnsEndTimeMs);
  const rawConnectEndTime = readTimePointNs(input.connectEndTimeMs);
  const connectEndTime = rawConnectEndTime !== undefined &&
    (dnsEndTime === undefined || rawConnectEndTime >= dnsEndTime)
    ? rawConnectEndTime
    : undefined;
  const rawTlsEndTime = readTimePointNs(input.tlsEndTimeMs);
  const tlsEndTime = rawTlsEndTime !== undefined && connectEndTime !== undefined &&
    rawTlsEndTime >= connectEndTime
    ? rawTlsEndTime
    : undefined;

  timing.dnsPhase = createTimingPhase(0, dnsEndTime);
  timing.tcpPhase = createTimingPhase(dnsEndTime, connectEndTime);
  timing.sslPhase = createTimingPhase(connectEndTime, tlsEndTime);
  appendPhaseMetric(timing.performanceMetrics, 'resourceDNS', timing.dnsPhase);
  appendPhaseMetric(timing.performanceMetrics, 'resourceTCP', timing.tcpPhase);
  appendPhaseMetric(timing.performanceMetrics, 'resourceSSL', timing.sslPhase);

  const lastTransportEndTime = getLastKnownTimePoint(dnsEndTime, connectEndTime, tlsEndTime);
  const rawFirstByteWaitStartTime = readTimePointNs(input.firstByteWaitStartTimeMs);
  const firstByteWaitStartTime = rawFirstByteWaitStartTime !== undefined &&
    (lastTransportEndTime === undefined || rawFirstByteWaitStartTime >= lastTransportEndTime)
    ? rawFirstByteWaitStartTime
    : undefined;
  const rawFirstByteTime = readTimePointNs(input.firstByteTimeMs);
  const firstBytePreviousTime = firstByteWaitStartTime !== undefined
    ? firstByteWaitStartTime
    : lastTransportEndTime;
  const firstByteTime = rawFirstByteTime !== undefined &&
    (firstBytePreviousTime === undefined || rawFirstByteTime >= firstBytePreviousTime)
    ? rawFirstByteTime
    : undefined;
  const rawTotalTime = readTimePointNs(input.totalTimeMs);
  const totalPreviousTime = firstByteTime !== undefined
    ? firstByteTime
    : (firstByteWaitStartTime !== undefined ? firstByteWaitStartTime : lastTransportEndTime);
  const totalTime = rawTotalTime !== undefined &&
    (totalPreviousTime === undefined || rawTotalTime >= totalPreviousTime)
    ? rawTotalTime
    : undefined;

  timing.firstBytePhase = createTimingPhase(firstByteWaitStartTime, firstByteTime);
  timing.downloadPhase = createTimingPhase(firstByteTime, totalTime);
  if (timing.firstBytePhase !== undefined) {
    timing.ttfbTime = timing.firstBytePhase.duration;
  }
  // resource_trans always means the valid TLS completion point to request end.
  // A zero TLS point is inapplicable/reused, not a request-local start point.
  if (tlsEndTime !== undefined && tlsEndTime > 0 && totalTime !== undefined) {
    const transPhase = createTimingPhase(tlsEndTime, totalTime);
    if (transPhase !== undefined) {
      timing.transTime = transPhase.duration;
    }
  }

  appendPositiveTimingMetric(timing.performanceMetrics, 'resourceTTFB', timing.ttfbTime);
  appendPositiveTimingMetric(timing.performanceMetrics, 'resourceFirstByte', timing.ttfbTime);
  appendPositiveTimingMetric(timing.performanceMetrics, 'resourceTrans', timing.transTime);
  appendPhaseMetric(timing.performanceMetrics, 'resourceDownloadTime', timing.downloadPhase);
  // A total endpoint that is before the last validated endpoint is internally
  // inconsistent. Keep any independently valid earlier phases, but do not use
  // that total as the Resource duration; the caller's wall-clock fallback is
  // more trustworthy in this case.
  if (totalTime !== undefined) {
    timing.loadTime = totalTime;
    appendPositiveTimingMetric(timing.performanceMetrics, 'resourceLoad', totalTime);
  }
  return timing;
}

/**
 * NetworkKit firstSend/firstReceive are wire-level send/receive points. They
 * are deliberately not treated as RCP preTransfer or response-header points.
 */
export function createFTResourceTimingFromNetworkPerformance(
  performanceTiming: FTNetworkPerformanceTiming | undefined,
  fallbackLoadNs: number
): FTResourceTiming {
  if (performanceTiming === undefined) {
    return createFallbackFTResourceTiming(fallbackLoadNs);
  }
  return createFTResourceTimingFromCumulative({
    dnsEndTimeMs: performanceTiming.dnsTiming,
    connectEndTimeMs: performanceTiming.tcpTiming,
    tlsEndTimeMs: performanceTiming.tlsTiming,
    firstByteWaitStartTimeMs: performanceTiming.firstSendTiming,
    firstByteTimeMs: performanceTiming.firstReceiveTiming,
    totalTimeMs: performanceTiming.totalFinishTiming
  }, fallbackLoadNs);
}

export function createFTNetStatusBean(timing: FTResourceTiming): NetStatusBean {
  const netStatusBean = new NetStatusBean();
  if (timing.dnsPhase !== undefined && timing.dnsPhase.duration > 0) {
    netStatusBean.setDNSStartTime(timing.dnsPhase.startTime);
    netStatusBean.setDNSTime(timing.dnsPhase.duration);
  }
  if (timing.tcpPhase !== undefined && timing.tcpPhase.duration > 0) {
    netStatusBean.setConnectStartTime(timing.tcpPhase.startTime);
    netStatusBean.setTcpTime(timing.tcpPhase.duration);
  }
  if (timing.sslPhase !== undefined && timing.sslPhase.duration > 0) {
    netStatusBean.setSslStartTime(timing.sslPhase.startTime);
    netStatusBean.setSSLTime(timing.sslPhase.duration);
  }
  if (timing.ttfbTime !== undefined && timing.ttfbTime > 0) {
    netStatusBean.setTTFB(timing.ttfbTime);
  }
  if (timing.transTime !== undefined && timing.transTime > 0) {
    netStatusBean.setResponseTime(timing.transTime);
  }
  if (timing.firstBytePhase !== undefined && timing.firstBytePhase.duration > 0) {
    netStatusBean.setFirstByteStartTime(timing.firstBytePhase.startTime);
    netStatusBean.setFirstByteTime(timing.firstBytePhase.duration);
  }
  if (timing.downloadPhase !== undefined && timing.downloadPhase.duration > 0) {
    netStatusBean.setDownloadTimeStart(timing.downloadPhase.startTime);
    netStatusBean.setDownloadTime(timing.downloadPhase.duration);
  }
  netStatusBean.setHoleRequestTime(timing.loadTime);
  return netStatusBean;
}

export interface HttpAutoTrackState {
  resourceId: string;
  url: string;
  method: string;
  startTime: number;
  requestHeaders: Record<string, string>;
  actionId?: string;
}

export interface FTAutoTrackOptions {
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;
}

export class HttpAutoTrackStateStore {
  private static instance: HttpAutoTrackStateStore | null = null;
  private readonly stateMap: Map<string, HttpAutoTrackState> = new Map();

  public static getInstance(): HttpAutoTrackStateStore {
    if (HttpAutoTrackStateStore.instance === null) {
      HttpAutoTrackStateStore.instance = new HttpAutoTrackStateStore();
    }
    return HttpAutoTrackStateStore.instance;
  }

  public put(state: HttpAutoTrackState): void {
    if (this.stateMap.size > Constants.MAX_MAP_SIZE_RESOURCE) {
      FTInnerLogger.w(TAG, `[HTTP-AutoTrack] stateMap size (${this.stateMap.size}) exceeds limit, clearing stale states`);
      this.stateMap.clear();
    }
    this.stateMap.set(state.resourceId, state);
  }

  public get(resourceId: string): HttpAutoTrackState | undefined {
    return this.stateMap.get(resourceId);
  }

  public delete(resourceId: string): void {
    this.stateMap.delete(resourceId);
  }

  public clear(): void {
    this.stateMap.clear();
  }

  public size(): number {
    return this.stateMap.size;
  }
}

export class AxiosChainMethodStore {
  private static instance: AxiosChainMethodStore | null = null;
  private readonly methodMap: Map<string, string> = new Map();

  public static getInstance(): AxiosChainMethodStore {
    if (AxiosChainMethodStore.instance === null) {
      AxiosChainMethodStore.instance = new AxiosChainMethodStore();
    }
    return AxiosChainMethodStore.instance;
  }

  public put(uniqueId: string, method: string): void {
    if (!uniqueId || !method) {
      return;
    }
    if (this.methodMap.size > Constants.MAX_MAP_SIZE_RESOURCE) {
      FTInnerLogger.w(TAG, `[Axios-Chain] methodMap size (${this.methodMap.size}) exceeds limit, clearing stale methods`);
      this.methodMap.clear();
    }
    this.methodMap.set(uniqueId, method);
  }

  public get(uniqueId: string): string | undefined {
    return this.methodMap.get(uniqueId);
  }

  public delete(uniqueId: string): void {
    this.methodMap.delete(uniqueId);
  }

  public clear(): void {
    this.methodMap.clear();
  }

  public size(): number {
    return this.methodMap.size;
  }
}

export function summarizeHeaderKeys(headers: Record<string, string>): string {
  const keys = Object.keys(headers);
  if (keys.length === 0) {
    return '0 headers';
  }
  const preview = keys.slice(0, 5).join(', ');
  return keys.length > 5 ? `${keys.length} headers (${preview}, ...)` : `${keys.length} headers (${preview})`;
}

export function summarizeResponseHeaders(headers: Record<string, string | string[] | undefined>): string {
  const keys = Object.keys(headers);
  if (keys.length === 0) {
    return '0 headers';
  }
  const preview = keys.slice(0, 5).join(', ');
  return keys.length > 5 ? `${keys.length} headers (${preview}, ...)` : `${keys.length} headers (${preview})`;
}

export function summarizePerformanceMetrics(metrics: Map<string, number>): string {
  const keys = Array.from(metrics.keys());
  if (keys.length === 0) {
    return '0 metrics';
  }
  const summary: string[] = [];
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = metrics.get(key);
    if (value !== undefined) {
      summary.push(`${key}=${(value / 1000000).toFixed(2)}ms`);
    }
  }
  return summary.join(', ');
}

export function resolveAxiosChainMethod(headers: Record<string, string>): string {
  const uniqueId = headers[FT_RESOURCE_ID_HEADER] || headers[FT_RESOURCE_ID_HEADER.toLowerCase()];
  if (!uniqueId) {
    return HTTP_METHOD_UNKNOWN;
  }
  const method = AxiosChainMethodStore.getInstance().get(uniqueId);
  return method ?? HTTP_METHOD_UNKNOWN;
}

export function normalizeObjectHeaders(headers?: Object | null): Record<string, string> {
  const normalized: Record<string, string> = {};
  if (!headers) {
    return normalized;
  }

  const rawHeaders = headers as Record<string, Object>;
  const keys = Object.keys(rawHeaders);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = rawHeaders[key];
    if (typeof value === 'string') {
      normalized[key] = value;
    } else if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string') {
      normalized[key] = value[0] as string;
    } else if (value !== undefined && value !== null) {
      normalized[key] = String(value);
    }
  }
  return normalized;
}

export function buildRequestHeaderMap(headers: Record<string, string>): Map<string, string[]> {
  const headerMap = new Map<string, string[]>();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headerMap.set(key, [headers[key]]);
  }
  return headerMap;
}

export function buildResponseHeaderMap(headers: Record<string, string>): Map<string, string[]> {
  const headerMap = new Map<string, string[]>();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headerMap.set(key, [headers[key]]);
  }
  return headerMap;
}

export function ensureHttpResourceId(headers: Record<string, string>): string {
  const existingId = headers[FT_RESOURCE_ID_HEADER] || headers[FT_RESOURCE_ID_HEADER.toLowerCase()];
  if (existingId && existingId.length > 0) {
    headers[FT_RESOURCE_ID_HEADER] = existingId;
    return existingId;
  }
  const generatedId = Utils.generateUUID();
  headers[FT_RESOURCE_ID_HEADER] = generatedId;
  return generatedId;
}

export function buildAutoTrackResourceId(method: string, url: string, uniqueId: string): string {
  return `${method}_${url}_${uniqueId}`;
}

export function extractContentLength(headers: Record<string, string>): number {
  const contentLength = headers['content-length'] || headers['Content-Length'];
  if (!contentLength) {
    return 0;
  }

  if (!/^\d+$/.test(contentLength)) {
    return 0;
  }

  const parsedValue = parseInt(contentLength, 10);
  return isNaN(parsedValue) ? 0 : parsedValue;
}

export function tryGetResponseBodyText(result: string | Object | ArrayBuffer): string | undefined {
  if (typeof result === 'string') {
    return result;
  }
  return undefined;
}

export function tryGetOptionalResponseBodyText(result?: string | Object | ArrayBuffer): string | undefined {
  if (result === undefined) {
    return undefined;
  }
  return tryGetResponseBodyText(result);
}
