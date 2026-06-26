import axiosBridgeUnitTest from './unit/AxiosBridgeUnit.test';
import httpInterceptorChainUnitTest from './unit/HttpInterceptorChainUnit.test';

export default function testsuite() {
  axiosBridgeUnitTest();
  httpInterceptorChainUnitTest();
}
