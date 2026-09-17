import { fileIo as fs } from '@kit.CoreFileKit';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';
import { SessionReplayContext } from './SessionReplayProtocol';

/** One private-file resource that may be referenced by a Replay record. */
export interface SessionReplayStoredResource {
  version: number;
  id: string;
  fileName: string;
  createdAt: number;
  size: number;
  mimeType: string;
  context: SessionReplayContext;
}

/**
 * Durable content-addressed Replay resource storage.
 *
 * Resource bytes are retained once per SHA-256 file name; metadata is retained
 * once per backend route (`wgt_id`). This matches Android's resource check
 * routing while avoiding duplicate private-file copies of identical content.
 */
export class SessionReplayResourceStore {
  private static readonly VERSION: number = 1;
  private readonly root: string;
  private readonly dataRoot: string;
  private readonly metadataRoot: string;
  private readonly maxBytes: number;

  constructor(filesDir: string, maxBytes: number) {
    if (filesDir.trim().length === 0) {
      throw new Error('Session Replay resource storage requires a non-empty filesDir');
    }
    this.root = `${filesDir}/ft_session_replay/resources`;
    this.dataRoot = `${this.root}/data`;
    this.metadataRoot = `${this.root}/pending`;
    this.maxBytes = Math.max(1024 * 1024, Math.floor(maxBytes));
    this.ensureDirectory(this.dataRoot);
    this.ensureDirectory(this.metadataRoot);
    this.recover();
  }

  /** Persists bytes and returns their content-addressed file name, or null on failure. */
  public put(context: SessionReplayContext, data: Uint8Array, mimeType: string = 'application/octet-stream'): string | null {
    if (!this.isValidContext(context) || data.byteLength === 0) {
      return null;
    }
    try {
      const fileName = sha256(data);
      const routeKey = this.getRouteKey(context);
      const id = `${fileName}-${routeKey}`;
      const metadataPath = `${this.metadataRoot}/${id}.json`;
      if (this.exists(metadataPath)) {
        return fileName;
      }
      const dataPath = `${this.dataRoot}/${fileName}.bin`;
      if (!this.exists(dataPath)) {
        if (!this.reserveBytes(data.byteLength)) {
          return null;
        }
        this.atomicWriteBytes(dataPath, data);
      }
      const resource: SessionReplayStoredResource = {
        version: SessionReplayResourceStore.VERSION,
        id,
        fileName,
        createdAt: Date.now(),
        size: data.byteLength,
        mimeType: this.normalizeMimeType(mimeType),
        context: this.copyContext(context)
      };
      this.atomicWriteText(metadataPath, JSON.stringify(resource));
      return fileName;
    } catch (_error) {
      return null;
    }
  }

  /** Lists only metadata with a valid file name and a retained byte payload. */
  public list(): Array<SessionReplayStoredResource> {
    const resources: Array<SessionReplayStoredResource> = [];
    const names = this.metadataFileNames();
    for (let index = 0; index < names.length; index++) {
      const name = names[index];
      const path = `${this.metadataRoot}/${name}`;
      try {
        const resource = JSON.parse(fs.readTextSync(path)) as SessionReplayStoredResource;
        if (!this.isValidResource(resource, name) || !this.exists(this.getDataPath(resource.fileName))) {
          fs.unlinkSync(path);
          continue;
        }
        resources.push(resource);
      } catch (_error) {
        try { fs.unlinkSync(path); } catch (_) { }
      }
    }
    return resources.sort((left: SessionReplayStoredResource, right: SessionReplayStoredResource): number =>
      left.createdAt - right.createdAt);
  }

