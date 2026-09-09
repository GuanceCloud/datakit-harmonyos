import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SyncDataJSON } from './bean/SyncData';
import { FTCacheFiles } from './FTCacheFiles';
import {
  FT_DB_SPOOL_MAX_BYTES,
  FT_DB_SPOOL_MAX_RECORD_BYTES,
  FT_DB_SPOOL_REPLAY_PAGE_RECORDS,
  FT_DB_SPOOL_REPLAY_PAGE_BYTES
} from './FTDBSpoolLimits';

enum FTDBSpoolTaskPoolCommand {
  INIT = 'init',
  APPEND = 'append',
  PREPARE_REPLAY = 'prepareReplay',
  ACK_REPLAY = 'ackReplay',
  CLEAR = 'clear',
  REMOVE_BY_UUIDS = 'removeByUuids',
  READ_PAGE = 'readPage',
  HAS_MARKER = 'hasMarker',
  WRITE_MARKER = 'writeMarker'
}

interface FTDBSpoolTaskPoolRequest {
  command: FTDBSpoolTaskPoolCommand;
  spoolDir: string;
  activePath: string;
  inflightPath: string;
  legacyPath: string;
  source?: string;
  seqStart?: number;
  records?: SyncDataJSON[];
  batchToken?: string;
  byteOffset?: number;
  recordLimit?: number;
  maxCapacityBytes?: number;
  uuids?: string[];
  readPath?: string;
  markerPath?: string;
}

interface FTDBSpoolRecordDTO {
  source: string;
  seq: number;
  createdAt: number;
  data: SyncDataJSON;
}

interface FTDBSpoolTaskPoolResponse {
  ok: boolean;
  appendedRecords: number;
  rejectedRecords: number;
  pendingRecords: number;
  pendingRecordsKnown: boolean;
  pendingBytes: number;
  capacityBytes: number;
  batchToken: string;
  batchFileRecords: number;
  skippedRecords: number;
  records: FTDBSpoolRecordDTO[];
  pageStartByteOffset: number;
  nextByteOffset: number;
  inflightBytes: number;
  hasMoreRecords: boolean;
  removedRecords: number;
  markerExists: boolean;
  errorMessage: string;
}

interface FTDBSpoolParseResult {
  corruptLines: string[];
  records: FTDBSpoolRecordDTO[];
  fileRecords: number;
  skippedRecords: number;
  nextByteOffset: number;
  fileSize: number;
}

const SPOOL_READ_CHUNK_SIZE = 64 * 1024;
interface FTSpoolAppendJournal { path: string; offset: number; content: string; }

