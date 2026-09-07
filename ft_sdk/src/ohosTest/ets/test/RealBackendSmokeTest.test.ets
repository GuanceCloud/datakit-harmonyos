import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { DefaultSyncTaskManagerRuntime } from '../../../main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '../../../main/ets/components/internal/testaccess/SyncInternalTestAccess';
import { SDKUploadExecutePageResultDTO, SDKWorkerCommand, SDKWorkerRequest, SDKWorkerResponse }
  from '../../../main/ets/components/thread/SDKWorkerProtocol';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { RumAttributeAssert } from './helpers/RumAttributeAssert';
import { runTestCleanup } from './helpers/MockCollector';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTRUMConfig, FTLoggerConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType, EnvType } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { ErrorType, AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { ResourceParams } from '../../../main/ets/components/rum/bean/ResourceParams';
import { NetStatusBean } from '../../../main/ets/components/rum/bean/NetStatusBean';
import { FTTraceManager } from '../../../main/ets/components/trace/FTTraceManager';
import { FTTraceHandler } from '../../../main/ets/components/trace/FTTraceHandler';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { HttpBuilder } from '../../../main/ets/components/http/HttpBuilder';
import { DBAssert } from './helpers/DBAssert';
import { WaitUtils } from './helpers/WaitUtils';

const DEFAULT_REAL_DATAWAY_URL = 'https://rum-openway.guance.com';

interface RealBackendTestParameters {
  enableRealBackendSmoke?: string;
  realBackendDatawayUrl?: string;
  realBackendClientToken?: string;
  realBackendRumAppId?: string;
  realBackendRecoveryControlUrl?: string;
}

interface RealBackendTestArguments extends RealBackendTestParameters {
  parameters?: RealBackendTestParameters;
}

interface RealBackendRuntimeConfig {
  enabled: boolean;
  datawayUrl: string;
  clientToken: string;
  rumAppId: string;
  recoveryControlUrl: string;
}

function getRealBackendTestArguments(): RealBackendTestArguments {
  return AbilityDelegatorRegistry.getArguments() as Object as RealBackendTestArguments;
}

function readRealBackendParameter(args: RealBackendTestArguments, key: string, fallback: string): string {
  let value: string | undefined;
  switch (key) {
    case 'enableRealBackendSmoke':
      value = args.parameters?.enableRealBackendSmoke ?? args.enableRealBackendSmoke;
      break;
    case 'realBackendDatawayUrl':
      value = args.parameters?.realBackendDatawayUrl ?? args.realBackendDatawayUrl;
      break;
    case 'realBackendClientToken':
      value = args.parameters?.realBackendClientToken ?? args.realBackendClientToken;
      break;
    case 'realBackendRumAppId':
      value = args.parameters?.realBackendRumAppId ?? args.realBackendRumAppId;
      break;
    case 'realBackendRecoveryControlUrl':
      value = args.parameters?.realBackendRecoveryControlUrl ?? args.realBackendRecoveryControlUrl;
      break;
    default:
      value = undefined;
      break;
  }
  return value === undefined || value === null ? fallback : String(value);
}

function getRealBackendRuntimeConfig(): RealBackendRuntimeConfig {
  const args = getRealBackendTestArguments();
  return {
    enabled: readRealBackendParameter(args, 'enableRealBackendSmoke', 'false') === 'true',
    datawayUrl: readRealBackendParameter(args, 'realBackendDatawayUrl', DEFAULT_REAL_DATAWAY_URL).trim(),
    clientToken: readRealBackendParameter(args, 'realBackendClientToken', '').trim(),
    rumAppId: readRealBackendParameter(args, 'realBackendRumAppId', '').trim(),
    recoveryControlUrl: readRealBackendParameter(args, 'realBackendRecoveryControlUrl', '').trim()
  };
}

function isRealBackendSmokeRunnable(): boolean {
  const config = getRealBackendRuntimeConfig();
  if (!config.enabled) return false;
  if (!config.datawayUrl || !config.clientToken || !config.rumAppId) {
    throw new Error('Real backend smoke enabled: Dataway URL, Client Token and RUM App ID are required');
  }
  return true;
}

function skipIfRealBackendDisabled(): boolean {
  return !isRealBackendSmokeRunnable();
}

/** Observe real HTTP results; do not inject responses or replace DB commits. */
class RealUploadObserver extends DefaultSyncTaskManagerRuntime {
  private successes: Map<string, string> = new Map<string, string>();
  private failures: Set<string> = new Set<string>();
  readonly statusCodes: number[] = [];

  async executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const response = await super.executeUploadWorkerCommand(request);
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE && response.ok && response.payload) {
      const result = response.payload as Object as SDKUploadExecutePageResultDTO;
      if (result.shouldUpload) {
        this.statusCodes.push(result.httpResult.code);
        for (const row of result.rows) {
          // UUIDs are SDK-generated hex identifiers. Require the actual data-id tag,
          // not an incidental occurrence in another event's message or URL.
          const idPattern = new RegExp(`(?:,|^)sdk_data_id=(?:[^, \n]+\\.)?${row.uuid}(?=,| )`);
          if (!idPattern.test(result.bodyPreview)) continue;
          if (result.successfulResponse && result.httpResult.code >= 200 && result.httpResult.code < 300) {
            this.successes.set(row.uuid, result.bodyPreview);
          } else if (result.httpResult.code === 503) {
            this.failures.add(row.uuid);
          }
        }
      }
    }
    return response;
  }

  successfulPayload(uuid: string): string { return this.successes.get(uuid) ?? ''; }
  failedWith503(uuid: string): boolean { return this.failures.has(uuid); }
}

