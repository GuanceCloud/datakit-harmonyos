import { describe, it, expect } from '@ohos/hypium';
import {
  createFTNetworkErrorContext,
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkErrorKind,
  FTNetworkErrorSource,
  FTNetworkResourceFields,
  handleFTNetworkError,
  sanitizeFTNetworkResourceFields
} from '../../main/ets/components/network/FTNetworkErrorHandler';

interface TestNetworkFailure {
  name: string;
  message: string;
  code: string;
}

class FilteringNetworkErrorHandler implements FTNetworkErrorHandler {
  public calls: number = 0;
  public lastContext: FTNetworkErrorContext | null = null;

  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    this.calls += 1;
    this.lastContext = context;
    resourceFields['handler_source'] = context.source;
    return context.kind === FTNetworkErrorKind.DNS;
  }
}

class ThrowingNetworkErrorHandler implements FTNetworkErrorHandler {
  onExceptionWithFilter(_context: FTNetworkErrorContext, _resourceFields: FTNetworkResourceFields): boolean {
    throw new Error('planned handler failure');
  }
}

export default function ftNetworkErrorHandlerUnitTest() {
  describe('FTNetworkErrorHandlerUnit', () => {
    it('handlerShouldReceiveOriginalFailureAndFilterDns', 0, () => {
      const rawFailure: TestNetworkFailure = {
        name: 'NetworkError',
        message: 'DNS lookup failed: ENOTFOUND',
        code: 'ENOTFOUND'
      };
      const handler = new FilteringNetworkErrorHandler();
      const context = createFTNetworkErrorContext(
        'https://example.com/resource',
        'GET',
        FTNetworkErrorSource.AXIOS,
        rawFailure
      );

      const result = handleFTNetworkError(handler, context);

      expect(result.suppressNetworkError).assertTrue();
      expect(handler.calls).assertEqual(1);
      expect(handler.lastContext!.exception === rawFailure).assertTrue();
      expect(handler.lastContext!.errorCode).assertEqual('ENOTFOUND');
      expect(String(result.resourceFields['handler_source'])).assertEqual(FTNetworkErrorSource.AXIOS);
    });

    it('handlerFailureShouldKeepDefaultErrorBehavior', 0, () => {
      const context = createFTNetworkErrorContext(
        'https://example.com/resource',
        'POST',
        FTNetworkErrorSource.RCP,
        new Error('timeout')
      );

      const result = handleFTNetworkError(new ThrowingNetworkErrorHandler(), context);

      expect(result.suppressNetworkError).assertFalse();
      expect(Object.keys(result.resourceFields).length).assertEqual(0);
    });

    it('protectedResourceFieldsShouldBeDiscarded', 0, () => {
      const fields: FTNetworkResourceFields = {};
      fields['resource_id'] = 'attempted-override';
      fields['view_id'] = 'attempted-view-override';
      fields['handler_reason'] = 'timeout';

      const sanitized = sanitizeFTNetworkResourceFields(fields);

      expect(Object.keys(sanitized).length).assertEqual(1);
      expect(String(sanitized['handler_reason'])).assertEqual('timeout');
    });
  });
}