function recoverSpoolAppend(dir: string): void {
  const journalPath = `${dir}/append.json`;
  const body = FTCacheFiles.read(journalPath);
  if (!body) { return; }
  const journal = JSON.parse(body) as FTSpoolAppendJournal;
  if (!journal.path.startsWith(`${dir}/`) || journal.path.includes('/../') || journal.offset < 0) {
    throw new Error('SPOOL_JOURNAL_INVALID');
  }
  const file = fileIo.openSync(journal.path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
  try {
    fileIo.truncateSync(file.fd, journal.offset);
    fileIo.lseek(file.fd, journal.offset, fileIo.WhenceType.SEEK_SET);
    const data = util.TextEncoder.create('utf-8').encodeInto(journal.content);
    let written = 0;
    while (written < data.length) {
      const count = fileIo.writeSync(file.fd, data.slice(written).buffer as ArrayBuffer);
      if (count <= 0) { throw new Error('SPOOL_SHORT_WRITE'); }
      written += count;
    }
    fileIo.fsyncSync(file.fd);
  } finally { fileIo.closeSync(file); }
  FTCacheFiles.syncDirectory(dir);
  FTCacheFiles.remove(journalPath);
}

export async function runFTDBSpoolTaskPoolExecute(requestObject: Object): Promise<Object> {
  const request = requestObject as FTDBSpoolTaskPoolRequest;
  try {
    recoverSpoolAppend(request.spoolDir);
    switch (request.command) {
      case FTDBSpoolTaskPoolCommand.INIT:
        await ensureSpoolDirectory(request.spoolDir);
        return await createPendingResponse(request);
      case FTDBSpoolTaskPoolCommand.APPEND:
        return await appendSpoolRecords(request);
      case FTDBSpoolTaskPoolCommand.PREPARE_REPLAY:
        return await prepareSpoolReplay(request);
      case FTDBSpoolTaskPoolCommand.ACK_REPLAY:
        return await ackSpoolReplay(request);
      case FTDBSpoolTaskPoolCommand.CLEAR:
        return await clearSpoolFiles(request);
      case FTDBSpoolTaskPoolCommand.REMOVE_BY_UUIDS:
        return await removeSpoolRecordsByUuids(request);
      case FTDBSpoolTaskPoolCommand.READ_PAGE:
        return await readSpoolPage(request);
      case FTDBSpoolTaskPoolCommand.HAS_MARKER:
        return await hasMarker(request);
      case FTDBSpoolTaskPoolCommand.WRITE_MARKER:
        return await writeMarker(request);
      default:
        return createErrorResponse(`Unsupported Spool TaskPool command: ${request.command}`) as Object;
    }
  } catch (error) {
    return createErrorResponse(error instanceof Error ? error.message : String(error)) as Object;
  } finally {
    if (FTCacheFiles.exists(request.spoolDir)) { FTCacheFiles.syncDirectory(request.spoolDir); }
  }
}

async function appendSpoolRecords(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const rows = request.records || [];
  if (rows.length === 0) {
    return await createPendingResponse(request);
  }
  await ensureSpoolDirectory(request.spoolDir);
  const now = Date.now();
  const seqStart = Math.max(0, request.seqStart || 0);
  const capacityBytes = normalizeCapacityBytes(request.maxCapacityBytes);
  const pendingBytesBeforeAppend = await countAllPendingBytes(request);
  let availableBytes = Math.max(0, capacityBytes - pendingBytesBeforeAppend);
  const encoder = util.TextEncoder.create('utf-8');
  const acceptedLines: string[] = [];
  let appendedRecords = 0;
  let rejectedRecords = 0;
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (!isValidSyncDataJSON(row)) {
      continue;
    }
    const record: FTDBSpoolRecordDTO = {
      source: request.source || 'db.write.failure',
      seq: seqStart + i,
      createdAt: now,
      data: row
    };
    const line = `${JSON.stringify(record)}\n`;
    const lineBytes = encoder.encodeInto(line).byteLength;
    if (lineBytes > FT_DB_SPOOL_MAX_RECORD_BYTES || lineBytes > availableBytes) {
      rejectedRecords++;
      continue;
    }
    acceptedLines.push(line);
    availableBytes -= lineBytes;
    appendedRecords++;
  }
  if (appendedRecords > 0) {
    const journal: FTSpoolAppendJournal = { path: request.activePath,
      offset: FTCacheFiles.size(request.activePath), content: acceptedLines.join('') };
    FTCacheFiles.atomicWrite(`${request.spoolDir}/append.json`, JSON.stringify(journal));
    recoverSpoolAppend(request.spoolDir);
  }
  const response = createSuccessResponse();
  response.appendedRecords = appendedRecords;
  response.rejectedRecords = rejectedRecords;
  response.pendingRecordsKnown = false;
  response.pendingBytes = await countAllPendingBytes(request);
  response.capacityBytes = capacityBytes;
  return response as Object;
}

