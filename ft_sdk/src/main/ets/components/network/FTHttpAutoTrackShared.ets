import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { NetStatusBean } from '../rum/bean/NetStatusBean';
import { Utils } from '../utils/Utils';
import { FTNetworkErrorHandler } from './FTNetworkErrorHandler';
import { ResourceParams } from '../rum/bean/ResourceParams';

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
  /** Full connection interval, including TLS when available, matching Android. */
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
  // resourceTCP/resource_connect_time retain their legacy names but cover the
  // full connection interval. SSL remains a separately reported subphase.
  const connectionEndTime = tlsEndTime !== undefined ? tlsEndTime : connectEndTime;
  timing.tcpPhase = createTimingPhase(dnsEndTime, connectionEndTime);
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
  /** Integration-provided transport values captured at request start. */
  transportMetrics?: FTResourceTransportMetricsInput;
  /** Low-priority byte estimates calculated from inspectable request data. */
  headerInferredTransportMetrics?: FTResourceTransportMetricsInput;
}

/**
 * Values supplied by an integration that has reliable transport knowledge.
 * Undefined means unknown; zero is a valid byte count.
 */
export interface FTResourceTransportMetricsInput {
  requestBodySize?: number;
  requestHeaderSize?: number;
  requestSize?: number;
  httpProtocol?: string;
  connectionReuse?: boolean;
}

export interface FTResourceTransportMetricsRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | Object | ArrayBuffer;
}

export type FTResourceTransportMetricsProvider = (
  request: FTResourceTransportMetricsRequest
) => FTResourceTransportMetricsInput | undefined;

/**
 * Combines two explicit metric sources for the same request. The latter
 * source wins only for values it actually supplies, so a completion-time
 * protocol does not discard request-start byte counts. This is deliberately
 * not used for platform-vs-integration ordering; ResourceParams owns that
 * priority decision.
 */
export function mergeResourceTransportMetricsInput(
  first?: FTResourceTransportMetricsInput,
  second?: FTResourceTransportMetricsInput
): FTResourceTransportMetricsInput | undefined {
  if (!first && !second) {
    return undefined;
  }
  const result: FTResourceTransportMetricsInput = {};
  const requestBodySize = second && second.requestBodySize !== undefined
    ? second.requestBodySize
    : first?.requestBodySize;
  const requestHeaderSize = second && second.requestHeaderSize !== undefined
    ? second.requestHeaderSize
    : first?.requestHeaderSize;
  const requestSize = second && second.requestSize !== undefined
    ? second.requestSize
    : first?.requestSize;
  const httpProtocol = second && second.httpProtocol !== undefined
    ? second.httpProtocol
    : first?.httpProtocol;
  const connectionReuse = second && second.connectionReuse !== undefined
    ? second.connectionReuse
    : first?.connectionReuse;
  if (requestBodySize !== undefined) {
    result.requestBodySize = requestBodySize;
  }
  if (requestHeaderSize !== undefined) {
    result.requestHeaderSize = requestHeaderSize;
  }
  if (requestSize !== undefined) {
    result.requestSize = requestSize;
  }
  if (httpProtocol !== undefined) {
    result.httpProtocol = httpProtocol;
  }
  if (connectionReuse !== undefined) {
    result.connectionReuse = connectionReuse;
  }
  return result;
}

export function normalizeResourceHttpProtocol(protocol?: string): string | undefined {
  const value = protocol ? protocol.trim().toLowerCase() : '';
  if (value === '1.0' || value === 'http/1.0') {
    return 'http/1.0';
  }
  if (value === '1.1' || value === 'http/1.1') {
    return 'http/1.1';
  }
  if (value === '2' || value === 'h2' || value === 'http/2' || value === 'http/2.0') {
    return 'h2';
  }
  if (value === '3' || value === 'h3' || value === 'http/3' || value === 'http/3.0') {
    return 'h3';
  }
  return undefined;
}

function isKnownTransportSize(size: number | undefined): boolean {
  return size !== undefined && Number.isFinite(size) && size >= 0;
}

/** Apply integration-supplied values without allowing generic properties to override them. */
export function applyIntegrationTransportMetrics(
  params: ResourceParams,
  metrics?: FTResourceTransportMetricsInput
): void {
  if (!metrics) {
    return;
  }
  if (isKnownTransportSize(metrics.requestBodySize)) {
    params.setRequestBodySize(metrics.requestBodySize!);
  }
  if (isKnownTransportSize(metrics.requestHeaderSize)) {
    params.setRequestHeaderSize(metrics.requestHeaderSize!);
  }
  if (isKnownTransportSize(metrics.requestSize)) {
    params.setRequestSize(metrics.requestSize!);
  }
  const httpProtocol = normalizeResourceHttpProtocol(metrics.httpProtocol);
  if (httpProtocol !== undefined) {
    params.setHttpProtocol(httpProtocol);
  }
  if (metrics.connectionReuse !== undefined) {
    params.setConnectionReuse(metrics.connectionReuse);
  }
}

