import { bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import zlib from '@ohos.zlib';
import { FTSDK } from '@guancecloud/ft_sdk';
import BuildProfile from '../../../../BuildProfile';
import { FTSessionReplayConfig } from './FTSessionReplayConfig';
import {
  ANDROID_REPLAY_ENDPOINTS,
  HARMONY_REPLAY_SOURCE,
  isReplayFullSnapshot,
  serializeAndroidReplayMobileSegment
} from './SessionReplayProtocol';
import { SessionReplaySegmentStore, SessionReplayStoredSegment } from './SessionReplaySegmentStore';

const UPLOAD_CONNECT_TIMEOUT_MS = 60_000;
const UPLOAD_READ_TIMEOUT_MS = 60_000;
const HARMONY_REPLAY_SDK_NAME = 'df_harmonyos_rum_sdk';

/** Observable result of an explicit Replay flush. Failed segments remain local. */
export interface SessionReplayUploadResult {
  success: boolean;
  code: number;
  message: string;
  retryable: boolean;
  endpointBlocked: boolean;
  attemptedSegments: number;
  uploadedSegments: number;
  remainingSegments: number;
}

/** Android-compatible multipart fields generated for one durable Replay segment. */
export interface SessionReplayUploadFields {
  fields: Map<string, string>;
  rawSegment: string;
}

interface SessionReplayUploadTarget {
  url: string;
  env: string;
}

export interface SessionReplayUploadRoute {
  datakitUrl: string;
  datawayUrl: string;
  clientToken: string;
  env: string;
  uploadUrl: string;
  appVersion: string;
}

interface SessionReplayMultipartPayload {
  boundary: string;
  body: ArrayBuffer;
  fields: Map<string, string>;
}

interface SessionReplayHttpStatus {
  code: number;
  message: string;
}

interface SessionReplayRequestHeaders {
  'Content-Type': string;
  'Content-Encoding': string;
  'User-Agent': string;
  'X-Pkg-Id': string;
}

/**
 * Resolves the Android Replay intake route using the same DataKit/Dataway URL
 * grammar as the core SDK's telemetry uploader.
 */
export function createAndroidReplayUploadUrl(
  datakitUrl: string,
  datawayUrl: string,
  clientToken: string
): string {
  const datakit = datakitUrl.trim();
  const dataway = datawayUrl.trim();
  const host = datakit.length > 0 ? datakit : dataway;
  if (host.length === 0) {
    return '';
  }
  const path = ANDROID_REPLAY_ENDPOINTS.records;
  const normalizedHost = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  if (datakit.length > 0) {
    return `${normalizedHost}/${path}?precision=ns`;
  }
  return `${normalizedHost}/${path}?token=${clientToken}&to_headless=true&precision=ns`;
}

/** Android-aligned retry classification for the record intake queue. */
export function isRetryableReplayUploadStatus(code: number): boolean {
  return code === 0 || code === 408 || code === 429 || code >= 500;
}

/** Creates Android-aligned form fields and the newline-delimited record payload. */
export function createSessionReplayUploadFields(
  segment: SessionReplayStoredSegment,
  env: string,
  appVersion: string
): SessionReplayUploadFields {
  const records = segment.records;
  let start = records[0].timestamp;
  let end = records[0].timestamp;
  let hasFullSnapshot = false;
  for (let index = 0; index < records.length; index++) {
    const record = records[index];
    start = Math.min(start, record.timestamp);
    end = Math.max(end, record.timestamp);
    if (isReplayFullSnapshot(record)) {
      hasFullSnapshot = true;
    }
  }
  // Android converts its persisted EnrichedRecord to MobileSegment here. The
  // Studio player expects this final structure, not the persisted envelope.
  const rawSegment = `${serializeAndroidReplayMobileSegment(segment.context, records)}\n`;
  const fields = new Map<string, string>();
  fields.set('start', String(start));
  fields.set('end', String(end));
  fields.set('records_count', String(records.length));
  fields.set('index_in_view', '0');
  fields.set('has_full_snapshot', String(hasFullSnapshot));
  fields.set('source', HARMONY_REPLAY_SOURCE);
  fields.set('raw_segment_size', String(utf8Bytes(rawSegment).byteLength));
  fields.set('env', env);
  fields.set('sdk_version', BuildProfile.HAR_VERSION);
  fields.set('sdk_name', HARMONY_REPLAY_SDK_NAME);
  fields.set('version', appVersion);
  fields.set('app_id', segment.context.applicationId);
  fields.set('session_id', segment.context.sessionId);
  fields.set('view_id', segment.context.viewId);
  const globalContext = segment.context.globalContext;
  if (globalContext !== undefined) {
    const keys = Object.keys(globalContext);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      fields.set(key, String(globalContext[key]));
    }
  }
  return { fields, rawSegment };
}

