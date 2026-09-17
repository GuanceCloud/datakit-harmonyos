import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { FTSDK } from '@guancecloud/ft_sdk';
import BuildProfile from '../../../../BuildProfile';
import { ANDROID_REPLAY_ENDPOINTS, SessionReplayContext } from './SessionReplayProtocol';
import { SessionReplayResourceStore, SessionReplayStoredResource } from './SessionReplayResourceStore';
import { isRetryableReplayUploadStatus } from './SessionReplayUploader';

const CONNECT_TIMEOUT_MS = 60_000;
const READ_TIMEOUT_MS = 60_000;
const HARMONY_REPLAY_SDK_NAME = 'df_harmonyos_rum_sdk';

export interface SessionReplayResourceUploadResult {
  success: boolean;
  code: number;
  message: string;
  retryable: boolean;
  endpointBlocked: boolean;
  attemptedResources: number;
  uploadedResources: number;
  remainingResources: number;
}

interface ResourceUploadTarget {
  checkUrl: string;
  uploadUrl: string;
}

interface ResourceGroup {
  applicationId: string;
  globalContext: Record<string, string | number | boolean>;
  resources: Array<SessionReplayStoredResource>;
}

interface HttpStatus {
  code: number;
  message: string;
}

interface ResourceCheckResult {
  existing: Set<string> | null;
  status: HttpStatus;
}

interface ResourceMultipartPayload {
  boundary: string;
  body: ArrayBuffer;
}

interface ResourceCheckRequestBody {
  app_id: string;
  files: Array<string>;
  tags?: Record<string, string | number | boolean>;
}

interface ResourceCheckResponseBody {
  content?: object;
}

/**
 * Android-compatible asset check and multipart uploader. Resources are grouped
 * by `wgt_id`, checked first, and their private files are removed only after a
 * server acknowledgement or a positive existence response.
 */
export class SessionReplayResourceUploader {
  private readonly store: SessionReplayResourceStore;

  constructor(store: SessionReplayResourceStore) {
    this.store = store;
  }

  public async uploadPending(): Promise<SessionReplayResourceUploadResult> {
    const pending = this.store.list();
    if (pending.length === 0) {
      return this.result(true, http.ResponseCode.OK, 'No pending Session Replay resources.', 0, 0);
    }
    const target = this.resolveTarget();
    if (target === null) {
      return this.result(false, 0, 'No Session Replay resource upload endpoint is configured.', 0, 0, false, true);
    }
    const groups = this.groupByRoute(pending);
    let attempted = 0;
    let uploaded = 0;
    for (let index = 0; index < groups.length; index++) {
      const group = groups[index];
      const checked = await this.checkExisting(target, group);
      attempted += group.resources.length;
      if (checked.existing === null) {
        return this.result(false, checked.status.code, checked.status.message, attempted, uploaded,
          isRetryableReplayUploadStatus(checked.status.code));
      }
      const existing: Array<SessionReplayStoredResource> = [];
      const missing: Array<SessionReplayStoredResource> = [];
      for (let resourceIndex = 0; resourceIndex < group.resources.length; resourceIndex++) {
        const resource = group.resources[resourceIndex];
        if (checked.existing.has(resource.fileName)) {
          existing.push(resource);
        } else {
          missing.push(resource);
        }
      }
      if (existing.length > 0 && !this.store.remove(existing.map((resource: SessionReplayStoredResource): string => resource.id))) {
        return this.result(false, 0, 'Session Replay resource check succeeded but local cleanup failed.', attempted, uploaded, true);
      }
      if (missing.length === 0) {
        uploaded += existing.length;
        continue;
      }
      const status = await this.uploadGroup(target, group.applicationId, group.globalContext, missing);
      if (status.code !== http.ResponseCode.OK) {
        return this.result(false, status.code, status.message, attempted, uploaded,
          isRetryableReplayUploadStatus(status.code));
      }
      if (!this.store.remove(missing.map((resource: SessionReplayStoredResource): string => resource.id))) {
        return this.result(false, 0, 'Session Replay resource endpoint acknowledged data but local cleanup failed.',
          attempted, uploaded, true);
      }
      uploaded += existing.length + missing.length;
    }
    return this.result(true, http.ResponseCode.OK, 'Session Replay resources uploaded.', attempted, uploaded);
  }

