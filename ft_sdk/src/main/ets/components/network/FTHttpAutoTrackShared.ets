import { Constants } from '../Constants';
import { FTInnerLogger } from '../log/FTLogger';
import { Utils } from '../utils/Utils';

const TAG = "FTHttpAutoTrack";
const FT_RESOURCE_ID_HEADER = 'X-FT-Resource-ID';
const HTTP_METHOD_UNKNOWN = 'UNKNOWN';

export interface PerformanceMetricValue {
  value: number;
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
