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
  code: string | number;
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
    it('unavailableMethodShouldRemainUnknown', 0, () => {
      const context = createFTNetworkErrorContext('https://example.com', 'UNKNOWN',
        FTNetworkErrorSource.HTTP_CHAIN, new Error('connection refused'));
      expect(context.method).assertEqual('UNKNOWN');
    });

    it('nativeNumericCodesShouldClassifyWithoutEnglishMessages', 0, () => {
      const codes: number[] = [2300005, 2300006, 1007900006, 2300028, 1007900028,
        1007900042, 1007900992, 2300035, 2300058, 2300060, 1007900077, 1007900090,
        2300007, 1007900056, 2300999];
      const kinds: FTNetworkErrorKind[] = [FTNetworkErrorKind.DNS, FTNetworkErrorKind.DNS, FTNetworkErrorKind.DNS,
        FTNetworkErrorKind.TIMEOUT, FTNetworkErrorKind.TIMEOUT, FTNetworkErrorKind.CANCELED, FTNetworkErrorKind.CANCELED,
        FTNetworkErrorKind.CERTIFICATE, FTNetworkErrorKind.CERTIFICATE, FTNetworkErrorKind.CERTIFICATE,
        FTNetworkErrorKind.CERTIFICATE, FTNetworkErrorKind.CERTIFICATE,
        FTNetworkErrorKind.CONNECTION, FTNetworkErrorKind.CONNECTION, FTNetworkErrorKind.UNKNOWN];
      for (let i = 0; i < codes.length; i++) {
        const failure: TestNetworkFailure = { name: 'BusinessError', message: '请求失败', code: codes[i] };
        const context = createFTNetworkErrorContext('https://example.com', 'GET', FTNetworkErrorSource.HTTP_CHAIN, failure);
        expect(context.exception === failure).assertTrue();
        expect(context.errorCode).assertEqual(codes[i]);
        expect(context.kind).assertEqual(kinds[i]);
      }
    });

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
      fields['network_available'] = true;
      fields['network_validated'] = true;
      fields['network_downlink_kbps'] = 999;
      fields['network_uplink_kbps'] = 999;
      fields['network_signal_strength'] = 4;
      fields['NETWORK_AVAILABLE'] = true;
      fields['resource_request_size'] = 1.5;
      fields['resource_http_protocol'] = 'wrong';
      fields['resource_connection_reuse'] = true;
      fields['RESOURCE_HTTP_PROTOCOL'] = 'wrong';

      const sanitized = sanitizeFTNetworkResourceFields(fields);

      expect(Object.keys(sanitized).length).assertEqual(1);
      expect(String(sanitized['handler_reason'])).assertEqual('timeout');
    });
  });
}
