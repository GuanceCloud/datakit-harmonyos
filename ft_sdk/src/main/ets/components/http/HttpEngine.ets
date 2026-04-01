import * as http from '@ohos.net.http';


export enum NetCodeStatus {
  /**
   * Network issue
   */
  NETWORK_EXCEPTION_CODE = 10001,

  /**
   * Parameter issue
   */
  INVALID_PARAMS_EXCEPTION_CODE = 10002,

  /**
   * File IO issue
   */
  FILE_IO_EXCEPTION_CODE = 10003,

  /**
   * Timeout
   */
  FILE_TIMEOUT_CODE = 10004,

  /**
   * Unknown issue
   */
  UNKNOWN_EXCEPTION_CODE = 11000
}

export class HttpEngine {
}