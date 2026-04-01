import { http } from '@kit.NetworkKit';
import { applyDefaultFTHttpInterceptorChain } from './FTHttpAutoTrack';
import { StringUtils } from '../utils/StringUtils';

export type FTAxiosMethod =
  | 'get'
  | 'GET'
  | 'post'
  | 'POST'
  | 'put'
  | 'PUT'
  | 'delete'
  | 'DELETE'
  | 'head'
  | 'HEAD'
  | 'options'
  | 'OPTIONS';

export interface FTAxiosRequestConfig {
  url?: string;
  baseURL?: string;
  method?: FTAxiosMethod;
  headers?: Record<string, string>;
  data?: Object | string | ArrayBuffer;
  timeout?: number;
  responseType?: 'json' | 'text' | 'arraybuffer';
  validateStatus?: (status: number) => boolean;
}

export interface FTAxiosResponse {
  data: string | Object | ArrayBuffer;
  status: number;
  statusText: string;
  headers: Record<string, string>;
  config: FTAxiosRequestConfig;
  request: Object;
}

export class FTAxiosAdapterError extends Error {
  code?: string;
  config?: FTAxiosRequestConfig;
  request?: Object;
  response?: FTAxiosResponse;

  constructor(message: string) {
    super(message);
    this.name = 'FTAxiosAdapterError';
  }
}

function buildAxiosAdapterError(
  message: string,
  code?: string,
  config?: FTAxiosRequestConfig,
  request?: Object,
  response?: FTAxiosResponse
): FTAxiosAdapterError {
  const error = new FTAxiosAdapterError(message);
  error.code = code;
  error.config = config;
  error.request = request;
  error.response = response;
  return error;
}

function normalizeAxiosHeaders(headers?: Record<string, string>): Record<string, string> {
  const normalized: Record<string, string> = {};
  if (!headers) {
    return normalized;
  }

  const keys = Object.keys(headers);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    normalized[key] = headers[key];
  }
  return normalized;
}

function normalizeResponseHeaders(headers: Object): Record<string, string> {
  const normalized: Record<string, string> = {};
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

function resolveAxiosUrl(config: FTAxiosRequestConfig): string {
  if (config.url && /^https?:\/\//.test(config.url)) {
    return config.url;
  }

  const baseURL = config.baseURL ?? '';
  const path = config.url ?? '';
  if (baseURL.length === 0) {
    return path;
  }
  if (path.length === 0) {
    return baseURL;
  }

  if (baseURL.endsWith('/') && path.startsWith('/')) {
    return `${baseURL}${path.substring(1)}`;
  }
  if (!baseURL.endsWith('/') && !path.startsWith('/')) {
    return `${baseURL}/${path}`;
  }
  return `${baseURL}${path}`;
}

function mapAxiosMethodToHttp(method?: FTAxiosMethod): http.RequestMethod {
  const normalizedMethod = (method ?? 'GET').toUpperCase();
  switch (normalizedMethod) {
    case 'POST':
      return http.RequestMethod.POST;
    case 'PUT':
      return http.RequestMethod.PUT;
    case 'DELETE':
      return http.RequestMethod.DELETE;
    case 'HEAD':
      return http.RequestMethod.HEAD;
    case 'OPTIONS':
      return http.RequestMethod.OPTIONS;
    case 'GET':
    default:
      return http.RequestMethod.GET;
  }
}

function mapAxiosResponseTypeToHttp(responseType?: 'json' | 'text' | 'arraybuffer'): http.HttpDataType | undefined {
  switch (responseType) {
    case 'arraybuffer':
      return http.HttpDataType.ARRAY_BUFFER;
    case 'json':
      return http.HttpDataType.OBJECT;
    case 'text':
    default:
      return http.HttpDataType.STRING;
  }
}

function normalizeRequestBody(data?: Object | string | ArrayBuffer): string | Object | ArrayBuffer | undefined {
  if (data === undefined || data === null) {
    return undefined;
  }
  if (typeof data === 'string' || data instanceof ArrayBuffer) {
    return data;
  }
  return JSON.stringify(data);
}

function parseAxiosResponseData(
  result: string | Object | ArrayBuffer,
  responseType?: 'json' | 'text' | 'arraybuffer'
): string | Object | ArrayBuffer {
  if (responseType === 'arraybuffer') {
    return result;
  }

  if (typeof result === 'string') {
    if (responseType === 'json') {
      try {
        return JSON.parse(result) as Object;
      } catch (_) {
        return result;
      }
    }
    return result;
  }

  if (result instanceof ArrayBuffer) {
    if (responseType === 'text' || responseType === 'json' || responseType === undefined) {
      const text = StringUtils.unit8ArrayToStr(new Uint8Array(result));
      if (responseType === 'json') {
        try {
          return JSON.parse(text) as Object;
        } catch (_) {
          return text;
        }
      }
      return text;
    }
  }

  return result;
}

function createStatusText(status: number): string {
  return status >= 200 && status < 300 ? 'OK' : `HTTP ${status}`;
}

export type FTAxiosAdapter = (config: FTAxiosRequestConfig) => Promise<FTAxiosResponse>;

export function createFTAxiosAdapter(): FTAxiosAdapter {
  return async (config: FTAxiosRequestConfig): Promise<FTAxiosResponse> => {
    const url = resolveAxiosUrl(config);
    const request = http.createHttp();
    applyDefaultFTHttpInterceptorChain(request);

    const headers = normalizeAxiosHeaders(config.headers);
    const requestOptions: http.HttpRequestOptions = {
      method: mapAxiosMethodToHttp(config.method),
      header: headers
    };

    if (config.timeout !== undefined) {
      requestOptions.connectTimeout = config.timeout;
      requestOptions.readTimeout = config.timeout;
    }

    const responseDataType = mapAxiosResponseTypeToHttp(config.responseType);
    if (responseDataType !== undefined) {
      requestOptions.expectDataType = responseDataType;
    }

    const body = normalizeRequestBody(config.data);
    if (body !== undefined) {
      requestOptions.extraData = body;
      if (!headers['Content-Type'] && !headers['content-type'] && typeof body === 'string') {
        headers['Content-Type'] = 'application/json';
      }
    }

    try {
      const response = await request.request(url, requestOptions);
      const axiosResponse: FTAxiosResponse = {
        data: parseAxiosResponseData(response.result, config.responseType),
        status: response.responseCode || 0,
        statusText: createStatusText(response.responseCode || 0),
        headers: normalizeResponseHeaders(response.header),
        config: config,
        request: request as Object
      };

      const validateStatus = config.validateStatus ?? ((status: number) => status >= 200 && status < 300);
      if (!validateStatus(axiosResponse.status)) {
        throw buildAxiosAdapterError(
          `Request failed with status code ${axiosResponse.status}`,
          'ERR_BAD_RESPONSE',
          config,
          request as Object,
          axiosResponse
        );
      }

      return axiosResponse;
    } catch (error) {
      if (error instanceof FTAxiosAdapterError) {
        throw buildAxiosAdapterError(
          error.message,
          error.code,
          error.config,
          error.request,
          error.response
        );
      }

      throw buildAxiosAdapterError(
        error instanceof Error ? error.message : String(error),
        'ERR_NETWORK',
        config,
        request as Object
      );
    } finally {
      request.destroy();
    }
  };
}
