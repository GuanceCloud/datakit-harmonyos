import { Context } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FTCacheFiles, FTCacheMutation } from './FTCacheFiles';
import { FTCacheSettings } from './FTCacheContext';
import { FTDBConfig } from './FTDBConfig';

export interface FTCacheUsage {
  fileBytes: number;
  sqliteBytes: number;
  legacyFileBytes: number;
  spoolBytes: number;
  totalBytes: number;
  capacityBytes: number;
  reserveBytes: number;
  overLimit: boolean;
}

export interface FTCacheStatus {
  mode: string;
  directUpload: boolean;
  sqliteReleased: boolean;
  usage: FTCacheUsage;
  migration: string;
  syncCount: number;
  viewCount: number;
  actionCount: number;
  oldestUuids: string[];
  evicted: number;
  rejected: number;
  corrupt: number;
  projectionPending: boolean;
  shadowHealthy: boolean;
}

/** One physical-byte account; aggregate files are already included in fileBytes. */
export class FTCacheLedger {
  private context: Context;
  private settings: FTCacheSettings;
  private root: string;
  constructor(context: Context, settings: FTCacheSettings, root: string) {
    this.context = context; this.settings = settings; this.root = root;
  }

  usage(): FTCacheUsage {
    const fileBytes = FTCacheFiles.size(this.root);
    const sqliteBytes = this.databaseBytes(this.context.databaseDir);
    const legacyFileBytes = FTCacheFiles.size(`${this.context.filesDir}/ft_sdk_file_store`);
    const spoolBytes = FTCacheFiles.size(`${this.context.filesDir}/ft_sdk_spool`);
    const totalBytes = fileBytes + sqliteBytes + legacyFileBytes + spoolBytes;
    return {
      fileBytes, sqliteBytes, legacyFileBytes, spoolBytes, totalBytes,
      capacityBytes: this.settings.capacity,
      reserveBytes: FTCacheFiles.CONTROL_RESERVE,
      overLimit: this.settings.limitEnabled && totalBytes > this.settings.capacity
    };
  }

  /** Includes the forward journal and largest replacement temp, not just net payload growth. */
  requiredBytes(changes: FTCacheMutation[]): number {
    let growth = 0;
    let largestTemp = 0;
    for (let i = 0; i < changes.length; i++) {
      const change = changes[i];
      if (change.body === null) { continue; }
      const next = FTCacheFiles.bytes(FTCacheFiles.encode(change.body));
      growth += Math.max(0, next - FTCacheFiles.size(change.path));
      largestTemp = Math.max(largestTemp, next);
      // Temporary compatibility projection: payload pages, WAL and page-allocation slack.
      if (change.path.endsWith('/meta/projection.json') && next > 1024) { growth += next * 3 + 128 * 1024; }
    }
    const journal = FTCacheFiles.bytes(FTCacheFiles.encode(JSON.stringify({ version: 1, changes })));
    return growth + largestTemp + journal + FTCacheFiles.CONTROL_RESERVE;
  }

  canReserve(bytes: number): boolean {
    return !this.settings.limitEnabled || this.usage().totalBytes + bytes <= this.settings.capacity;
  }

  private databaseBytes(path: string): number {
    if (!path || !FTCacheFiles.exists(path)) { return 0; }
    let total = 0;
    const names = fs.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      const child = `${path}/${names[i]}`;
      if (fs.statSync(child).isDirectory()) { total += this.databaseBytes(child); }
      else if (names[i].startsWith(FTDBConfig.DATABASE_NAME)) { total += fs.statSync(child).size; }
    }
    return total;
  }
}