async function prepareSpoolReplay(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  await ensureSpoolDirectory(request.spoolDir);
  await removeEmptyFile(request.inflightPath);
  if (!(await pathExists(request.inflightPath))) {
    // A fresh batch must never reuse the token of an already-acknowledged batch.
    FTCacheFiles.remove(`${request.spoolDir}/inflight-token.json`);
    if (await pathExists(request.legacyPath)) {
      await fileIo.rename(request.legacyPath, request.inflightPath);
    } else if (await pathExists(request.activePath)) {
      await fileIo.rename(request.activePath, request.inflightPath);
    }
  }
  if (!(await pathExists(request.inflightPath))) {
    return await createPendingResponse(request);
  }

  const byteOffset = Math.max(0, request.byteOffset || 0);
  const recordLimit = Math.max(1, request.recordLimit || 256);
  const parseResult = readSpoolRecordsPage(request.inflightPath, byteOffset, recordLimit);
  if (parseResult.skippedRecords > 0) {
    // Bounded forensic sample; bad rows cannot block the valid rows following them.
    FTCacheFiles.atomicWrite(`${request.spoolDir}/corrupt.json`, JSON.stringify(parseResult.corruptLines));
  }
  const response = createSuccessResponse();
  response.records = parseResult.records;
  response.batchFileRecords = parseResult.fileRecords;
  response.skippedRecords = parseResult.skippedRecords;
  response.pageStartByteOffset = byteOffset;
  response.nextByteOffset = parseResult.nextByteOffset;
  response.inflightBytes = parseResult.fileSize;
  response.hasMoreRecords = response.nextByteOffset < parseResult.fileSize;
  response.batchToken = await getFileToken(request.inflightPath, true);
  response.pendingRecordsKnown = false;
  response.pendingBytes = await countAllPendingBytes(request);
  response.capacityBytes = FT_DB_SPOOL_MAX_BYTES;
  return response as Object;
}

async function ackSpoolReplay(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const response = createSuccessResponse();
  if (!(await pathExists(request.inflightPath))) {
    response.pendingRecords = await countAllPendingRecords(request);
    response.pendingBytes = await countAllPendingBytes(request);
    return response as Object;
  }
  const actualToken = await getFileToken(request.inflightPath);
  if (!request.batchToken || actualToken !== request.batchToken) {
    return createErrorResponse(
      `Spool inflight token mismatch: expected=${request.batchToken || ''}, actual=${actualToken}`
    ) as Object;
  }
  await fileIo.unlink(request.inflightPath);
  response.pendingRecords = await countAllPendingRecords(request);
  response.pendingBytes = await countAllPendingBytes(request);
  return response as Object;
}

async function clearSpoolFiles(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  await deleteFileIfExists(request.activePath);
  await deleteFileIfExists(request.inflightPath);
  await deleteFileIfExists(request.legacyPath);
  FTCacheFiles.remove(`${request.spoolDir}/corrupt.json`);
  FTCacheFiles.remove(`${request.spoolDir}/inflight-token.json`);
  return createSuccessResponse() as Object;
}

/**
 * Remove committed records from a durable NDJSON queue. This command is used
 * by FileStore; the DB-failure spool only uses append/replay/ack operations.
 */
async function removeSpoolRecordsByUuids(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const uuidSet: Set<string> = new Set<string>();
  const uuids = request.uuids || [];
  for (let i = 0; i < uuids.length; i++) {
    if (uuids[i] && uuids[i].length > 0) {
      uuidSet.add(uuids[i]);
    }
  }
  if (uuidSet.size === 0) {
    return await createPendingResponse(request) as Object;
  }

  const response = createSuccessResponse();
  response.removedRecords += await removeFileRecordsByUuids(request.activePath, uuidSet);
  response.removedRecords += await removeFileRecordsByUuids(request.inflightPath, uuidSet);
  response.removedRecords += await removeFileRecordsByUuids(request.legacyPath, uuidSet);
  response.pendingRecords = await countAllPendingRecords(request);
  response.pendingBytes = await countAllPendingBytes(request);
  response.capacityBytes = normalizeCapacityBytes(request.maxCapacityBytes);
  return response as Object;
}

async function readSpoolPage(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const path = request.readPath || '';
  if (!path || !(await pathExists(path))) {
    return createSuccessResponse() as Object;
  }
  const page = readSpoolRecordsPage(
    path,
    Math.max(0, request.byteOffset || 0),
    Math.max(1, request.recordLimit || 256)
  );
  const response = createSuccessResponse();
  response.records = page.records;
  response.batchFileRecords = page.fileRecords;
  response.skippedRecords = page.skippedRecords;
  response.pageStartByteOffset = Math.max(0, request.byteOffset || 0);
  response.nextByteOffset = page.nextByteOffset;
  response.inflightBytes = page.fileSize;
  response.hasMoreRecords = page.nextByteOffset < page.fileSize;
  return response as Object;
}

