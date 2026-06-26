import { FTResponseData } from '@guancecloud/ft_sdk/src/main/ets/components/http/FTResponseData';
import {
  HttpBuilder,
  HttpBuilderTestRequest
} from '@guancecloud/ft_sdk/src/main/ets/components/http/HttpBuilder';
import { WaitUtils } from './WaitUtils';

export class ExtMockCollector {
  constructor(code: number = 200, body: string = '') {
    this.setResponse(code, body);
  }

  start(): void {
    HttpBuilder.enableTestMode();
    HttpBuilder.resetCapturedRequests();
  }

  stop(): void {
    HttpBuilder.disableTestMode();
  }

  setResponse(code: number, body: string = ''): void {
    HttpBuilder.setMockResponse(new FTResponseData(code, body));
  }

  clearRequests(): void {
    HttpBuilder.resetCapturedRequests();
  }

  getRequests(): HttpBuilderTestRequest[] {
    return HttpBuilder.getCapturedRequests();
  }

  async waitForPayloadContaining(fragments: string[], timeoutMs: number = 5000): Promise<string> {
    let payload = '';
    const found = await WaitUtils.waitUntil(async () => {
      const requests = this.getRequests();
      for (const request of requests) {
        if (this.containsAll(request.bodyString, fragments)) {
          payload = request.bodyString;
          return true;
        }
      }
      return false;
    }, timeoutMs);
    return found ? payload : '';
  }

  private containsAll(value: string, fragments: string[]): boolean {
    for (const fragment of fragments) {
      if (!value.includes(fragment)) {
        return false;
      }
    }
    return true;
  }
}
