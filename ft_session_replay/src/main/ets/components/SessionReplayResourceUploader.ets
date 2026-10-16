import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { FTSDK } from '@guancecloud/ft_sdk';
import BuildProfile from '../../../../BuildProfile';
import { ANDROID_REPLAY_ENDPOINTS, SessionReplayContext } from './SessionReplayProtocol';
import { SessionReplayResourceStore, SessionReplayStoredResource } from './SessionReplayResourceStore';
import {
  isReplayUploadEndpointAvailable,
  isRetryableReplayUploadStatus,
  REPLAY_MAX_BATCHES_PER_UPLOAD_JOB,
  SessionReplayUploadRoute,
  shouldDiscardReplayUploadStatus
} from './SessionReplayUploader';
import { ReplayResourceCleanupResult, replayResourceCleanup, replayResourceCleanupError } from './ReplayResourceCleanup';
import { ReplayResourceAcknowledgements } from './ReplayResourceAcknowledgements';

const CONNECT_TIMEOUT_MS = 60_000;
const READ_TIMEOUT_MS = 60_000;
export interface SessionReplayResourceUploadResult {
  success: boolean;
  code: number;
  message: string;
  retryable: boolean;
  endpointBlocked: boolean;
  attemptedResources: number;
  /** Includes resources positively confirmed by the existence endpoint. */
  uploadedResources: number;
  /** Unacknowledged assets only; locally retained confirmed bytes are not an upload backlog. */
  remainingResources: number;
  cleanup: ReplayResourceCleanupResult;
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
  invalid?: boolean;
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

/** Invalid resource payloads are final unless their local cleanup itself failed. */
export function isRetryableReplayResourceFailure(
  code: number, invalid: boolean, cleanupFailed: boolean
): boolean {
  return cleanupFailed || isRetryableReplayUploadStatus(code, invalid);
}

/**
 * Android-compatible asset check and multipart uploader. Resources are grouped
 * by `wgt_id`, checked first, and their private files are removed only after a
 * server acknowledgement or a positive existence response.
 */
export class SessionReplayResourceUploader {
  private readonly store: SessionReplayResourceStore;
  private readonly route: SessionReplayUploadRoute | null;
  private readonly removeAcknowledged: ((ids: Array<string>) => Promise<ReplayResourceCleanupResult>) | null;
  private readonly acknowledgements: ReplayResourceAcknowledgements;
  private readonly onAttempt: ((count: number) => void) | null;
  private cleanup: ReplayResourceCleanupResult = replayResourceCleanup();

  constructor(
    store: SessionReplayResourceStore,
    route: SessionReplayUploadRoute | null = null,
    removeAcknowledged: ((ids: Array<string>) => Promise<ReplayResourceCleanupResult>) | null = null,
    acknowledgements: ReplayResourceAcknowledgements = new ReplayResourceAcknowledgements(),
    onAttempt: ((count: number) => void) | null = null
  ) {
    this.store = store;
    this.route = route;
    this.removeAcknowledged = removeAcknowledged;
    this.acknowledgements = acknowledgements;
    this.onAttempt = onAttempt;
  }

