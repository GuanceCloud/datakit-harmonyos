import axiosBridgeUnitTest from './unit/AxiosBridgeUnit.test';
import httpInterceptorChainUnitTest from './unit/HttpInterceptorChainUnit.test';
import httpRequestObserverUnitTest from './unit/HttpRequestObserverUnit.test';

export default function testsuite() {
  axiosBridgeUnitTest();
  httpInterceptorChainUnitTest();
  httpRequestObserverUnitTest();
}