/**
 * Uploads durable segments one by one. A file is removed only after the
 * Replay endpoint returns HTTP 200, matching Android's acknowledgement rule.
 */
export class SessionReplayUploader {
  private readonly store: SessionReplaySegmentStore;
  private readonly config: FTSessionReplayConfig;
  private readonly removeAcknowledged: ((ids: Array<string>) => Promise<boolean>) | null;
  private readonly route: SessionReplayUploadRoute | null;

  constructor(
    store: SessionReplaySegmentStore,
    config: FTSessionReplayConfig,
    removeAcknowledged: ((ids: Array<string>) => Promise<boolean>) | null = null,
    route: SessionReplayUploadRoute | null = null
  ) {
    this.store = store;
    this.config = config;
    this.removeAcknowledged = removeAcknowledged;
    this.route = route;
  }

  public async uploadPending(readySegments?: Array<SessionReplayStoredSegment>): Promise<SessionReplayUploadResult> {
    const target = this.resolveTarget();
    const pending = readySegments ?? this.store.list();
    if (pending.length === 0) {
      return this.result(true, 200, 'No pending Session Replay segments.', 0, 0);
    }
    if (target === null) {
      return this.result(false, 0, 'No Replay upload endpoint is configured.', 0, 0, true, true);
    }

    const appVersion = this.route?.appVersion ?? this.getAppVersion();
    let attemptedSegments = 0;
    let uploadedSegments = 0;
    for (let index = 0; index < pending.length; index++) {
      const segment = pending[index];
      attemptedSegments++;
      const status = await this.uploadSegment(target, segment, appVersion);
      if (status.code !== http.ResponseCode.OK) {
        return this.result(false, status.code, status.message, attemptedSegments, uploadedSegments,
          isRetryableReplayUploadStatus(status.code));
      }
      const removed = this.removeAcknowledged === null ? this.store.remove([segment.id]) :
        await this.removeAcknowledged([segment.id]);
      if (!removed) {
        return this.result(false, 0, 'Replay endpoint acknowledged a segment but local deletion failed.',
          attemptedSegments, uploadedSegments, true);
      }
      uploadedSegments++;
    }
    return this.result(true, http.ResponseCode.OK, 'Session Replay segments uploaded.', attemptedSegments, uploadedSegments);
  }

  private resolveTarget(): SessionReplayUploadTarget | null {
    if (this.route !== null) {
      const url = this.route.uploadUrl.length > 0 ? this.route.uploadUrl : createAndroidReplayUploadUrl(
        this.route.datakitUrl, this.route.datawayUrl, this.route.clientToken);
      return url.length === 0 ? null : { url, env: this.route.env };
    }
    const installedConfig = FTSDK.getSDKConfig();
    const env = installedConfig === null ? 'prod' : installedConfig.getEnv();
    const override = this.config.getUploadUrl();
    if (override.length > 0) {
      return { url: override, env };
    }
    if (installedConfig === null) {
      return null;
    }
    const url = createAndroidReplayUploadUrl(
      installedConfig.getDatakitUrl(),
      installedConfig.getDatawayUrl(),
      installedConfig.getClientToken()
    );
    return url.length === 0 ? null : { url, env };
  }

