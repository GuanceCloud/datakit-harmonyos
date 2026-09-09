import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheFiles } from './FTCacheFiles';
import { FTCacheFileStore } from './FTCacheFileStore';
import { FTDBTaskPoolRequest, FTDBTaskPoolResponse } from './FTDBTaskPoolExecutor';
import { FTDBSpoolTaskPoolRequest, FTDBSpoolTaskPoolResponse } from './FTDBSpoolTaskPoolExecutor';
import { runFTDBSpoolTaskPoolExecute } from './FTDBSpoolTaskPoolOperations';
import { runFTSqliteTaskPoolExecute } from './FTDBTaskPoolOperations';

interface FTCacheLocation { filesDir: string; databaseDir: string; }

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
    if (request.command === 'append' && request.cache.limitEnabled) {
      await store.reserveSpool(Math.min(8 * 1024 * 1024,
        FTCacheFiles.bytes(JSON.stringify(request.records || [])) * 3 + 4096));
      // Reserve journal + append bytes and the fixed recovery headroom.
      const usage = store.ledger.usage();
      const free = Math.max(0, request.cache.capacity - usage.totalBytes - FTCacheFiles.CONTROL_RESERVE);
      const pending = FTCacheFiles.size(request.spoolDir);
      request.maxCapacityBytes = Math.min(request.maxCapacityBytes || 8 * 1024 * 1024,
        pending + Math.floor(free / 3));
      if (free === 0) { request.maxCapacityBytes = Math.max(1, pending); }
    }
    return await runFTDBSpoolTaskPoolExecute(request);
  } finally {
    try { if (locked) { lock.unlock(); } } finally { fs.closeSync(lock); }
  }
}
