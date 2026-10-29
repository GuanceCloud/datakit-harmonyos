/**
 * Public contract for handling locally failed automatically tracked requests.
 *
 * A handler can attach fields to the Resource and decide whether the SDK must
 * suppress only the derived `network_error`. It never controls the caller's
 * network request or its thrown exception.
 */

import { FTInnerLogger } from '../log/FTLogger';

const TAG = 'FTNetworkErrorHandler';

/**
 * Callback fields are appended to a Resource after SDK fields are built. Keep
 * that extension point from altering lifecycle identity, RUM associations or
 * built-in Resource measurements.
 */
const RESERVED_RESOURCE_FIELD_NAMES: Set<string> = new Set([
  'resource_id', 'resource_url', 'resource_url_host', 'resource_url_path',
  'resource_url_path_group', 'resource_url_query', 'resource_method',
  'resource_type', 'resource_status', 'resource_status_group',
  'resource_host_ip', 'trace_id', 'span_id', 'session_id', 'session_type',
  'view_id', 'view_name', 'view_referrer', 'action_id', 'action_name',
  'action_type', 'rum_app_id', 'sdk_data_id', 'sdk_name', 'sdk_version',
  'service', 'env', 'version', 'resource_size', 'duration', 'resource_dns',
  'resource_dns_time', 'resource_tcp', 'resource_connect_time',
  'resource_tcp_time', 'resource_ssl', 'resource_ssl_time', 'resource_ttfb',
  'resource_trans', 'resource_first_byte', 'resource_first_byte_time',
  'resource_download_time', 'request_header', 'response_header',
  'response_connection', 'response_content_type', 'response_content_encoding',
  'resource_dns', 'resource_tcp', 'resource_ssl', 'resource_ttfb',
  'resource_trans', 'resource_first_byte', 'resource_download_time',
  'resourcedns', 'resourcetcp', 'resourcessl', 'resourcettfb', 'resourcetrans',
  'resourcefirstbyte', 'resourcedownloadtime', 'resourceload',
  'network_error_kind', 'network_error_message', 'network_error_stack',
  'network_available', 'network_validated', 'network_downlink_kbps',
  'network_uplink_kbps', 'network_signal_strength'
]);

export type FTNetworkErrorRaw = object | string | number | boolean | null | undefined;
export type FTNetworkResourceFieldValue = string | number | boolean | object;
export type FTNetworkResourceFields = Record<string, FTNetworkResourceFieldValue>;

export enum FTNetworkErrorSource {
  RCP = 'rcp',
  HTTP_CHAIN = 'http_chain',
  AXIOS = 'axios'
}

/** Coarse, portable classification. The original exception and code are retained. */
export enum FTNetworkErrorKind {
  DNS = 'dns',
  TIMEOUT = 'timeout',
  CANCELED = 'canceled',
  CERTIFICATE = 'certificate',
  CONNECTION = 'connection',
  UNKNOWN = 'unknown'
}

export interface FTNetworkErrorContext {
  readonly url: string;
  /** UNKNOWN when the transport did not expose a request method. */
  readonly method: string;
  readonly source: FTNetworkErrorSource;
  /** Original platform or client failure. The SDK never wraps this value. */
  readonly exception: FTNetworkErrorRaw;
  readonly errorCode?: string | number;
  readonly kind: FTNetworkErrorKind;
  readonly message: string;
  readonly stack?: string;
}

/**
 * Called only for a local transport failure that has no HTTP response.
 * Return true to suppress the SDK-generated network Error while retaining the
 * completed Resource. Values added to resourceFields are Resource fields.
 */
export interface FTNetworkErrorHandler {
  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean;
}

export interface FTNetworkErrorHandlingResult {
  suppressNetworkError: boolean;
  resourceFields: FTNetworkResourceFields;
}

/** Removes callback fields that could alter SDK-owned Resource data. */
export function sanitizeFTNetworkResourceFields(fields: FTNetworkResourceFields): FTNetworkResourceFields {
  const sanitized: FTNetworkResourceFields = {};
  const keys = Object.keys(fields);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const normalizedKey = key.toLowerCase();
    const value = fields[key];
    if (!key || RESERVED_RESOURCE_FIELD_NAMES.has(normalizedKey) || key.startsWith('_')) {
      FTInnerLogger.w(TAG, `Ignored protected Resource field from network error handler: ${key}`);
      continue;
    }
    if (value === undefined || value === null) {
      continue;
    }
    sanitized[key] = value;
  }
  return sanitized;
}

interface FTNetworkErrorLike {
  code?: string | number;
  name?: string;
  message?: string;
  stack?: string;
}

function getErrorLike(rawError: FTNetworkErrorRaw): FTNetworkErrorLike | null {
  if (typeof rawError !== 'object' || rawError === null) {
    return null;
  }
  return rawError as FTNetworkErrorLike;
}