  private async uploadSegment(
    target: SessionReplayUploadTarget,
    segment: SessionReplayStoredSegment,
    appVersion: string
  ): Promise<SessionReplayHttpStatus> {
    try {
      const uploadFields = createSessionReplayUploadFields(segment, target.env, appVersion);
      const multipart = await this.createMultipartPayload(uploadFields);
      const request = http.createHttp();
      try {
        const headers: SessionReplayRequestHeaders = {
          'Content-Type': `multipart/form-data; boundary=${multipart.boundary}`,
          'Content-Encoding': 'identity',
          'User-Agent': `DF-RUM-HarmonyOS/${BuildProfile.HAR_VERSION}`,
          'X-Pkg-Id': `rumm-harmony-${segment.id}`
        };
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.POST,
          connectTimeout: UPLOAD_CONNECT_TIMEOUT_MS,
          readTimeout: UPLOAD_READ_TIMEOUT_MS,
          header: headers,
          extraData: multipart.body
        };
        const response = await request.request(target.url, options);
        const message = response.responseCode === http.ResponseCode.OK
          ? 'Replay endpoint acknowledged the segment.'
          : `Replay endpoint returned HTTP ${response.responseCode}.`;
        return { code: response.responseCode, message };
      } finally {
        request.destroy();
      }
    } catch (_error) {
      return { code: 0, message: 'Replay upload request failed; the segment was retained for retry.' };
    }
  }

  private async createMultipartPayload(upload: SessionReplayUploadFields): Promise<SessionReplayMultipartPayload> {
    const rawBytes = utf8Bytes(upload.rawSegment);
    const compressed = await this.compress(rawBytes);
    const boundary = `----GuanceHarmonyReplay${Date.now().toString(16)}`;
    const parts: Array<Uint8Array> = [];
    const fieldNames: Array<string> = [];
    upload.fields.forEach((_value: string, key: string): void => {
      fieldNames.push(key);
    });
    fieldNames.sort();
    for (let index = 0; index < fieldNames.length; index++) {
      const name = fieldNames[index];
      parts.push(utf8Bytes(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${upload.fields.get(name) ?? ''}\r\n`));
    }
    const fileName = (upload.fields.get('view_id') ?? '').replace(/[^a-zA-Z0-9._-]/g, '_');
    parts.push(utf8Bytes(`--${boundary}\r\nContent-Disposition: form-data; name="segment"; filename="${fileName}"\r\nContent-Type: application/octet-stream\r\n\r\n`));
    parts.push(compressed);
    parts.push(utf8Bytes(`\r\n--${boundary}--\r\n`));
    return { boundary, body: joinBytes(parts), fields: upload.fields };
  }

  private async compress(raw: Uint8Array): Promise<Uint8Array> {
    const source = new ArrayBuffer(raw.byteLength);
    new Uint8Array(source).set(raw);
    const zip = zlib.createZipSync();
    const capacity = await zip.compressBound(raw.byteLength);
    if (capacity <= 0) {
      throw new Error('Replay segment compression capacity is invalid.');
    }
    const destination = new ArrayBuffer(capacity);
    const output = await zip.compress(destination, source, raw.byteLength);
    if (output.status !== zlib.ReturnStatus.OK || output.destLen <= 0 || output.destLen > destination.byteLength) {
      throw new Error('Replay segment compression failed.');
    }
    return new Uint8Array(destination.slice(0, output.destLen));
  }

  private result(
    success: boolean,
    code: number,
    message: string,
    attemptedSegments: number,
    uploadedSegments: number,
    retryable: boolean = false,
    endpointBlocked: boolean = false
  ): SessionReplayUploadResult {
    return {
      success,
      code,
      message,
      retryable,
      endpointBlocked,
      attemptedSegments,
      uploadedSegments,
      remainingSegments: this.store.list().length
    };
  }

  private getAppVersion(): string {
    try {
      return bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      ).versionName;
    } catch (_error) {
      return '';
    }
  }
}

function utf8Bytes(value: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(value);
}

function joinBytes(parts: Array<Uint8Array>): ArrayBuffer {
  let length = 0;
  for (let index = 0; index < parts.length; index++) {
    length += parts[index].byteLength;
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (let index = 0; index < parts.length; index++) {
    result.set(parts[index], offset);
    offset += parts[index].byteLength;
  }
  return result.buffer;
}
