import { process, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import {
  SDKBackgroundMetricsRequestDTO,
  SDKBackgroundMetricsResultDTO
} from '../SDKWorkerProtocol';

let cachedCpuTickCount = -1;
let cachedCpuAt = 0;
let cachedMemoryUsageBytes = -1;
let cachedMemoryAt = 0;

/** Runs only inside the DataProcessWorker background-metrics command. */
export function collectBackgroundMetricsInWorker(
  payload: SDKBackgroundMetricsRequestDTO
): SDKBackgroundMetricsResultDTO {
  const now = Date.now();
  let cpuTickCount = -1;
  let memoryUsageBytes = -1;
  let batteryCurrent = 0;
  let hasBatteryCurrent = false;
  let cpuFromCache = false;
  let memoryFromCache = false;

  if (payload && payload.collectCpu) {
    const cpuCacheMs = normalizeCacheMs(payload.cpuCacheMs, 5000);
    if (cpuCacheMs > 0 && cachedCpuTickCount >= 0 && now - cachedCpuAt < cpuCacheMs) {
      cpuTickCount = cachedCpuTickCount;
      cpuFromCache = true;
    } else {
      cpuTickCount = readAppCpuTickCount();
      if (cpuTickCount >= 0) {
        cachedCpuTickCount = cpuTickCount;
        cachedCpuAt = now;
      }
    }
  }

  if (payload && payload.collectMemory) {
    const memoryCacheMs = normalizeCacheMs(payload.memoryCacheMs, 3000);
    if (memoryCacheMs > 0 && cachedMemoryUsageBytes >= 0 && now - cachedMemoryAt < memoryCacheMs) {
      memoryUsageBytes = cachedMemoryUsageBytes;
      memoryFromCache = true;
    } else {
      memoryUsageBytes = readAppMemoryUsageBytes();
      if (memoryUsageBytes >= 0) {
        cachedMemoryUsageBytes = memoryUsageBytes;
        cachedMemoryAt = now;
      }
    }
  }

  if (payload && payload.collectBattery) {
    const current = readBatteryCurrent();
    if (current !== undefined) {
      batteryCurrent = current;
      hasBatteryCurrent = true;
    }
  }

  return {
    cpuTickCount,
    memoryUsageBytes,
    batteryCurrent,
    hasBatteryCurrent,
    collectedAt: now,
    cpuFromCache,
    memoryFromCache
  };
}

export function parseProcStatCpuTicks(content: string): number {
  if (!content || content.length === 0) {
    return -1;
  }
  const fields: string[] = [];
  let current = '';
  let inParens = false;
  for (let i = 0; i < content.length; i++) {
    const char = content[i];
    if (char === '(') {
      inParens = true;
      current += char;
    } else if (char === ')') {
      inParens = false;
      current += char;
    } else if (char === ' ' && !inParens) {
      if (current.length > 0) {
        fields.push(current);
        current = '';
      }
    } else {
      current += char;
    }
  }
  if (current.length > 0) {
    fields.push(current);
  }
  if (fields.length <= 14) {
    return -1;
  }
  // Android's CpuUtils#getAppCPUTickCount returns /proc/<pid>/stat field 14
  // (utime) only. Keep the same user-tick definition across SDKs.
  const userTicks = parseInt(fields[13], 10);
  return isNaN(userTicks) ? -1 : userTicks;
}

export function parseProcStatusMemoryBytes(content: string): number {
  if (!content || content.length === 0) {
    return -1;
  }
  const match = content.match(/VmRSS:\s+(\d+)\s+kB/);
  if (!match || match.length <= 1) {
    return -1;
  }
  const memoryKB = parseInt(match[1], 10);
  // Android reports VmRSS in bytes by multiplying the proc value by 1000.
  return isNaN(memoryKB) ? -1 : memoryKB * 1000;
}

export function resetBackgroundMetricsCacheForTest(): void {
  cachedCpuTickCount = -1;
  cachedCpuAt = 0;
  cachedMemoryUsageBytes = -1;
  cachedMemoryAt = 0;
}

function readAppCpuTickCount(): number {
  return parseProcStatCpuTicks(readSmallTextFile(`/proc/${process.pid}/stat`, 2048));
}

function readAppMemoryUsageBytes(): number {
  return parseProcStatusMemoryBytes(readSmallTextFile(`/proc/${process.pid}/status`, 8192));
}

function readBatteryCurrent(): number | undefined {
  try {
    const current = batteryInfo.nowCurrent;
    if (Number.isFinite(current)) {
      return Math.trunc(current);
    }
  } catch (_) {
    // Some device classes do not expose a battery current through BatteryManager.
  }

  const content = readSmallTextFile('/sys/class/power_supply/battery/current_now', 32).trim();
  if (content.length === 0) {
    return undefined;
  }
  const microAmps = parseInt(content, 10);
  return isNaN(microAmps) ? undefined : Math.trunc(microAmps / 1000);
}

function readSmallTextFile(path: string, maxBytes: number): string {
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(maxBytes);
      const readLen = fileIo.readSync(file.fd, data);
      if (readLen <= 0) {
        return '';
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeWithStream(new Uint8Array(data.slice(0, readLen)), { stream: false });
    } finally {
      fileIo.closeSync(file);
    }
  } catch (_) {
    return '';
  }
}

function normalizeCacheMs(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 0) {
    return fallback;
  }
  if (value === 0) {
    return 0;
  }
  return Math.min(60_000, Math.max(1000, Math.floor(value)));
}
