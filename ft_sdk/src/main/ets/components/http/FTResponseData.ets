import { FTInnerLogger } from "../log/FTLogger";
import { http } from "@kit.NetworkKit";

export class FTResponseData {
  private static TAG: string = `FTResponseData`;
  /**
   * http code
   */
  private code: number = 0;
  /**
   * Error code. Some values come from Datakit network request errors,
   * and others come from NetCodeStatus.
   */
  private errorCode: string = "";
  /**
   * Brief request error information
   */
  private message: string = "";

  constructor(code: number, data: string) {
    if (code === http.ResponseCode.OK) {
      this.code = code;
      this.message = data;
    } else {
      if (code < http.ResponseCode.BAD_REQUEST) {
        try {
          if (data != null) {
            let jsonObject = JSON.parse(data) as object;
            this.code = jsonObject["code"] || code;
            this.errorCode = jsonObject["errorCode"] || "";

            if (this.errorCode) {
              // dataway error code compatible
              this.errorCode = jsonObject["error_code"] || "";
            }

            this.message = jsonObject["message"] || "";
          }
        } catch (e) {
          //fixme
          if (e instanceof SyntaxError) {
            this.code = code;
            this.message = data;
          } else {
            FTInnerLogger.e(FTResponseData.TAG, e + "");
          }
        }
      } else {
        this.code = code;
        this.message = data;
      }
    }
  }

  getCode(): number {
    return this.code;
  }

  setCode(code: number): void {
    this.code = code;
  }

  getErrorCode(): string {
    return this.errorCode;
  }

  setErrorCode(errorCode: string): void {
    this.errorCode = errorCode;
  }

  getMessage(): string {
    return this.message;
  }

  setMessage(message: string): void {
    this.message = message;
  }
}