  private resolveTarget(): ResourceUploadTarget | null {
    const installedConfig = FTSDK.getSDKConfig();
    if (installedConfig === null) {
      return null;
    }
    const datakitUrl = installedConfig.getDatakitUrl();
    const datawayUrl = installedConfig.getDatawayUrl();
    const clientToken = installedConfig.getClientToken();
    const checkUrl = createAndroidReplayResourceUrl(
      datakitUrl, datawayUrl, clientToken, ANDROID_REPLAY_ENDPOINTS.assetCheck, false
    );
    const uploadUrl = createAndroidReplayResourceUrl(
      datakitUrl, datawayUrl, clientToken, ANDROID_REPLAY_ENDPOINTS.assets, true
    );
    return checkUrl.length === 0 || uploadUrl.length === 0 ? null : { checkUrl, uploadUrl };
  }

  private groupByRoute(resources: Array<SessionReplayStoredResource>): Array<ResourceGroup> {
    const grouped = new Map<string, ResourceGroup>();
    for (let index = 0; index < resources.length; index++) {
      const resource = resources[index];
      const context = resource.context;
      const globalContext = copyGlobalContext(context);
      const wgtId = getGlobalContextValue(globalContext, 'wgt_id');
      const key = `${context.applicationId}|${wgtId}`;
      const existing = grouped.get(key);
      if (existing === undefined) {
        grouped.set(key, {
          applicationId: context.applicationId,
          globalContext,
          resources: [resource]
        });
      } else {
        existing.resources.push(resource);
      }
    }
    return Array.from(grouped.values());
  }

  private async checkExisting(target: ResourceUploadTarget, group: ResourceGroup): Promise<ResourceCheckResult> {
    const files = group.resources.map((resource: SessionReplayStoredResource): string => resource.fileName);
    const body: ResourceCheckRequestBody = {
      app_id: group.applicationId,
      files
    };
    if (Object.keys(group.globalContext).length > 0) {
      body.tags = group.globalContext;
    }
    try {
      const request = http.createHttp();
      try {
        const response = await request.request(target.checkUrl, {
          method: http.RequestMethod.POST,
          connectTimeout: CONNECT_TIMEOUT_MS,
          readTimeout: READ_TIMEOUT_MS,
          header: {
            'Content-Type': 'application/json',
            'Content-Encoding': 'identity',
            'User-Agent': `DF-RUM-HarmonyOS/${BuildProfile.HAR_VERSION}`,
            'X-Pkg-Id': `rumm-harmony-resource-check-${Date.now()}`
          },
          extraData: JSON.stringify(body)
        });
        if (response.responseCode !== http.ResponseCode.OK) {
          return {
            existing: null,
            status: {
              code: response.responseCode,
              message: `Session Replay resource check returned HTTP ${response.responseCode}.`
            }
          };
        }
        const existing = this.parseExistingFiles(response.result.toString(), files);
        return existing === null
          ? { existing: null, status: { code: 0, message: 'Session Replay resource check response was invalid.' } }
          : { existing, status: { code: response.responseCode, message: 'Session Replay resource check succeeded.' } };
      } finally {
        request.destroy();
      }
    } catch (_error) {
      return {
        existing: null,
        status: { code: 0, message: 'Session Replay resource check request failed; local files were retained for retry.' }
      };
    }
  }

  private parseExistingFiles(body: string, requestedFiles: Array<string>): Set<string> | null {
    try {
      const parsed = JSON.parse(body) as ResourceCheckResponseBody;
      if (parsed.content === undefined || typeof parsed.content !== 'object') {
        return null;
      }
      const requested = new Set<string>(requestedFiles);
      const existing = new Set<string>();
      const keys = Object.keys(parsed.content);
      const contentJson = JSON.stringify(parsed.content);
      for (let index = 0; index < keys.length; index++) {
        const key = keys[index];
        if (requested.has(key) && contentJson.indexOf(`${JSON.stringify(key)}:true`) >= 0) {
          existing.add(key);
        }
      }
      return existing;
    } catch (_error) {
      return null;
    }
  }

