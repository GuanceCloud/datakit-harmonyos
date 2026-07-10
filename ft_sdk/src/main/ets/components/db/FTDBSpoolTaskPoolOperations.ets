import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SyncDataJSON } from './bean/SyncData';

enum FTDBSpoolTaskPoolCommand {
  INIT = 'init',
  APPEND = 'append',
  PREPARE_REPLAY = 'prepareReplay',
  ACK_REPLAY = 'ackReplay',
  CLEAR = 'clear'
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
  recordOffset?: number;
  recordLimit?: number;
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
  pendingRecords: number;
  batchToken: string;
  batchFileRecords: number;
  skippedRecords: number;
  records: FTDBSpoolRecordDTO[];
  nextRecordOffset: number;
  hasMoreRecords: boolean;
  errorMessage: string;
}

interface FTDBSpoolParseResult {
  records: FTDBSpoolRecordDTO[];
  fileRecords: number;
  skippedRecords: number;
  validRecords: number;
}

const SPOOL_READ_CHUNK_SIZE = 64 * 1024;

export async function runFTDBSpoolTaskPoolExecute(requestObject: Object): Promise<Object> {
  const request = requestObject as FTDBSpoolTaskPoolRequest;
  try {
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
      default:
        return createErrorResponse(`Unsupported Spool TaskPool command: ${request.command}`) as Object;
    }
  } catch (error) {
    return createErrorResponse(error instanceof Error ? error.message : String(error)) as Object;
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
  let text = '';
  let appendedRecords = 0;
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
    text += `${JSON.stringify(record)}\n`;
    appendedRecords++;
  }
  if (appendedRecords > 0) {
    const file = await fileIo.open(
      request.activePath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
    );
    try {
      await fileIo.write(file.fd, text);
    } finally {
      await fileIo.close(file);
    }
  }
  const response = await createPendingResponse(request);
  response.appendedRecords = appendedRecords;
  return response as Object;
}

async function prepareSpoolReplay(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  await ensureSpoolDirectory(request.spoolDir);
  await removeEmptyFile(request.inflightPath);
  if (!(await pathExists(request.inflightPath))) {
    if (await pathExists(request.legacyPath)) {
      await fileIo.rename(request.legacyPath, request.inflightPath);
    } else if (await pathExists(request.activePath)) {
      await fileIo.rename(request.activePath, request.inflightPath);
    }
  }
  if (!(await pathExists(request.inflightPath))) {
    return await createPendingResponse(request);
  }

  const recordOffset = Math.max(0, request.recordOffset || 0);
  const recordLimit = Math.max(1, request.recordLimit || 256);
  const parseResult = readSpoolRecordsChunked(request.inflightPath, recordOffset, recordLimit);
  const response = createSuccessResponse();
  response.records = parseResult.records;
  response.batchFileRecords = parseResult.fileRecords;
  response.skippedRecords = parseResult.skippedRecords;
  response.nextRecordOffset = recordOffset + parseResult.records.length;
  response.hasMoreRecords = response.nextRecordOffset < parseResult.validRecords;
  response.batchToken = await getFileToken(request.inflightPath);
  response.pendingRecords = await countAllPendingRecords(request);
  return response as Object;
}

async function ackSpoolReplay(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  const response = createSuccessResponse();
  if (!(await pathExists(request.inflightPath))) {
    response.pendingRecords = await countAllPendingRecords(request);
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
  return response as Object;
}

async function clearSpoolFiles(request: FTDBSpoolTaskPoolRequest): Promise<Object> {
  await deleteFileIfExists(request.activePath);
  await deleteFileIfExists(request.inflightPath);
  await deleteFileIfExists(request.legacyPath);
  return createSuccessResponse() as Object;
}

async function createPendingResponse(request: FTDBSpoolTaskPoolRequest): Promise<FTDBSpoolTaskPoolResponse> {
  const response = createSuccessResponse();
  response.pendingRecords = await countAllPendingRecords(request);
  return response;
}

function createSuccessResponse(): FTDBSpoolTaskPoolResponse {
  return {
    ok: true,
    appendedRecords: 0,
    pendingRecords: 0,
    batchToken: '',
    batchFileRecords: 0,
    skippedRecords: 0,
    records: [],
    nextRecordOffset: 0,
    hasMoreRecords: false,
    errorMessage: ''
  };
}

function createErrorResponse(message: string): FTDBSpoolTaskPoolResponse {
  const response = createSuccessResponse();
  response.ok = false;
  response.errorMessage = message;
  return response;
}

function readSpoolRecordsChunked(
  path: string,
  recordOffset: number,
  recordLimit: number
): FTDBSpoolParseResult {
  const result: FTDBSpoolParseResult = {
    records: [],
    fileRecords: 0,
    skippedRecords: 0,
    validRecords: 0
  };
  const stat = fileIo.statSync(path);
  if (stat.size <= 0) {
    return result;
  }
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  const decoder = util.TextDecoder.create('utf-8');
  let carry = '';
  let totalRead = 0;
  try {
    while (totalRead < stat.size) {
      const readSize = Math.min(SPOOL_READ_CHUNK_SIZE, stat.size - totalRead);
      const buffer = new ArrayBuffer(readSize);
      const readLen = fileIo.readSync(file.fd, buffer);
      if (readLen <= 0) {
        break;
      }
      totalRead += readLen;
      const chunk = decoder.decodeWithStream(new Uint8Array(buffer.slice(0, readLen)), {
        stream: totalRead < stat.size
      });
      carry += chunk;
      let newlineIndex = carry.indexOf('\n');
      while (newlineIndex >= 0) {
        parseSpoolLine(carry.substring(0, newlineIndex), result, recordOffset, recordLimit);
        carry = carry.substring(newlineIndex + 1);
        newlineIndex = carry.indexOf('\n');
      }
    }
    if (carry.trim().length > 0) {
      parseSpoolLine(carry, result, recordOffset, recordLimit);
    }
    return result;
  } finally {
    fileIo.closeSync(file);
  }
}

function parseSpoolLine(
  line: string,
  result: FTDBSpoolParseResult,
  recordOffset: number,
  recordLimit: number
): void {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return;
  }
  result.fileRecords++;
  try {
    const record = JSON.parse(trimmed) as FTDBSpoolRecordDTO;
    if (record && isValidSyncDataJSON(record.data)) {
      const validIndex = result.validRecords;
      result.validRecords++;
      if (validIndex >= recordOffset && result.records.length < recordLimit) {
        result.records.push(record);
      }
    } else {
      result.skippedRecords++;
    }
  } catch (_) {
    result.skippedRecords++;
  }
}

async function countAllPendingRecords(request: FTDBSpoolTaskPoolRequest): Promise<number> {
  return countFileRecords(request.activePath) +
    countFileRecords(request.inflightPath) +
    countFileRecords(request.legacyPath);
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

async function getFileToken(path: string): Promise<string> {
  const stat = await fileIo.stat(path);
  return `${stat.size}:${stat.mtime}`;
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

function isValidSyncDataJSON(data: SyncDataJSON | undefined): boolean {
  return !!data && data.dataType !== undefined && !!data.dataString && data.dataString.length > 0 &&
    !!data.uuid && data.uuid.length > 0 && data.time > 0;
}
