/**
 * Races one Worker-owned HTTP request against its soft timeout.  The request
 * destruction callback stays outside the Host so a stalled upload cannot keep
 * the DataUpload Worker command alive until the manager hard timeout.
 */
export async function awaitDataUploadHttpResult<T>(
  requestTask: Promise<T>,
  softTimeoutMs: number,
  destroyRequest: () => void,
  createTimeoutResult: () => T
): Promise<T> {
  let timeoutId = -1;
  const timeoutTask = new Promise<T>((resolve: (value: T) => void) => {
    timeoutId = setTimeout(() => {
      try {
        destroyRequest();
      } catch (_) {
      }
      resolve(createTimeoutResult());
    }, softTimeoutMs) as number;
  });
  try {
    return await Promise.race([requestTask, timeoutTask]);
  } finally {
    if (timeoutId >= 0) {
      clearTimeout(timeoutId);
    }
  }
}
