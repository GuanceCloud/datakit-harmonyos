import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheFileStore } from './FTCacheFileStore';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse } from './FTDBTaskPoolExecutor';
import { FTDBSpoolTaskPoolRequest } from './FTDBSpoolTaskPoolExecutor';
import { runFTDBSpoolTaskPoolExecute } from './FTDBSpoolTaskPoolOperations';
import { runFTSqliteTaskPoolExecute } from './FTDBTaskPoolOperations';

/** Spool shares both the process lane and the cross-process directory lock. */
export async function runFTCacheSpool(object: Object, contextObject: Object): Promise<Object> {
  const request = object as FTDBSpoolTaskPoolRequest;
  if (!request.cache || request.cache.mode === 'sqlite' || !request.filesDir) {
    return await runFTDBSpoolTaskPoolExecute(object);
  }
  const context = contextObject as Context;
  const lock = fs.openSync(`${request.filesDir}/ft_sdk_cache.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
  let locked = false;
  try {
    await lock.lock(true); locked = true;
    const store = new FTCacheFileStore(context, request.cache,
      async (q: FTDBTaskPoolRequest): Promise<FTDBTaskPoolResponse> => {
        return await runFTSqliteTaskPoolExecute(context, q) as FTDBTaskPoolResponse;
      });
    await store.recover();
    return await runFTDBSpoolTaskPoolExecute(request);
  } finally {
    try { if (locked) { lock.unlock(); } } finally { fs.closeSync(lock); }
  }
}