// Test-owned proxy protocol: POST {mode:"fail"} returns 503 on upload routes;
// POST {mode:"recover"} resumes forwarding to the configured real backend.
async function setRecoveryProxyMode(mode: string): Promise<void> {
  const url = getRealBackendRuntimeConfig().recoveryControlUrl;
  if (!url) throw new Error('Recovery case requires realBackendRecoveryControlUrl and a controllable Dataway proxy');
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: JSON.stringify({ mode }),
      connectTimeout: 5000,
      readTimeout: 5000
    });
    if (response.responseCode < 200 || response.responseCode >= 300) {
      throw new Error(`Recovery control failed: HTTP ${response.responseCode}`);
    }
  } finally {
    request.destroy();
  }
}

function installRealBackendSdk(context: Context): void {
  const config = getRealBackendRuntimeConfig();
  FTSDK.install(
    FTSDKConfig.builder(config.datawayUrl, config.clientToken)
      .setDebug(true)
      .setAutoSync(false)
      .setDataSyncRetryCount(0)
      .setEnv(EnvType.GRAY),
    context
  );

  FTSDK.installRUMConfig(
    new FTRUMConfig()
      .setRumAppId(config.rumAppId)
      .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
      .setEnableTraceUserAction(true)
      .setEnableTraceUserView(true)
      .setEnableTraceUserResource(true)
  );

  FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));

  FTSDK.installTraceConfig(
    new FTTraceConfig()
      .setEnableAutoTrace(true)
      .setEnableLinkRUMData(true)
      .setTraceType(TraceType.DDTRACE)
  );
}

async function flushAndAssertRealBackendConsumed(
  observer: RealUploadObserver,
  dataType: DataType,
  fragments: string[],
  record: SyncData,
  searchHint: string
): Promise<void> {
  const uuid = record.getUuid();
  console.info('RealBackendSmokeTest', `Uploading real backend payload. Search Studio ${searchHint}`);
  FTSDK.flushSyncData();
  const acknowledged = await WaitUtils.waitUntil(async () => observer.successfulPayload(uuid).length > 0, 30000);
  if (!acknowledged) {
    throw new Error(`No real HTTP 2xx for ${uuid}; statusCodes=${observer.statusCodes.join(',')}`);
  }
  const payload = observer.successfulPayload(uuid);
  for (const fragment of fragments) expect(payload.includes(fragment)).assertTrue();
  if (dataType === DataType.RUM_APP) {
    RumAttributeAssert.uploaded(payload, record, {
      measurement: record.getDataString().split(',')[0], appId: getRealBackendRuntimeConfig().rumAppId
    });
  }
  if (dataType === DataType.LOG) {
    // These smoke messages are single-line. Compare the complete original log,
    // allowing only the SDK's upload-package prefix to change.
    const original = record.getDataString().replace(/sdk_data_id=[^, ]+/, 'sdk_data_id=<id>');
    expect(payload.split('\n').some((line: string) =>
      line.replace(/sdk_data_id=[^, ]+/, 'sdk_data_id=<id>') === original)).assertTrue();
  }
  expect(await DBAssert.waitForNoSyncRecordWithUuid(dataType, uuid, 10000)).assertTrue();
  expect(await DBAssert.waitForNoSyncRecordContaining(dataType, fragments, 1000)).assertTrue();
  console.info('RealBackendSmokeTest', `HTTP 2xx and DB commit verified for ${uuid}. Search Studio ${searchHint}`);
}

