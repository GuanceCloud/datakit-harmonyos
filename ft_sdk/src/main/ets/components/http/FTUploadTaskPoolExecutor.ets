import { http } from '@kit.NetworkKit';
import taskpool from '@ohos.taskpool';
import BuildProfile from '../../../../../BuildProfile';
import { Constants } from '../Constants';
import { NetCodeStatus } from './HttpEngine';

export interface FTUploadHttpConfigDTO {
  datakitUrl: string;
  datawayUrl: string;
  clientToken: string;
}

export interface FTUploadHttpTaskRequest {
  config: FTUploadHttpConfigDTO;
  model: string;
  body: string;
  pkgId: string;
  deviceTimeMs: number;
}

export interface FTUploadHttpTaskResponse {
  code: number;
  message: string;
  errorCode: string;
}

export class FTUploadTaskPoolExecutor {
  public static async execute(request: FTUploadHttpTaskRequest): Promise<FTUploadHttpTaskResponse> {
    const response = await taskpool.execute(ftUploadHttpTaskPoolExecute, request as Object);
    return response as Object as FTUploadHttpTaskResponse;
  }
}

@Concurrent
async function ftUploadHttpTaskPoolExecute(requestObject: Object): Promise<Object> {
  const request = requestObject as FTUploadHttpTaskRequest;
  try {
    const charset = "UTF-8";
    const contentType = "text/plain";
    const connectTimeoutMs = 60000;
    const readTimeoutMs = 60000;
    const headers: Record<string, string> = {};
    headers["User-Agent"] = `${Constants.USER_AGENT};agent_${BuildProfile.HAR_VERSION}`;
    headers["charset"] = charset;
    headers[Constants.SYNC_DATA_CONTENT_TYPE_HEADER] = contentType;
    headers["Date"] = new Date().toUTCString();
    headers[Constants.SYNC_DATA_TRACE_HEADER] = Constants.SYNC_DATA_TRACE_HEADER_FORMAT.replace('%s', request.pkgId);
    headers[Constants.SYNC_DATA_DEVICE_TIME] = String(request.deviceTimeMs);

    const datakitUrl = request.config.datakitUrl || '';
    const datawayUrl = request.config.datawayUrl || '';
    const host = datakitUrl.length > 0 ? datakitUrl : datawayUrl;
    let url = host;
    if (request.model && request.model.trim().length > 0) {
      if (datakitUrl.length > 0) {
        url = `${host}/${request.model}?precision=ns`;
      } else {
        const token = request.config.clientToken || '';
        url = `${host}/${request.model}?token=${token}&to_headless=true&precision=ns`;
      }
    }

    const requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      connectTimeout: connectTimeoutMs,
      readTimeout: readTimeoutMs,
      header: headers
    };
    if (request.body && request.body.length > 0) {
      requestOptions.extraData = request.body;
    }

    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, requestOptions);
    return {
      code: response.responseCode,
      message: response.result.toString(),
      errorCode: ''
    } as FTUploadHttpTaskResponse as Object;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes('timeout')) {
      return {
        code: NetCodeStatus.FILE_TIMEOUT_CODE,
        message: `Request timeout: ${message}`,
        errorCode: ''
      } as FTUploadHttpTaskResponse as Object;
    }
    if (message.includes('network')) {
      return {
        code: NetCodeStatus.NETWORK_EXCEPTION_CODE,
        message: `Network error: ${message}`,
        errorCode: ''
      } as FTUploadHttpTaskResponse as Object;
    }
    return {
      code: NetCodeStatus.UNKNOWN_EXCEPTION_CODE,
      message: `Unknown error: ${message}`,
      errorCode: ''
    } as FTUploadHttpTaskResponse as Object;
  }
}