/** Applies platform values returned by an adapter, retaining the top priority. */
export function applyPlatformTransportMetrics(
  params: ResourceParams,
  metrics?: FTResourceTransportMetricsInput
): void {
  if (!metrics) {
    return;
  }
  if (isKnownTransportSize(metrics.requestBodySize)) {
    params.setPlatformRequestBodySize(metrics.requestBodySize!);
  }
  if (isKnownTransportSize(metrics.requestHeaderSize)) {
    params.setPlatformRequestHeaderSize(metrics.requestHeaderSize!);
  }
  if (isKnownTransportSize(metrics.requestSize)) {
    params.setPlatformRequestSize(metrics.requestSize!);
  }
  const httpProtocol = normalizeResourceHttpProtocol(metrics.httpProtocol);
  if (httpProtocol !== undefined) {
    params.setPlatformHttpProtocol(httpProtocol);
  }
  if (metrics.connectionReuse !== undefined) {
    params.setPlatformConnectionReuse(metrics.connectionReuse);
  }
}

/**
 * Applies only the components that can be calculated from inspectable request
 * data. Protocol and connection reuse are never guessed from headers.
 */
export function applyHeaderInferredTransportMetrics(
  params: ResourceParams,
  metrics?: FTResourceTransportMetricsInput
): void {
  if (!metrics) {
    return;
  }
  if (isKnownTransportSize(metrics.requestBodySize)) {
    params.setHeaderInferredRequestBodySize(metrics.requestBodySize!);
  }
  if (isKnownTransportSize(metrics.requestHeaderSize)) {
    params.setHeaderInferredRequestHeaderSize(metrics.requestHeaderSize!);
  }
}

type FTHeaderValue = string | string[];

/**
 * Keeps only serializable HTTP header values. Objects and non-string values
 * are intentionally ignored instead of being coerced with toString().
 */
export function normalizeHeaderValues(headers?: Object | null): Record<string, FTHeaderValue> {
  const normalized: Record<string, FTHeaderValue> = {};
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
    } else if (Array.isArray(value)) {
      const values: string[] = [];
      for (let j = 0; j < value.length; j++) {
        if (typeof value[j] !== 'string') {
          values.length = 0;
          break;
        }
        values.push(value[j] as string);
      }
      if (values.length > 0) {
        normalized[key] = values;
      }
    }
  }
  return normalized;
}

function containsHeaderIgnoreCase(headers: Record<string, FTHeaderValue>, key: string): boolean {
  const normalizedKey = key.toLowerCase();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() === normalizedKey) {
      return true;
    }
  }
  return false;
}

/**
 * Starts from the caller's multi-value headers, then appends interceptor-added
 * headers such as trace/resource identifiers. Existing values are retained
 * because they are already part of the final normalized request.
 */
export function buildHeaderValuesForFinalRequest(
  rawHeaders: Object | null | undefined,
  finalHeaders: Record<string, string>
): Record<string, FTHeaderValue> {
  const result = normalizeHeaderValues(rawHeaders);
  const finalKeys = Object.keys(finalHeaders);
  for (let i = 0; i < finalKeys.length; i++) {
    const key = finalKeys[i];
    if (!containsHeaderIgnoreCase(result, key)) {
      result[key] = finalHeaders[key];
    }
  }
  return result;
}

function utf8ByteLength(value: string): number {
  // Do not use TextEncoder here. In an HTTP interceptor's INITIAL_REQUEST
  // callback, some HarmonyOS runtimes can return undefined from encodeInto,
  // which must not prevent the Resource state from being recorded.
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code <= 0x7f) {
      bytes++;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const next = value.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        i++;
      } else {
        // A lone surrogate is represented by the replacement character in
        // UTF-8, which occupies three bytes.
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function parseNonNegativeDecimal(value: string): number | undefined {
  if (!/^\d+$/.test(value)) {
    return undefined;
  }
  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function getHeaderValuesIgnoreCase(
  headers: Record<string, FTHeaderValue>,
  name: string
): string[] {
  const result: string[] = [];
  const normalizedName = name.toLowerCase();
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].toLowerCase() !== normalizedName) {
      continue;
    }
    const value = headers[keys[i]];
    if (typeof value === 'string') {
      result.push(value);
    } else {
      for (let j = 0; j < value.length; j++) {
        result.push(value[j]);
      }
    }
  }
  return result;
}