  /** Reads retained bytes only for a validated resource descriptor. */
  public read(resource: SessionReplayStoredResource): Uint8Array | null {
    if (!this.isSafeFileName(resource.fileName)) {
      return null;
    }
    const path = this.getDataPath(resource.fileName);
    try {
      const size = fs.statSync(path).size;
      if (size <= 0 || size > this.maxBytes) {
        return null;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const buffer = new ArrayBuffer(size);
        const read = fs.readSync(file.fd, buffer);
        if (read !== size) {
          return null;
        }
        const bytes = new Uint8Array(buffer);
        return sha256(bytes) === resource.fileName ? bytes : null;
      } finally {
        fs.closeSync(file);
      }
    } catch (_error) {
      return null;
    }
  }

  /** Removes acknowledged metadata and unreferenced content-addressed byte files. */
  public remove(ids: Array<string>): boolean {
    let complete = true;
    const fileNames: Array<string> = [];
    for (let index = 0; index < ids.length; index++) {
      const id = ids[index];
      if (!this.isSafeId(id)) {
        complete = false;
        continue;
      }
      const path = `${this.metadataRoot}/${id}.json`;
      try {
        const resource = JSON.parse(fs.readTextSync(path)) as SessionReplayStoredResource;
        if (this.isSafeFileName(resource.fileName)) {
          fileNames.push(resource.fileName);
        }
        fs.unlinkSync(path);
      } catch (_error) {
        complete = false;
      }
    }
    const remaining = this.list();
    for (let index = 0; index < fileNames.length; index++) {
      const fileName = fileNames[index];
      if (!remaining.some((resource: SessionReplayStoredResource): boolean => resource.fileName === fileName)) {
        try { fs.unlinkSync(this.getDataPath(fileName)); } catch (_error) { complete = false; }
      }
    }
    return complete;
  }

  public getRoot(): string {
    return this.root;
  }

  private recover(): void {
    this.removeTempFiles(this.root);
    this.list();
    this.removeOrphanedData();
  }

  private reserveBytes(incomingBytes: number): boolean {
    if (incomingBytes > this.maxBytes) {
      return false;
    }
    let usedBytes = this.dataBytes();
    const pending = this.list();
    let index = 0;
    while (usedBytes + incomingBytes > this.maxBytes && index < pending.length) {
      const candidate = pending[index];
      const sameFile = pending.filter((resource: SessionReplayStoredResource): boolean =>
        resource.fileName === candidate.fileName);
      const ids = sameFile.map((resource: SessionReplayStoredResource): string => resource.id);
      const bytes = candidate.size;
      if (!this.remove(ids)) {
        return false;
      }
      usedBytes -= bytes;
      index += sameFile.length;
    }
    return usedBytes + incomingBytes <= this.maxBytes;
  }

  private dataBytes(): number {
    let result = 0;
    const names = this.dataFileNames();
    for (let index = 0; index < names.length; index++) {
      try { result += fs.statSync(`${this.dataRoot}/${names[index]}`).size; } catch (_) { }
    }
    return result;
  }

  private removeOrphanedData(): void {
    const referenced = new Set<string>();
    const resources = this.list();
    for (let index = 0; index < resources.length; index++) {
      referenced.add(resources[index].fileName);
    }
    const names = this.dataFileNames();
    for (let index = 0; index < names.length; index++) {
      const fileName = names[index].substring(0, names[index].length - 4);
      if (!referenced.has(fileName)) {
        try { fs.unlinkSync(`${this.dataRoot}/${names[index]}`); } catch (_) { }
      }
    }
  }

  private getRouteKey(context: SessionReplayContext): string {
    const globalContext = context.globalContext;
    const wgtId = globalContext === undefined || globalContext['wgt_id'] === undefined
      ? '' : String(globalContext['wgt_id']);
    let hash = 2166136261;
    const value = `${context.applicationId}|${wgtId}`;
    for (let index = 0; index < value.length; index++) {
      hash = Math.imul(hash ^ value.charCodeAt(index), 16777619);
    }
    return (hash >>> 0).toString(16).padStart(8, '0');
  }

