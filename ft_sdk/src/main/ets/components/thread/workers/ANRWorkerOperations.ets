import fs, { ReadOptions } from '@ohos.file.fs';
import buffer from '@ohos.buffer';
import {
  SDKANRParseRequestDTO,
  SDKANRParseResultDTO,
  SDKStringRecord
} from '../SDKWorkerProtocol';

const DEFAULT_MAX_FILE_BYTES = 50_000;
const DEFAULT_MAX_FILES_PER_DIRECTORY = 5;
const DEFAULT_MAX_EXTERNAL_FILES = 10;
const DEFAULT_MAX_OUTPUT_LENGTH = 256_000;
const MAX_DIRECTORY_ENTRIES_TO_SCAN = 256;
const DEFAULT_SYSTEM_LOG_DIRS: string[] = [
  '/data/storage/el2/log/resourcelimit',
  '/data/storage/el2/log',
  '/data/log/faultlog/temp'
];

interface LimitedFileContent {
  content: string;
  fileSize: number;
  truncated: boolean;
}

interface ANROutputBuilder {
  value: string;
  limit: number;
  capped: boolean;
}

interface DirectoryLogFiles {
  paths: string[];
  totalMatches: number;
}

/** Runs only inside ANRWorker. All synchronous file APIs are isolated here. */
export function parseANREventInWorker(payload: SDKANRParseRequestDTO): SDKANRParseResultDTO {
  const params = payload && payload.params ?
    payload.params as Record<string, Object> : new Object() as Record<string, Object>;
  const maxFileBytes = normalizeLimit(payload.maxFileBytes, DEFAULT_MAX_FILE_BYTES, 1024, 100_000);
  const maxFilesPerDirectory = normalizeLimit(
    payload.maxFilesPerDirectory,
    DEFAULT_MAX_FILES_PER_DIRECTORY,
    1,
    10
  );
  const maxExternalFiles = normalizeLimit(payload.maxExternalFiles, DEFAULT_MAX_EXTERNAL_FILES, 1, 20);
  const maxOutputLength = normalizeLimit(payload.maxOutputLength, DEFAULT_MAX_OUTPUT_LENGTH, 16_000, 512_000);
  const output: ANROutputBuilder = {
    value: '',
    limit: maxOutputLength,
    capped: false
  };
  let filesRead = 0;
  let truncatedFiles = 0;

  appendOutput(output, `App freeze detected: ${payload.eventName || 'APP_FREEZE'}\n\n`);
  appendScalarLine(output, 'Freeze Type', params['freeze_type']);
  appendException(output, params['exception']);
  appendHilog(output, params['hilog']);
  appendEventHandler(output, params['event_handler']);

  const stackTrace = extractStackTrace(params);
  if (stackTrace.length > 0) {
    appendOutput(output, `\n${stackTrace}\n`);
  } else {
    appendOutput(output, '\nStack Trace: Not available (HarmonyOS system event does not provide stack trace)\n');
  }

  if (params['bundle_name'] !== undefined && params['bundle_name'] !== null) {
    let bundleLine = `Bundle: ${String(params['bundle_name'])}`;
    if (params['bundle_version'] !== undefined && params['bundle_version'] !== null) {
      bundleLine += ` (${String(params['bundle_version'])})`;
    }
    appendOutput(output, `${bundleLine}\n`);
  }
  appendScalarLine(output, 'Foreground', params['foreground']);

  const externalPaths = getExternalLogPaths(params['external_log'], maxExternalFiles);
  if (externalPaths.length > 0) {
    appendOutput(output, `\nSystem Log Files (${externalPaths.length} files):\n`);
    for (let i = 0; i < externalPaths.length && !output.capped; i++) {
      const result = readSystemLogFileLimited(externalPaths[i], maxFileBytes);
      if (result.content.length === 0) {
        appendOutput(output, `\n--- File ${i + 1}: ${externalPaths[i]} (empty or cannot read) ---\n`);
        continue;
      }
      filesRead++;
      if (result.truncated) {
        truncatedFiles++;
      }
      appendOutput(output, `\n--- File ${i + 1}: ${externalPaths[i]} ---\n`);
      appendOutput(output, result.content);
      appendTruncationNotice(output, result, maxFileBytes);
      appendOutput(output, `\n--- End of File ${i + 1} ---\n`);
    }
  }

  const systemLogDirs = payload.systemLogDirs === undefined ? DEFAULT_SYSTEM_LOG_DIRS : payload.systemLogDirs;
  for (let dirIndex = 0; dirIndex < systemLogDirs.length && !output.capped; dirIndex++) {
    const directory = systemLogDirs[dirIndex];
    const logFiles = listLogFilesInDirectory(directory, ['.log', '.txt'], maxFilesPerDirectory);
    if (logFiles.paths.length === 0) {
      continue;
    }
    appendOutput(output, `\nSystem Log Directory: ${directory} (${logFiles.totalMatches} files):\n`);
    for (let i = 0; i < logFiles.paths.length && !output.capped; i++) {
      const path = logFiles.paths[i];
      const result = readSystemLogFileLimited(path, maxFileBytes);
      if (result.content.length === 0) {
        continue;
      }
      filesRead++;
      if (result.truncated) {
        truncatedFiles++;
      }
      appendOutput(output, `\n--- File: ${path} ---\n`);
      appendOutput(output, result.content);
      appendTruncationNotice(output, result, maxFileBytes);
      appendOutput(output, '\n--- End of File ---\n');
    }
    if (logFiles.totalMatches > logFiles.paths.length) {
      appendOutput(output, `\n... (${logFiles.totalMatches - logFiles.paths.length} more files in this directory)\n`);
    }
  }

  appendScalarLine(output, 'Event Handler Size (3s)', params['event_handler_size_3s']);
  appendScalarLine(output, 'Event Handler Size (6s)', params['event_handler_size_6s']);
  appendOutput(output, '\n\nKey ANR Info:\n');
  appendKeyInfo(output, 'freeze_type', params['freeze_type']);
  appendKeyInfo(output, 'pid', params['pid']);
  appendKeyInfo(output, 'uid', params['uid']);
  appendKeyInfo(output, 'time', params['time']);
  appendKeyInfo(output, 'uuid', params['uuid']);

  const properties: SDKStringRecord = {};
  copyProperty(properties, 'freeze_type', params['freeze_type']);
  copyProperty(properties, 'bundle_name', params['bundle_name']);
  copyProperty(properties, 'bundle_version', params['bundle_version']);
  copyProperty(properties, 'foreground', params['foreground']);

  return {
    stackTrace: output.value,
    message: 'harmony_anr',
    dateline: payload.dateline,
    foreground: params['foreground'] === true,
    freezeType: params['freeze_type'] === undefined ? '' : String(params['freeze_type']),
    properties,
    missingStack: stackTrace.length === 0,
    filesRead,
    truncatedFiles
  };
}

