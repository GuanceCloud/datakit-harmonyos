import { http } from '@kit.NetworkKit';
import { SDKUploadHttpRequestDTO } from '../SDKWorkerProtocol';

/** Builds NetworkKit options that are specific to SDK upload transport. */
export function createDataUploadNetworkOptions(request: SDKUploadHttpRequestDTO): http.HttpRequestOptions {
  const options: http.HttpRequestOptions = {
    method: http.RequestMethod.POST,
    connectTimeout: request.connectTimeoutMs,
    readTimeout: request.readTimeoutMs
  };
  if (request.proxy !== undefined) {
    options.usingProxy = {
      host: request.proxy.host,
      port: request.proxy.port,
      exclusionList: request.proxy.exclusionList.slice(),
      username: request.proxy.username,
      password: request.proxy.password
    };
  }
  if (request.dnsServers !== undefined && request.dnsServers.length > 0) {
    options.dnsServers = request.dnsServers.slice(0, 3);
  }
  if (request.dnsOverHttps !== undefined && request.dnsOverHttps.length > 0) {
    options.dnsOverHttps = request.dnsOverHttps;
  }
  return options;
}
