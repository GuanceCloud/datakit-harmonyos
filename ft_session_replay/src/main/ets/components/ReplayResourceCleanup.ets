import { BusinessError } from '@kit.BasicServicesKit';

/** Local housekeeping is independent of the server's resource acknowledgement. */
export interface ReplayResourceCleanupResult {
  deletedResources: number;
  deferredResources: number;
  failedResources: number;
  reason: string;
}

export function replayResourceCleanup(
  deletedResources: number = 0, deferredResources: number = 0, failedResources: number = 0, reason: string = ''
): ReplayResourceCleanupResult {
  return { deletedResources, deferredResources, failedResources, reason };
}

export function replayResourceCleanupError(error: Error): string {
  const failure = error as BusinessError;
  return `code=${failure.code ?? 0}, message=${failure.message ?? String(error)}`;
}