function extractStackTrace(params: Record<string, Object>): string {
  const threads = params['threads'];
  if (typeof threads === 'string' && threads.length > 0) {
    return threads;
  }
  if (Array.isArray(threads) && threads.length > 0) {
    return formatMainThread(threads as Array<Object>, readValue(params['process_name']));
  }
  if (threads !== null && threads !== undefined && typeof threads === 'object') {
    const thread = threads as Record<string, Object>;
    const direct = readFirstString(thread, ['stack', 'stack_trace', 'trace']);
    return direct.length > 0 ? direct : safeStringify(thread, true);
  }

  const direct = readFirstString(params, ['stack_trace', 'stack', 'trace', 'call_stack', 'backtrace']);
  if (direct.length > 0) {
    return direct;
  }
  const exception = params['exception'] as Record<string, Object>;
  if (exception) {
    const exceptionStack = readFirstString(exception, ['stack']);
    if (exceptionStack.length > 0) {
      return exceptionStack;
    }
  }
  const eventHandler = params['event_handler'];
  return typeof eventHandler === 'string' && eventHandler.length > 0 ? `Event Handler:\n${eventHandler}` : '';
}

function formatMainThread(threads: Array<Object>, processName: string): string {
  let mainThreadIndex = 0;
  for (let i = 0; i < threads.length; i++) {
    const thread = threads[i] as Record<string, Object>;
    const threadName = readValue(thread['thread_name']).toLowerCase();
    if (threadName.includes('main') || (processName.length > 0 && threadName.includes(processName.toLowerCase()))) {
      mainThreadIndex = i;
      break;
    }
  }
  const mainThread = threads[mainThreadIndex] as Record<string, Object>;
  const threadName = readValue(mainThread['thread_name']) || `Thread ${mainThreadIndex}`;
  const threadId = readValue(mainThread['tid']);
  let result = `Main Thread Stack Trace:\nTid:${threadId}, Name:${threadName}\n\n`;
  result += 'Note: Stack trace shows current execution point, not the full call chain.\n';
  result += 'For async operations (setTimeout, Promise), the caller may not appear in the stack.\n\n';

  const frames = mainThread['frames'];
  if (Array.isArray(frames)) {
    for (let i = 0; i < frames.length; i++) {
      const frame = frames[i] as Record<string, Object>;
      const frameNum = `#${String(i).padStart(2, '0')}`;
      if (frame['pc'] && frame['symbol'] && frame['file']) {
        const offset = frame['offset'] !== undefined ? `+${String(frame['offset'])}` : '';
        result += `${frameNum} pc ${String(frame['pc'])} ${String(frame['file'])}(${String(frame['symbol'])}${offset})\n`;
      } else if (frame['file'] && frame['line'] !== undefined) {
        const column = frame['column'] !== undefined ? `:${String(frame['column'])}` : '';
        result += `${frameNum} at ${readValue(frame['symbol']) || 'anonymous'} (${String(frame['file'])}:${
          String(frame['line'])}${column})\n`;
      } else {
        result += `${frameNum} ${safeStringify(frame, false)}\n`;
      }
    }
    return result;
  }
  const direct = readFirstString(mainThread, ['stack', 'stack_trace', 'trace']);
  return result + (direct.length > 0 ? direct : safeStringify(mainThread, true));
}