export function getFTNetworkErrorMessage(rawError: FTNetworkErrorRaw, fallback: string = 'Unknown error'): string {
  const candidate = getErrorLike(rawError);
  if (candidate && candidate.message && candidate.message.length > 0) {
    return candidate.message;
  }
  if (typeof rawError === 'string' && rawError.length > 0) {
    return rawError;
  }
  if (rawError !== undefined && rawError !== null) {
    return String(rawError);
  }
  return fallback;
}

export function getFTNetworkErrorStack(rawError: FTNetworkErrorRaw): string | undefined {
  const candidate = getErrorLike(rawError);
  if (candidate && candidate.stack && candidate.stack.length > 0) {
    return candidate.stack;
  }
  return undefined;
}

export function getFTNetworkErrorCode(rawError: FTNetworkErrorRaw): string | number | undefined {
  const candidate = getErrorLike(rawError);
  if (!candidate || candidate.code === undefined || candidate.code === null) {
    return undefined;
  }
  return candidate.code;
}

export function classifyFTNetworkError(
  rawError: FTNetworkErrorRaw,
  message: string,
  errorCode?: string | number
): FTNetworkErrorKind {
  // NetworkKit and RCP use different prefixes for the same transport codes.
  // Read the documented numeric codes before message heuristics, since native
  // BusinessError messages may be localized or simply say "request failed".
  const numericCode = Number(errorCode);
  const transportCode = numericCode >= 1007900000 && numericCode < 1007901000 ? numericCode - 1007900000 :
    numericCode >= 2300000 && numericCode < 2301000 ? numericCode - 2300000 : -1;
  if (transportCode === 5 || transportCode === 6) return FTNetworkErrorKind.DNS;
  if (transportCode === 28) return FTNetworkErrorKind.TIMEOUT;
  if (transportCode === 42 || numericCode === 1007900992) return FTNetworkErrorKind.CANCELED;
  if ([35, 58, 59, 60, 77, 90].includes(transportCode)) return FTNetworkErrorKind.CERTIFICATE;
  if ([7, 52, 55, 56].includes(transportCode)) return FTNetworkErrorKind.CONNECTION;
  const candidate = getErrorLike(rawError);
  const name = candidate && candidate.name ? candidate.name : '';
  const combined = `${name} ${errorCode === undefined ? '' : String(errorCode)} ${message}`.toLowerCase();
  if (combined.includes('dns') || combined.includes('enotfound') || combined.includes('eai_again') ||
    combined.includes('host not found')) {
    return FTNetworkErrorKind.DNS;
  }
  if (combined.includes('timeout') || combined.includes('timed out') || combined.includes('etimedout') ||
    combined.includes('econnaborted')) {
    return FTNetworkErrorKind.TIMEOUT;
  }
  if (combined.includes('cancel') || combined.includes('abort')) {
    return FTNetworkErrorKind.CANCELED;
  }
  if (combined.includes('certificate') || combined.includes('cert') || combined.includes('tls') || combined.includes('ssl')) {
    return FTNetworkErrorKind.CERTIFICATE;
  }
  if (combined.includes('connection') || combined.includes('network') || combined.includes('refused') ||
    combined.includes('unreachable') || combined.includes('reset')) {
    return FTNetworkErrorKind.CONNECTION;
  }
  return FTNetworkErrorKind.UNKNOWN;
}

export function createFTNetworkErrorContext(
  url: string,
  method: string,
  source: FTNetworkErrorSource,
  rawError: FTNetworkErrorRaw,
  fallbackMessage: string = 'Unknown error',
  fallbackStack?: string,
  fallbackCode?: string | number
): FTNetworkErrorContext {
  const message = getFTNetworkErrorMessage(rawError, fallbackMessage);
  const errorCode = getFTNetworkErrorCode(rawError) ?? fallbackCode;
  const stack = getFTNetworkErrorStack(rawError) ?? fallbackStack;
  return {
    url,
    method,
    source,
    exception: rawError,
    errorCode,
    kind: classifyFTNetworkError(rawError, message, errorCode),
    message,
    stack
  };
}

/**
 * Keeps user code off the request-control path. A failed handler behaves as
 * false and none of its partially written fields are retained.
 */
export function handleFTNetworkError(
  handler: FTNetworkErrorHandler | undefined,
  context: FTNetworkErrorContext
): FTNetworkErrorHandlingResult {
  if (!handler) {
    return { suppressNetworkError: false, resourceFields: {} };
  }

  const fields: FTNetworkResourceFields = {};
  try {
    return {
      suppressNetworkError: handler.onExceptionWithFilter(context, fields) === true,
      resourceFields: sanitizeFTNetworkResourceFields(fields)
    };
  } catch (error) {
    FTInnerLogger.w(TAG,
      `Network error handler failed: source=${context.source}, kind=${context.kind}, error=${String(error)}`);
    return { suppressNetworkError: false, resourceFields: {} };
  }
}