async function hasMarker(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const response = createSuccessResponse();
  response.markerExists = !!request.markerPath && await pathExists(request.markerPath);
  return response as Object;
}

async function writeMarker(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  if (!request.markerPath) {
    return createErrorResponse('Marker path is required') as Object;
  }
  await ensureSpoolDirectory(request.spoolDir);
  const file = await fileIo.open(
    request.markerPath,
    fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE
  );
  try {
    await fileIo.write(file.fd, 'complete');
  } finally {
    await fileIo.close(file);
  }
  const response = createSuccessResponse();
  response.markerExists = true;
  return response as Object;
}

async function createPendingResponse(request: FTDBSpoolTaskPoolRequest): Promise<FTDBSpoolTaskPoolResponse> {
  const response = createSuccessResponse();
  response.pendingRecords = await countAllPendingRecords(request);
  response.pendingBytes = await countAllPendingBytes(request);
  response.capacityBytes = normalizeCapacityBytes(request.maxCapacityBytes);
  return response;
}

function createSuccessResponse(): FTDBSpoolTaskPoolResponse {
  return {
    ok: true,
    appendedRecords: 0,
    rejectedRecords: 0,
    pendingRecords: 0,
    pendingRecordsKnown: true,
    pendingBytes: 0,
    capacityBytes: FT_DB_SPOOL_MAX_BYTES,
    batchToken: '',
    batchFileRecords: 0,
    skippedRecords: 0,
    records: [],
    pageStartByteOffset: 0,
    nextByteOffset: 0,
    inflightBytes: 0,
    hasMoreRecords: false,
    removedRecords: 0,
    markerExists: false,
    errorMessage: ''
  };
}

async function removeFileRecordsByUuids(path: string, uuids: Set<string>): Promise<number> {
  if (!(await pathExists(path))) {
    return 0;
  }

  let offset = 0;
  let removed = 0;
  const retainedLines: string[] = [];
  while (true) {
    const page = readSpoolRecordsPage(path, offset, FT_DB_SPOOL_REPLAY_PAGE_RECORDS);
    for (let i = 0; i < page.records.length; i++) {
      const record = page.records[i];
      if (uuids.has(record.data.uuid)) {
        removed++;
      } else {
        retainedLines.push(`${JSON.stringify(record)}\n`);
      }
    }
    if (page.nextByteOffset >= page.fileSize) {
      break;
    }
    if (page.nextByteOffset <= offset) {
      throw new Error(`FileStore remove cursor did not advance: path=${path}, offset=${offset}`);
    }
    offset = page.nextByteOffset;
  }

  if (removed <= 0) {
    return 0;
  }
  if (retainedLines.length === 0) {
    await fileIo.unlink(path);
    return removed;
  }

  const tempPath = `${path}.rewrite`;
  await deleteFileIfExists(tempPath);
  const file = await fileIo.open(
    tempPath,
    fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE
  );
  try {
    await fileIo.write(file.fd, retainedLines.join(''));
  } finally {
    await fileIo.close(file);
  }
  await fileIo.rename(tempPath, path);
  return removed;
}

function createErrorResponse(message: string): FTDBSpoolTaskPoolResponse {
  const response = createSuccessResponse();
  response.ok = false;
  response.errorMessage = message;
  return response;
}

