import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { Context } from '@kit.AbilityKit';
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
}

interface RealBackendTestArguments extends RealBackendTestParameters {
  parameters?: RealBackendTestParameters;
}

interface RealBackendRuntimeConfig {
  enabled: boolean;
  datawayUrl: string;
  clientToken: string;
  rumAppId: string;
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
    rumAppId: readRealBackendParameter(args, 'realBackendRumAppId', '').trim()
  };
}

function isRealBackendSmokeRunnable(): boolean {
  const config = getRealBackendRuntimeConfig();
  return config.enabled &&
    config.datawayUrl.length > 0 &&
    config.clientToken.length > 0 &&
    config.rumAppId.length > 0;
}

function skipIfRealBackendDisabled(): boolean {
  if (isRealBackendSmokeRunnable()) {
    return false;
  }

  console.info('RealBackendSmokeTest', 'Skipped. Set enableRealBackendSmoke=true, realBackendClientToken, and realBackendRumAppId.');
  expect(true).assertTrue();
  return true;
}

function installRealBackendSdk(context: Context): void {
  const config = getRealBackendRuntimeConfig();
  FTSDK.install(
    FTSDKConfig.builder(config.datawayUrl, config.clientToken)
      .setDebug(true)
      .setAutoSync(false)
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
  dataType: DataType,
  fragments: string[],
  uuid: string,
  searchHint: string
): Promise<void> {
  console.info('RealBackendSmokeTest', `Uploading real backend payload. Search Studio ${searchHint}`);

  FTSDK.flushSyncData();

  const consumed = await DBAssert.waitForNoSyncRecordWithUuid(dataType, uuid, 10000);
  expect(consumed).assertTrue();
  const matchingGone = await DBAssert.waitForNoSyncRecordContaining(dataType, fragments, 1000);
  expect(matchingGone).assertTrue();

  console.info('RealBackendSmokeTest', `Real backend upload consumed local DB record. Search Studio ${searchHint}`);
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
  describe('RealBackendSmokeTest', () => {
    let context: Context;

    const shouldRunRealBackend = (): boolean => {
      return isRealBackendSmokeRunnable();
    };

    beforeEach(async () => {
      if (!shouldRunRealBackend()) {
        return;
      }

      context = await DBAssert.getAppContext();
      HttpBuilder.disableTestMode();
      FTSDK.shutDown();
      await DBAssert.resetAll();
      installRealBackendSdk(context);
      await WaitUtils.delay(120);
    });

    afterEach(async () => {
      if (!shouldRunRealBackend()) {
        return;
      }

      FTSDK.shutDown();
      HttpBuilder.disableTestMode();
      await DBAssert.cleanupAll();
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

      await flushAndAssertRealBackendConsumed(DataType.RUM_APP, fragments, record.getUuid(), `view_name=${viewName}`);
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

      await flushAndAssertRealBackendConsumed(DataType.LOG, fragments, record.getUuid(), `message=${logContent}`);
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

      await flushAndAssertRealBackendConsumed(DataType.RUM_APP, fragments, record.getUuid(), `action_name=${actionName}`);
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

      await flushAndAssertRealBackendConsumed(DataType.RUM_APP, fragments, record.getUuid(), `error_message=${errorMessage}`);
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

      await flushAndAssertRealBackendConsumed(DataType.RUM_APP, fragments, record.getUuid(), `resource_url=${resourceUrl}`);
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

      await flushAndAssertRealBackendConsumed(DataType.RUM_APP, fragments, record.getUuid(), `trace_id=${traceIds[0]}`);
    });
  });
}