function appendException(output: ANROutputBuilder, value: Object | undefined): void {
  if (!value || typeof value !== 'object') {
    return;
  }
  const exception = value as Record<string, Object>;
  appendOutput(output, 'Exception:\n');
  appendScalarLine(output, '  Type', exception['type']);
  appendScalarLine(output, '  Message', exception['message']);
}

function appendHilog(output: ANROutputBuilder, value: Object | undefined): void {
  if (!Array.isArray(value) || value.length === 0) {
    return;
  }
  const maxLines = 50;
  const count = Math.min(maxLines, value.length);
  appendOutput(output, `\nRecent Logs (${value.length} total, showing first ${count}):\n`);
  for (let i = 0; i < count; i++) {
    appendOutput(output, `${String(value[i])}\n`);
  }
  if (value.length > count) {
    appendOutput(output, `... (${value.length - count} more lines truncated)\n`);
  }
}

function appendEventHandler(output: ANROutputBuilder, value: Object | undefined): void {
  if (value === undefined || value === null) {
    return;
  }
  let text = '';
  if (typeof value === 'string') {
    text = value;
  } else if (Array.isArray(value)) {
    text = value.map((item: Object) => String(item)).join('\n');
  } else {
    text = safeStringify(value, false);
  }
  if (text.length > 0) {
    appendOutput(output, `\nEvent Handler Information:\n${text}\n`);
  }
}

function getExternalLogPaths(value: Object | undefined, limit: number): string[] {
  const result: string[] = [];
  if (typeof value === 'string' && value.length > 0) {
    result.push(value);
    return result;
  }
  if (!Array.isArray(value)) {
    return result;
  }
  for (let i = 0; i < value.length && result.length < limit; i++) {
    if (typeof value[i] === 'string' && value[i].length > 0) {
      result.push(value[i]);
    }
  }
  return result;
}

