/**
 * Public contract for handling locally failed automatically tracked requests.
 *
 * A handler can attach fields to the Resource and decide whether the SDK must
 * suppress only the derived `network_error`. It never controls the caller's
 * network request or its thrown exception.
 */

import { FTInnerLogger } from '../log/FTLogger';

const TAG = 'FTNetworkErrorHandler';

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
  const candidate = getErrorLike(rawError);
  const name = candidate && candidate.name ? candidate.name : '';
  const combined = `${name} ${errorCode === undefined ? '' : String(errorCode)} ${message}`.toLowerCase();
  if (combined.includes('dns') || combined.includes('enotfound') || combined.includes('host not found')) {
    return FTNetworkErrorKind.DNS;
  }
  if (combined.includes('timeout') || combined.includes('timed out') || combined.includes('etimedout')) {
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
      resourceFields: fields
    };
  } catch (error) {
    FTInnerLogger.w(TAG,
      `Network error handler failed: source=${context.source}, kind=${context.kind}, error=${String(error)}`);
    return { suppressNetworkError: false, resourceFields: {} };
  }
}