  private copyContext(context: SessionReplayContext): SessionReplayContext {
    const result: SessionReplayContext = {
      applicationId: context.applicationId,
      sessionId: context.sessionId,
      viewId: context.viewId
    };
    if (context.globalContext !== undefined) {
      const globalContext: Record<string, string | number | boolean> = {};
      const keys = Object.keys(context.globalContext);
      for (let index = 0; index < keys.length; index++) {
        const key = keys[index];
        globalContext[key] = context.globalContext[key];
      }
      result.globalContext = globalContext;
    }
    return result;
  }

  private normalizeMimeType(value: string): string {
    const mimeType = value.trim();
    return /^[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*$/.test(mimeType)
      ? mimeType : 'application/octet-stream';
  }

  private isValidResource(resource: SessionReplayStoredResource, name: string): boolean {
    return resource.version === SessionReplayResourceStore.VERSION &&
      typeof resource.id === 'string' && this.isSafeId(resource.id) && name === `${resource.id}.json` &&
      typeof resource.fileName === 'string' && this.isSafeFileName(resource.fileName) &&
      typeof resource.createdAt === 'number' && Number.isFinite(resource.createdAt) &&
      typeof resource.size === 'number' && Number.isInteger(resource.size) && resource.size > 0 && resource.size <= this.maxBytes &&
      typeof resource.mimeType === 'string' && this.normalizeMimeType(resource.mimeType) === resource.mimeType &&
      this.isValidContext(resource.context);
  }

  private isValidContext(context: SessionReplayContext): boolean {
    return context !== undefined && typeof context.applicationId === 'string' && context.applicationId.length > 0 &&
      typeof context.sessionId === 'string' && context.sessionId.length > 0 &&
      typeof context.viewId === 'string' && context.viewId.length > 0;
  }

  private isSafeId(id: string): boolean {
    return /^[a-f0-9]{64}-[a-f0-9]{8}$/.test(id);
  }

  private isSafeFileName(fileName: string): boolean {
    return /^[a-f0-9]{64}$/.test(fileName);
  }

  private getDataPath(fileName: string): string {
    return `${this.dataRoot}/${fileName}.bin`;
  }

  private exists(path: string): boolean {
    try { fs.accessSync(path); return true; } catch (_) { return false; }
  }

  private ensureDirectory(path: string): void {
    if (!this.exists(path)) {
      fs.mkdirSync(path, true);
    }
  }

  private metadataFileNames(): Array<string> {
    try { return fs.listFileSync(this.metadataRoot).filter((name: string): boolean => name.endsWith('.json')).sort(); }
    catch (_error) { return []; }
  }

  private dataFileNames(): Array<string> {
    try { return fs.listFileSync(this.dataRoot).filter((name: string): boolean => name.endsWith('.bin')).sort(); }
    catch (_error) { return []; }
  }

  private removeTempFiles(root: string): void {
    let names: Array<string> = [];
    try { names = fs.listFileSync(root); } catch (_) { return; }
    for (let index = 0; index < names.length; index++) {
      const path = `${root}/${names[index]}`;
      try {
        if (fs.statSync(path).isDirectory()) {
          this.removeTempFiles(path);
        } else if (names[index].endsWith('.tmp')) {
          fs.unlinkSync(path);
        }
      } catch (_) { }
    }
  }

  private atomicWriteText(path: string, value: string): void {
    this.atomicWriteBytes(path, util.TextEncoder.create('utf-8').encodeInto(value));
  }

  private atomicWriteBytes(path: string, bytes: Uint8Array): void {
    const temp = `${path}.tmp`;
    const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        const count = fs.writeSync(file.fd, bytes.slice(offset).buffer as ArrayBuffer);
        if (count <= 0) {
          throw new Error('Session Replay resource storage short write');
        }
        offset += count;
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(temp, path);
  }
}

function sha256(bytes: Uint8Array): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: bytes });
  const digest = md.digestSync().data;
  let result = '';
  for (let index = 0; index < digest.length; index++) {
    result += digest[index].toString(16).padStart(2, '0');
  }
  return result;
}