function listLogFilesInDirectory(dir: string, suffixes: string[], limit: number): DirectoryLogFiles {
  const result: DirectoryLogFiles = { paths: [], totalMatches: 0 };
  try {
    if (!dir || !fs.accessSync(dir) || !fs.statSync(dir).isDirectory()) {
      return result;
    }
    const names = fs.listFileSync(dir);
    const scanCount = Math.min(names.length, MAX_DIRECTORY_ENTRIES_TO_SCAN);
    for (let i = 0; i < scanCount; i++) {
      const name = names[i];
      if (!matchesSuffix(name, suffixes)) {
        continue;
      }
      const path = `${dir}/${name}`;
      try {
        if (fs.statSync(path).isFile()) {
          result.totalMatches++;
          if (result.paths.length < limit) {
            result.paths.push(path);
          }
        }
      } catch (_) {
      }
    }
  } catch (_) {
  }
  return result;
}

function matchesSuffix(name: string, suffixes: string[]): boolean {
  const normalized = name.toLowerCase();
  for (let i = 0; i < suffixes.length; i++) {
    if (normalized.endsWith(suffixes[i].toLowerCase())) {
      return true;
    }
  }
  return false;
}

function readSystemLogFileLimited(path: string, maxBytes: number): LimitedFileContent {
  const empty: LimitedFileContent = { content: '', fileSize: 0, truncated: false };
  if (!path || path.length === 0) {
    return empty;
  }
  try {
    if (!fs.accessSync(path)) {
      return empty;
    }
    const stat = fs.statSync(path);
    if (!stat.isFile() || stat.size <= 0) {
      return empty;
    }
    const readSize = Math.min(stat.size, maxBytes);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const data = new ArrayBuffer(readSize);
      const options: ReadOptions = { offset: 0, length: readSize };
      const readLen = fs.readSync(file.fd, data, options);
      if (readLen <= 0) {
        return empty;
      }
      return {
        content: buffer.from(data, 0, readLen).toString('utf-8'),
        fileSize: stat.size,
        truncated: stat.size > readLen
      };
    } finally {
      fs.closeSync(file);
    }
  } catch (_) {
    return empty;
  }
}

function appendTruncationNotice(output: ANROutputBuilder, result: LimitedFileContent, maxBytes: number): void {
  if (result.truncated) {
    appendOutput(output, `\n... (file limited to first ${maxBytes} bytes of ${result.fileSize})\n`);
  }
}

function appendOutput(output: ANROutputBuilder, value: string): void {
  if (output.capped || !value || value.length === 0) {
    return;
  }
  const remaining = output.limit - output.value.length;
  if (remaining <= 0) {
    output.capped = true;
    return;
  }
  if (value.length <= remaining) {
    output.value += value;
    return;
  }
  output.value += value.substring(0, remaining);
  output.capped = true;
}

function appendScalarLine(output: ANROutputBuilder, label: string, value: Object | undefined): void {
  if (value !== undefined && value !== null) {
    appendOutput(output, `${label}: ${String(value)}\n`);
  }
}

function appendKeyInfo(output: ANROutputBuilder, label: string, value: Object | undefined): void {
  if (value !== undefined && value !== null) {
    appendOutput(output, `  ${label}: ${String(value)}\n`);
  }
}

function copyProperty(target: SDKStringRecord, key: string, value: Object | undefined): void {
  if (value !== undefined && value !== null) {
    target[key] = String(value);
  }
}

function readFirstString(record: Record<string, Object>, keys: string[]): string {
  if (!record) {
    return '';
  }
  for (let i = 0; i < keys.length; i++) {
    const value = record[keys[i]];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
  }
  return '';
}

function readValue(value: Object | undefined): string {
  return value === undefined || value === null ? '' : String(value);
}

function safeStringify(value: Object, pretty: boolean): string {
  try {
    return JSON.stringify(value, null, pretty ? 2 : 0);
  } catch (_) {
    return String(value);
  }
}

function normalizeLimit(value: number | undefined, fallback: number, minimum: number, maximum: number): number {
  if (value === undefined || value !== value || value <= 0) {
    return fallback;
  }
  return Math.min(maximum, Math.max(minimum, Math.floor(value)));
}