/**
 * Uses Content-Length only if all supplied values are valid and agree. It is
 * an on-wire body length fallback for streams or other opaque bodies.
 */
export function getKnownRequestContentLength(headers: Record<string, FTHeaderValue>): number | undefined {
  const values = getHeaderValuesIgnoreCase(headers, 'content-length');
  if (values.length === 0) {
    return undefined;
  }
  let contentLength: number | undefined = undefined;
  for (let i = 0; i < values.length; i++) {
    const parsed = parseNonNegativeDecimal(values[i]);
    if (parsed === undefined || (contentLength !== undefined && contentLength !== parsed)) {
      return undefined;
    }
    contentLength = parsed;
  }
  return contentLength;
}

/**
 * Header byte estimate: UTF-8 bytes for every normalized `Name: Value\\r\\n`
 * line, plus the final CRLF. It excludes the HTTP request line and any HTTP/2
 * header compression, matching the portable request-header serialization
 * contract rather than pretending to know compressed wire bytes.
 */
export function estimateRequestHeaderByteSize(headers: Record<string, FTHeaderValue>): number {
  let total = 2;
  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const values = headers[keys[i]];
    const normalizedValues = typeof values === 'string' ? [values] : values;
    for (let j = 0; j < normalizedValues.length; j++) {
      total += utf8ByteLength(keys[i]) + 2 + utf8ByteLength(normalizedValues[j]) + 2;
    }
  }
  return total;
}

/** Returns an exact byteLength only for ArrayBuffer and TypedArray/DataView. */
export function getKnownBinaryByteLength(body?: Object | ArrayBuffer): number | undefined {
  if (body instanceof ArrayBuffer) {
    return body.byteLength;
  }
  if (body && ArrayBuffer.isView(body)) {
    return body.byteLength;
  }
  return undefined;
}

export function getKnownRequestBodyByteSize(
  body: string | Object | ArrayBuffer | undefined,
  headers: Record<string, FTHeaderValue>
): number | undefined {
  if (typeof body === 'string') {
    return utf8ByteLength(body);
  }
  const binaryLength = getKnownBinaryByteLength(body);
  if (binaryLength !== undefined) {
    return binaryLength;
  }
  return getKnownRequestContentLength(headers);
}

/** Builds low-priority byte estimates without guessing protocol or connection reuse. */
export function createHeaderInferredTransportMetrics(
  rawHeaders: Object | null | undefined,
  finalHeaders: Record<string, string>,
  body?: string | Object | ArrayBuffer
): FTResourceTransportMetricsInput {
  const headers = buildHeaderValuesForFinalRequest(rawHeaders, finalHeaders);
  return {
    requestHeaderSize: estimateRequestHeaderByteSize(headers),
    requestBodySize: getKnownRequestBodyByteSize(body, headers)
  };
}

export interface FTAutoTrackOptions {
  enableTraceInterceptor?: boolean;
  enableResourceInterceptor?: boolean;
  /** Handles local failures only; HTTP responses, including 4xx/5xx, bypass it. */
  /**
   * Overrides FTRUMConfig's default handler for this integration. Pass null
   * to opt this integration out of the configured global default.
   */
  networkErrorHandler?: FTNetworkErrorHandler | null;
  /** Optional per-request source of integration-verified transport metrics. */
  resourceTransportMetricsProvider?: FTResourceTransportMetricsProvider;
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

/**
 * A request can cross more than one automatic interceptor implementation.
 * Claim its completion before invoking a local-failure callback so only the
 * terminal owner reports the Resource and derives its Error.
 */
export class HttpAutoTrackCompletionStore {
  private static instance: HttpAutoTrackCompletionStore | null = null;
  private readonly completedResourceIds: Set<string> = new Set();

  public static getInstance(): HttpAutoTrackCompletionStore {
    if (HttpAutoTrackCompletionStore.instance === null) {
      HttpAutoTrackCompletionStore.instance = new HttpAutoTrackCompletionStore();
    }
    return HttpAutoTrackCompletionStore.instance;
  }

  public tryClaim(resourceId: string): boolean {
    if (!resourceId || resourceId.length === 0 || this.completedResourceIds.has(resourceId)) {
      return false;
    }
    if (this.completedResourceIds.size >= Constants.MAX_MAP_SIZE_RESOURCE) {
      FTInnerLogger.w(TAG, '[HTTP-AutoTrack] completion ledger reached its limit, clearing old completions');
      this.completedResourceIds.clear();
    }
    this.completedResourceIds.add(resourceId);
    return true;
  }

  public clear(): void {
    this.completedResourceIds.clear();
  }

  public size(): number {
    return this.completedResourceIds.size;
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