function readSpoolRecordsPage(
  path: string,
  byteOffset: number,
  recordLimit: number
): FTDBSpoolParseResult {
  const result: FTDBSpoolParseResult = {
    corruptLines: [],
    records: [],
    fileRecords: 0,
    skippedRecords: 0,
    nextByteOffset: byteOffset,
    fileSize: 0
  };
  const stat = fileIo.statSync(path);
  result.fileSize = stat.size;
  if (stat.size <= 0) {
    return result;
  }
  if (byteOffset > stat.size) {
    throw new Error(`Spool byte cursor exceeds inflight size: cursor=${byteOffset}, size=${stat.size}`);
  }
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  const decoder = util.TextDecoder.create('utf-8');
  const lineParts: Uint8Array[] = [];
  let lineBytes = 0;
  let oversizedLine = false;
  let absoluteOffset = byteOffset;
  try {
    validateByteCursor(file.fd, byteOffset);
    while (absoluteOffset < stat.size && result.records.length < recordLimit) {
      const readSize = Math.min(SPOOL_READ_CHUNK_SIZE, stat.size - absoluteOffset);
      const data = new ArrayBuffer(readSize);
      const readLen = fileIo.readSync(file.fd, data);
      if (readLen <= 0) {
        break;
      }
      const bytes = new Uint8Array(data, 0, readLen);
      let segmentStart = 0;
      for (let i = 0; i < bytes.length; i++) {
        if (bytes[i] !== 10) {
          continue;
        }
        appendLinePart(bytes, segmentStart, i, lineParts, lineBytes, oversizedLine);
        lineBytes += i - segmentStart;
        if (lineBytes > FT_DB_SPOOL_MAX_RECORD_BYTES) {
          oversizedLine = true;
        }
        parseSpoolLineBytes(lineParts, lineBytes, oversizedLine, decoder, result);
        lineParts.length = 0;
        lineBytes = 0;
        oversizedLine = false;
        result.nextByteOffset = absoluteOffset + i + 1;
        segmentStart = i + 1;
        if (result.records.length >= recordLimit ||
          result.nextByteOffset - byteOffset >= FT_DB_SPOOL_REPLAY_PAGE_BYTES) {
          return result;
        }
      }
      if (segmentStart < bytes.length) {
        appendLinePart(bytes, segmentStart, bytes.length, lineParts, lineBytes, oversizedLine);
        lineBytes += bytes.length - segmentStart;
        if (lineBytes > FT_DB_SPOOL_MAX_RECORD_BYTES) {
          oversizedLine = true;
          lineParts.length = 0;
        }
      }
      absoluteOffset += readLen;
    }
    if (absoluteOffset >= stat.size && (lineBytes > 0 || oversizedLine)) {
      parseSpoolLineBytes(lineParts, lineBytes, oversizedLine, decoder, result);
      result.nextByteOffset = stat.size;
    }
    return result;
  } finally {
    fileIo.closeSync(file);
  }
}

function appendLinePart(
  bytes: Uint8Array,
  start: number,
  end: number,
  lineParts: Uint8Array[],
  currentLineBytes: number,
  oversizedLine: boolean
): void {
  if (oversizedLine || end <= start || currentLineBytes + end - start > FT_DB_SPOOL_MAX_RECORD_BYTES) {
    return;
  }
  lineParts.push(bytes.slice(start, end));
}

function parseSpoolLineBytes(
  lineParts: Uint8Array[],
  lineBytes: number,
  oversizedLine: boolean,
  decoder: util.TextDecoder,
  result: FTDBSpoolParseResult
): void {
  if (lineBytes === 0) {
    return;
  }
  result.fileRecords++;
  if (oversizedLine || lineBytes > FT_DB_SPOOL_MAX_RECORD_BYTES) {
    result.skippedRecords++;
    if (result.corruptLines.length < 8) { result.corruptLines.push(`oversized line: ${lineBytes} bytes`); }
    return;
  }
  const joined = new Uint8Array(lineBytes);
  let targetOffset = 0;
  for (let i = 0; i < lineParts.length; i++) {
    joined.set(lineParts[i], targetOffset);
    targetOffset += lineParts[i].byteLength;
  }
  const line = decoder.decodeWithStream(joined, { stream: false });
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return;
  }
  try {
    const record = JSON.parse(trimmed) as FTDBSpoolRecordDTO;
    if (record && isValidSyncDataJSON(record.data)) {
      result.records.push(record);
    } else {
      result.skippedRecords++;
      if (result.corruptLines.length < 8) { result.corruptLines.push(trimmed.slice(0, 2048)); }
    }
  } catch (_) {
    result.skippedRecords++;
    if (result.corruptLines.length < 8) { result.corruptLines.push(trimmed.slice(0, 2048)); }
  }
}