  public async uploadPending(): Promise<SessionReplayResourceUploadResult> {
    this.cleanup = replayResourceCleanup();
    const stored = this.store.list();
    if (stored.length === 0) {
      return this.result(true, http.ResponseCode.OK, 'No pending Session Replay resources.', 0, 0);
    }
    const target = this.resolveTarget();
    if (target === null) {
      this.acknowledgements.setScope('');
      return this.result(false, 0, 'No Session Replay resource upload endpoint is configured.', 0, 0, false, true);
    }
    this.acknowledgements.setScope(JSON.stringify([target.checkUrl, target.uploadUrl]));
    const pending: Array<SessionReplayStoredResource> = [];
    const cached: Array<string> = [];
    for (const resource of stored) {
      if (this.acknowledgements.has(resource.id)) cached.push(resource.id);
      else pending.push(resource);
    }
    // Retry only local housekeeping for confirmed assets. A new frame may keep
    // the bytes alive or recreate their descriptor without requiring another HTTP request.
    await this.removeResources(cached);
    if (pending.length === 0) {
      return this.result(true, http.ResponseCode.OK, 'No unacknowledged Session Replay resources.', 0, 0,
        this.cleanup.failedResources > 0);
    }
    this.onAttempt?.(pending.length);
    // One durable resource descriptor is one local batch in HarmonyOS. Limit
    // those first, then coalesce the selected batches by Android route.
    const groups = this.groupByRoute(pending.slice(0, REPLAY_MAX_BATCHES_PER_UPLOAD_JOB));
    let attempted = 0;
    let uploaded = 0;
    for (let index = 0; index < groups.length; index++) {
      const group = groups[index];
      const checked = await this.checkExisting(target, group);
      attempted += group.resources.length;
      if (checked.existing === null) {
        const failedBefore = this.cleanup.failedResources;
        if (shouldDiscardReplayUploadStatus(checked.status.code, checked.status.invalid === true)) {
          await this.removeResources(group.resources.map((resource: SessionReplayStoredResource): string => resource.id));
        }
        return this.result(false, checked.status.code, checked.status.message, attempted, uploaded,
          isRetryableReplayResourceFailure(checked.status.code, checked.status.invalid === true,
            this.cleanup.failedResources > failedBefore));
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
      // Availability is acknowledged remotely even if local housekeeping must wait.
      uploaded += existing.length;
      this.acknowledgements.remember(existing.map((resource: SessionReplayStoredResource): string => resource.id));
      await this.removeResources(existing.map((resource: SessionReplayStoredResource): string => resource.id));
      if (missing.length === 0) {
        continue;
      }
      const status = await this.uploadGroup(target, group.applicationId, group.globalContext, missing);
      if (status.code !== http.ResponseCode.OK) {
        const failedBefore = this.cleanup.failedResources;
        if (shouldDiscardReplayUploadStatus(status.code, status.invalid === true)) {
          await this.removeResources(missing.map((resource: SessionReplayStoredResource): string => resource.id));
        }
        return this.result(false, status.code, status.message, attempted, uploaded,
          isRetryableReplayResourceFailure(status.code, status.invalid === true,
            this.cleanup.failedResources > failedBefore));
      }
      uploaded += missing.length;
      this.acknowledgements.remember(missing.map((resource: SessionReplayStoredResource): string => resource.id));
      await this.removeResources(missing.map((resource: SessionReplayStoredResource): string => resource.id));
    }
    const retained = this.cleanup.deferredResources + this.cleanup.failedResources;
    return this.result(true, http.ResponseCode.OK, retained > 0
      ? 'Session Replay resources acknowledged; local cleanup remains pending.'
      : 'Session Replay resources uploaded.', attempted, uploaded, this.cleanup.failedResources > 0);
  }

  private resolveTarget(): ResourceUploadTarget | null {
    const installedConfig = this.route === null ? FTSDK.getSDKConfig() : null;
    if (installedConfig === null && this.route === null) {
      return null;
    }
    const datakitUrl = this.route?.datakitUrl ?? installedConfig!.getDatakitUrl();
    const datawayUrl = this.route?.datawayUrl ?? installedConfig!.getDatawayUrl();
    const clientToken = this.route?.clientToken ?? installedConfig!.getClientToken();
    const checkUrl = createAndroidReplayResourceUrl(
      datakitUrl, datawayUrl, clientToken, ANDROID_REPLAY_ENDPOINTS.assetCheck, false
    );
    const uploadUrl = createAndroidReplayResourceUrl(
      datakitUrl, datawayUrl, clientToken, ANDROID_REPLAY_ENDPOINTS.assets, true
    );
    return checkUrl.length === 0 || uploadUrl.length === 0 ? null : { checkUrl, uploadUrl };
  }

  private async removeResources(ids: Array<string>): Promise<void> {
    if (ids.length === 0) return;
    let result: ReplayResourceCleanupResult;
    try {
      result = this.removeAcknowledged === null ? this.store.removeAcknowledged(ids) : await this.removeAcknowledged(ids);
    } catch (error) {
      result = replayResourceCleanup(0, 0, ids.length,
        `Resource cleanup request failed: ${replayResourceCleanupError(error as Error)}`);
    }
    this.cleanup.deletedResources += result.deletedResources;
    this.cleanup.deferredResources += result.deferredResources;
    this.cleanup.failedResources += result.failedResources;
    if (result.reason.length > 0 && (this.cleanup.reason.length === 0 || result.failedResources > 0)) {
      this.cleanup.reason = result.reason;
    }
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
          ? { existing: null, status: { code: 0, message: 'Session Replay resource check response was invalid.', invalid: true } }
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
      return { code: 0, message: 'A pending Session Replay resource could not be read from private storage.', invalid: true };
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
      remainingResources: this.store.list().filter((resource: SessionReplayStoredResource): boolean =>
        !this.acknowledgements.has(resource.id)).length,
      cleanup: this.cleanup
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
  if (!isReplayUploadEndpointAvailable(datakit, dataway, clientToken)) {
    return '';
  }
  const host = datakit.length > 0 ? datakit : dataway;
  const normalized = host.endsWith('/') ? host.substring(0, host.length - 1) : host;
  if (datakit.length > 0) {
    return useMillisecondPrecision ? `${normalized}/${endpoint}?precision=ms` : `${normalized}/${endpoint}`;
  }
  const base = `${normalized}/${endpoint}?token=${encodeURIComponent(clientToken.trim())}&to_headless=true`;
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
