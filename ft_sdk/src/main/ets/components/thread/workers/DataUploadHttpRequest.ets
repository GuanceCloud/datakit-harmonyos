import { Constants } from '../../Constants';
import BuildProfile from '../../../../../../BuildProfile';
import { SDKUploadHttpRequestDTO } from '../SDKWorkerProtocol';

/**
 * Builds the headers used by the real DataUploadWorker HTTP request. The content encoding is deliberately
 * omitted unless compression produced a corresponding binary body.
 */
export function createDataUploadHeaders(request: SDKUploadHttpRequestDTO): Record<string, string> {
  const headers: Record<string, string> = {};
  headers['User-Agent'] = `${Constants.USER_AGENT};agent_${BuildProfile.HAR_VERSION}`;
  headers['charset'] = 'UTF-8';
  headers[Constants.SYNC_DATA_CONTENT_TYPE_HEADER] = 'text/plain';
  if (request.compressedBody !== undefined && request.compressedBody.byteLength > 0 && request.contentEncoding) {
    headers[Constants.SYNC_DATA_CONTENT_ENCODING_HEADER] = request.contentEncoding;
  }
  headers['Date'] = new Date().toUTCString();
  headers[Constants.SYNC_DATA_TRACE_HEADER] =
    Constants.SYNC_DATA_TRACE_HEADER_FORMAT.replace('%s', request.packageId);
  headers[Constants.SYNC_DATA_DEVICE_TIME] = String(request.deviceTimeMs);
  return headers;
}

/** Selects the exact data supplied to NetworkKit for the upload request. */
export function getDataUploadRequestBody(request: SDKUploadHttpRequestDTO): string | ArrayBuffer | undefined {
  if (request.compressedBody !== undefined && request.compressedBody.byteLength > 0) {
    return request.compressedBody;
  }
  if (request.body && request.body.length > 0) {
    return request.body;
  }
  return undefined;
}