  private async uploadGroup(
    target: ResourceUploadTarget,
    applicationId: string,
    globalContext: Record<string, string | number | boolean>,
    resources: Array<SessionReplayStoredResource>
  ): Promise<HttpStatus> {
    const multipart = this.createMultipartPayload(applicationId, globalContext, resources);
    if (multipart === null) {
      return { code: 0, message: 'A pending Session Replay resource could not be read from private storage.' };
    }
    try {
      const request = http.createHttp();
      try {
        const response = await request.request(target.uploadUrl, {
          method: http.RequestMethod.POST,
          connectTimeout: CONNECT_TIMEOUT_MS,
          readTimeout: READ_TIMEOUT_MS,
          header: {
            'Content-Type': `multipart/form-data; boundary=${multipart.boundary}`,
            'Content-Encoding': 'identity',
            'User-Agent': `DF-RUM-HarmonyOS/${BuildProfile.HAR_VERSION}`,
            'X-Pkg-Id': `rumm-harmony-resource-${Date.now()}-${resources.length}`
          },
          extraData: multipart.body
        });
        return response.responseCode === http.ResponseCode.OK
          ? { code: response.responseCode, message: 'Session Replay resource endpoint acknowledged the files.' }
          : { code: response.responseCode, message: `Session Replay resource endpoint returned HTTP ${response.responseCode}.` };
      } finally {
        request.destroy();
      }
    } catch (_error) {
      return { code: 0, message: 'Session Replay resource upload failed; local files were retained for retry.' };
    }
  }

  private createMultipartPayload(
    applicationId: string,
    globalContext: Record<string, string | number | boolean>,
    resources: Array<SessionReplayStoredResource>
  ): ResourceMultipartPayload | null {
    const boundary = `----GuanceHarmonyReplayResource${Date.now().toString(16)}`;
    const parts: Array<Uint8Array> = [];
    parts.push(formField(boundary, 'app_id', applicationId));
    if (Object.keys(globalContext).length > 0) {
      parts.push(formField(boundary, 'tags', JSON.stringify(globalContext)));
    }
    for (let index = 0; index < resources.length; index++) {
      const resource = resources[index];
      const bytes = this.store.read(resource);
      if (bytes === null) {
        return null;
      }
      parts.push(utf8Bytes(`--${boundary}\r\nContent-Disposition: form-data; name="files"; filename="${resource.fileName}"\r\nContent-Type: ${resource.mimeType}\r\n\r\n`));
      parts.push(bytes);
      parts.push(utf8Bytes('\r\n'));
    }
    parts.push(utf8Bytes(`--${boundary}--\r\n`));
    return { boundary, body: joinBytes(parts) };
  }

  private result(
    success: boolean,
    code: number,
    message: string,
    attemptedResources: number,
    uploadedResources: number,
    retryable: boolean = false,
    endpointBlocked: boolean = false
  ): SessionReplayResourceUploadResult {
    return {
      success,
      code,
      message,
      retryable,
      endpointBlocked,
      attemptedResources,
      uploadedResources,
      remainingResources: this.store.list().length
    };
  }
}

/** Builds Android's DataKit/Dataway resource endpoint URLs. */
export function createAndroidReplayResourceUrl(
  datakitUrl: string,
  datawayUrl: string,
  clientToken: string,
  endpoint: string,
  useMillisecondPrecision: boolean
): string {
  const datakit = datakitUrl.trim();
  const dataway = datawayUrl.trim();
  const host = datakit.length > 0 ? datakit : dataway;
  if (host.length === 0) {
    return '';
  }
  const normalized = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  if (datakit.length > 0) {
    return useMillisecondPrecision ? `${normalized}/${endpoint}?precision=ms` : `${normalized}/${endpoint}`;
  }
  const base = `${normalized}/${endpoint}?token=${encodeURIComponent(clientToken)}&to_headless=true`;
  return useMillisecondPrecision ? `${base}&precision=ms` : base;
}

function formField(boundary: string, name: string, value: string): Uint8Array {
  return utf8Bytes(`--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`);
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

function copyGlobalContext(context: SessionReplayContext): Record<string, string | number | boolean> {
  const result: Record<string, string | number | boolean> = {};
  if (context.globalContext === undefined) {
    return result;
  }
  const keys = Object.keys(context.globalContext);
  for (let index = 0; index < keys.length; index++) {
    const key = keys[index];
    result[key] = context.globalContext[key];
  }
  return result;
}

function getGlobalContextValue(context: Record<string, string | number | boolean>, key: string): string {
  const keys = Object.keys(context);
  for (let index = 0; index < keys.length; index++) {
    if (keys[index] === key) {
      return String(context[keys[index]]);
    }
  }
  return '';
}