function validateByteCursor(fd: number, byteOffset: number): void {
  if (byteOffset <= 0) {
    fileIo.lseek(fd, 0, fileIo.WhenceType.SEEK_SET);
    return;
  }
  fileIo.lseek(fd, byteOffset - 1, fileIo.WhenceType.SEEK_SET);
  const previousByte = new ArrayBuffer(1);
  const readLen = fileIo.readSync(fd, previousByte);
  if (readLen !== 1 || new Uint8Array(previousByte)[0] !== 10) {
    throw new Error(`Spool byte cursor is not positioned after a newline: cursor=${byteOffset}`);
  }
  fileIo.lseek(fd, byteOffset, fileIo.WhenceType.SEEK_SET);
}

async function countAllPendingRecords(request: FTDBSpoolTaskPoolRequest): Promise<number> {
  return countFileRecords(request.activePath) +
    countFileRecords(request.inflightPath) +
    countFileRecords(request.legacyPath);
}

async function countAllPendingBytes(request: FTDBSpoolTaskPoolRequest): Promise<number> {
  return await getFileSize(request.activePath) +
    await getFileSize(request.inflightPath) +
    await getFileSize(request.legacyPath);
}

async function getFileSize(path: string): Promise<number> {
  try {
    if (!(await pathExists(path))) {
      return 0;
    }
    const stat = await fileIo.stat(path);
    return Math.max(0, stat.size);
  } catch (_) {
    return 0;
  }
}

function countFileRecords(path: string): number {
  try {
    if (!fileIo.accessSync(path)) {
      return 0;
    }
    const stat = fileIo.statSync(path);
    if (stat.size <= 0) {
      return 0;
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    let count = 0;
    let totalRead = 0;
    let lastByte = -1;
    try {
      while (totalRead < stat.size) {
        const readSize = Math.min(SPOOL_READ_CHUNK_SIZE, stat.size - totalRead);
        const buffer = new ArrayBuffer(readSize);
        const readLen = fileIo.readSync(file.fd, buffer);
        if (readLen <= 0) {
          break;
        }
        totalRead += readLen;
        const bytes = new Uint8Array(buffer, 0, readLen);
        for (let i = 0; i < bytes.length; i++) {
          lastByte = bytes[i];
          if (lastByte === 10) {
            count++;
          }
        }
      }
      if (totalRead > 0 && lastByte !== 10) {
        count++;
      }
      return count;
    } finally {
      fileIo.closeSync(file);
    }
  } catch (_) {
    return 0;
  }
}

async function getFileToken(path: string, create: boolean = false): Promise<string> {
  const tokenPath = `${path.substring(0, path.lastIndexOf('/'))}/inflight-token.json`;
  let token = FTCacheFiles.read(tokenPath);
  if (token === null && create) {
    token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
    FTCacheFiles.atomicWrite(tokenPath, token);
  }
  return token || '';
}

async function ensureSpoolDirectory(path: string): Promise<void> {
  if (await pathExists(path)) {
    return;
  }
  try {
    await fileIo.mkdir(path);
  } catch (error) {
    if (!(await pathExists(path))) {
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }
}

async function removeEmptyFile(path: string): Promise<void> {
  if (!(await pathExists(path))) {
    return;
  }
  const stat = await fileIo.stat(path);
  if (stat.size <= 0) {
    await fileIo.unlink(path);
  }
}

async function deleteFileIfExists(path: string): Promise<void> {
  if (await pathExists(path)) {
    await fileIo.unlink(path);
  }
}

async function pathExists(path: string): Promise<boolean> {
  try {
    return await fileIo.access(path);
  } catch (_) {
    return false;
  }
}

function normalizeCapacityBytes(value: number | undefined): number {
  if (value === undefined || value !== value || value <= 0) {
    return FT_DB_SPOOL_MAX_BYTES;
  }
  return Math.max(1, Math.floor(value));
}

function isValidSyncDataJSON(data: SyncDataJSON | undefined): boolean {
  return !!data && data.dataType !== undefined && !!data.dataString && data.dataString.length > 0 &&
    !!data.uuid && data.uuid.length > 0 && data.time > 0;
}