function assertDDTraceHeaders(headers: Record<string, string>): string[] {
  const traceId = headers[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] || '';
  const spanId = headers[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] || '';
  const sampled = headers[FTTraceHandler.DD_TRACE_SAMPLING_PRIORITY_KEY] || '';
  const origin = headers[FTTraceHandler.DD_TRACE_ORIGIN_KEY] || '';

  expect(traceId.length > 0).assertTrue();
  expect(spanId.length > 0).assertTrue();
  expect(sampled).assertEqual('2');
  expect(origin).assertEqual('rum');

  return [traceId, spanId];
}

export default function realBackendSmokeTest() {
  // Disabled suites register no passing placeholder cases.
  if (!getRealBackendRuntimeConfig().enabled) return;
  describe('RealBackendSmokeTest', () => {
    let context: Context;
    let observer: RealUploadObserver;

    const shouldRunRealBackend = (): boolean => {
      return isRealBackendSmokeRunnable();
    };

    beforeEach(async () => {
      if (!shouldRunRealBackend()) {
        return;
      }

      context = await DBAssert.getAppContext();
      HttpBuilder.disableTestMode();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      installRealBackendSdk(context);
      observer = new RealUploadObserver();
      SyncInternalTestAccess.setRuntime(observer);
      await WaitUtils.delay(120);
    });

    afterEach(async () => {
      if (!shouldRunRealBackend()) {
        return;
      }

      await runTestCleanup([
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        () => { HttpBuilder.disableTestMode(); },
        async () => { await DBAssert.cleanupAll(); }
      ]);
    });

    it('realBackendShouldUploadRumView', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const viewName = `real_backend_view_${Date.now()}`;
      const fragments = [
        'view',
        `view_name=${viewName}`
      ];

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.RUM_APP, fragments, record, `view_name=${viewName}`);
    });

    it('realBackendShouldUploadLog', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const logContent = `real_backend_log_${Date.now()}`;
      const fragments = [
        logContent,
        'status=info'
      ];

      FTLogger.logBackground(logContent, Status.INFO);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.LOG, fragments, record, `message=${logContent}`);
    });

    it('realBackendShouldRecoverUploadAfter503', 0, async () => {
      if (skipIfRealBackendDisabled()) return;
      const message = `real_backend_recovery_${Date.now()}`;
      const fragments = [message, 'status=info'];
      await runTestCleanup([async () => {
        await setRecoveryProxyMode('fail');
        FTLogger.logBackground(message, Status.INFO);
        const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, fragments, 5000);
        expect(record !== null).assertTrue();
        FTSDK.flushSyncData();
        expect(await WaitUtils.waitUntil(async () => observer.failedWith503(record!.getUuid()), 30000)).assertTrue();
        expect(await SdkTestLifecycle.waitForUploadIdle(10000)).assertTrue();
        const retained = await DBAssert.waitForSyncRecordContaining(DataType.LOG, fragments, 5000);
        expect(retained!.getUuid()).assertEqual(record!.getUuid());
        // Upload persists a package prefix in sdk_data_id even on HTTP failure.
        expect(retained!.getTime()).assertEqual(record!.getTime());
        expect(retained!.getDataString().replace(/sdk_data_id=[^, ]+/, 'sdk_data_id=<id>'))
          .assertEqual(record!.getDataString().replace(/sdk_data_id=[^, ]+/, 'sdk_data_id=<id>'));
        expect(observer.successfulPayload(record!.getUuid())).assertEqual('');
        await setRecoveryProxyMode('recover');
        await flushAndAssertRealBackendConsumed(observer, DataType.LOG, fragments, record!, `message=${message}`);
      }, async () => {
        // Restore the proxy without hiding the original assertion failure.
        await setRecoveryProxyMode('recover');
      }]);
    });

    it('realBackendShouldUploadHistoricalLogAfterSdkReinstall', 0, async () => {
      if (skipIfRealBackendDisabled()) return;
      const message = `real_backend_historical_${Date.now()}`;
      const fragments = [message, 'status=info'];
      FTLogger.logBackground(message, Status.INFO);
      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, fragments, 5000);
      expect(record !== null).assertTrue();
      expect(observer.statusCodes.length).assertEqual(0);
      // Recreate SDK and Worker state, but deliberately preserve database rows.
      await SdkTestLifecycle.resetRuntimeState();
      installRealBackendSdk(context);
      observer = new RealUploadObserver();
      SyncInternalTestAccess.setRuntime(observer);
      const historical = await DBAssert.waitForSyncRecordContaining(DataType.LOG, fragments, 5000);
      expect(historical!.getUuid()).assertEqual(record!.getUuid());
      expect(historical!.getTime()).assertEqual(record!.getTime());
      expect(historical!.getDataString()).assertEqual(record!.getDataString());
      await flushAndAssertRealBackendConsumed(observer, DataType.LOG, fragments, record!, `message=${message}`);
    });

    it('realBackendShouldUploadAction', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const now = Date.now();
      const viewName = `real_backend_action_view_${now}`;
      const actionName = `real_backend_action_${now}`;
      const fragments = [
        'action',
        `action_name=${actionName}`,
        `view_name=${viewName}`
      ];

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addAction(actionName, 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.RUM_APP, fragments, record, `action_name=${actionName}`);
    });

    it('realBackendShouldUploadError', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const now = Date.now();
      const viewName = `real_backend_error_view_${now}`;
      const errorMessage = `real_backend_js_error_${now}`;
      const errorStack = `Error: ${errorMessage}\n  at RealBackendSmokeTest`;
      const fragments = [
        'error',
        'error_type=js',
        errorMessage,
        'RealBackendSmokeTest',
        `view_name=${viewName}`
      ];

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addError(errorStack, errorMessage, ErrorType.JS, AppState.RUN);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.RUM_APP, fragments, record, `error_message=${errorMessage}`);
    });

    it('realBackendShouldUploadResource', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const now = Date.now();
      const viewName = `real_backend_resource_view_${now}`;
      const resourceId = `real_backend_resource_${now}`;
      const resourceUrl = `https://example.com/real-backend-resource/${now}`;
      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`
      ];

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      params.setResponseContentType('application/json');
      params.setResponseContentLength(11);
      params.setRequestHeader('Accept: application/json');
      params.setResponseHeader('content-type: application/json');

      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(120000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.RUM_APP, fragments, record, `resource_url=${resourceUrl}`);
    });

    it('realBackendShouldUploadTraceResource', 0, async () => {
      if (skipIfRealBackendDisabled()) {
        return;
      }

      const now = Date.now();
      const viewName = `real_backend_trace_view_${now}`;
      const resourceId = `real_backend_trace_resource_${now}`;
      const resourceUrl = `https://example.com/real-backend-trace-resource/${now}`;

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId);

      const traceHeaders = FTTraceManager.getInstance().getTraceHeader(resourceId, resourceUrl);
      const traceIds = assertDDTraceHeaders(traceHeaders);
      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`,
        `trace_id=${traceIds[0]}`,
        `span_id=${traceIds[1]}`
      ];

      const requestHeaderMap = new Map<string, string[]>();
      const traceHeaderKeys = Object.keys(traceHeaders);
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        requestHeaderMap.set(key, [traceHeaders[key]]);
      }

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      params.setResponseContentType('application/json');
      params.setResponseContentLength(15);
      params.setRequestHeaderMap(requestHeaderMap);
      params.setResponseHeader('content-type: application/json');

      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(150000000);

      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();
      if (record === null) {
        return;
      }

      await flushAndAssertRealBackendConsumed(observer, DataType.RUM_APP, fragments, record, `trace_id=${traceIds[0]}`);
    });
  });
}
