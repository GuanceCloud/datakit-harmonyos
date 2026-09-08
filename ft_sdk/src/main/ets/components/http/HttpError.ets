import { BusinessError } from '@kit.BasicServicesKit';

/** Normalized detail retained from HarmonyOS HTTP exceptions. */
export interface HttpErrorDetails {
  code: string;
  message: string;
}

/**
 * HarmonyOS NetworkKit rejects some requests with a BusinessError-shaped
 * object rather than a JavaScript Error. String(error) then only produces
 * "[object Object]", which loses the platform error code needed to diagnose
 * DNS, routing, TLS, and timeout failures.
 */
export function describeHttpError(
  error: Error | BusinessError | object | string | number | boolean | null | undefined
): HttpErrorDetails {
  if (typeof error === 'object' && error !== null) {
    const businessError = error as BusinessError;
    const code = businessError.code === undefined || businessError.code === null ? '' : String(businessError.code);
    const message = businessError.message && businessError.message.length > 0 ?
      businessError.message : fallbackHttpErrorMessage(error);
    return { code, message };
  }
  return { code: '', message: String(error) };
}

export function formatHttpError(error: HttpErrorDetails): string {
  const code = error.code.length > 0 ? error.code : 'unknown';
  return `code=${code}, message=${error.message}`;
}

function fallbackHttpErrorMessage(error: object): string {
  const value = String(error);
  return value === '[object Object]' ? 'No platform error message' : value;
}
