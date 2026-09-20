import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig } from '../../../main/ets/components/Configs';
import { DataModifier, DataModifierValue, LineDataModifier } from '../../../main/ets/components/DataModifier';
import { Constants } from '../../../main/ets/components/Constants';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType } from '../../../main/ets/components/enum/Enums';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { ResourceParams } from '../../../main/ets/components/rum/bean/ResourceParams';
import { NetStatusBean } from '../../../main/ets/components/rum/bean/NetStatusBean';
import { AppState } from '../../../main/ets/components/rum/enum/RUMEnums';
import { DBAssert } from './helpers/DBAssert';
import { RumAttributeAssert, RumAttributeExpectation } from './helpers/RumAttributeAssert';
import { SyncData } from '../../../main/ets/components/db/bean/SyncData';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';
import { SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { HttpBuilder } from '../../../main/ets/components/http/HttpBuilder';

const TEST_FAKE_URL = 'http://www.test.url';
const TEST_FAKE_RUM_ID = 'rumId';
const MASK = 'xxx';
const ORIGINAL_LOG_MESSAGE = 'sensitive-log-message';
const ORIGINAL_ACTION_NAME = 'sensitive_action';

class PublicApiLineDataModifier implements LineDataModifier {
  maskResources: boolean = false;
  resourceCount: number = 0;
  networkErrorCount: number = 0;
  resourceHasContext: boolean = false;
  networkErrorHasContext: boolean = false;
  actionCount: number = 0;
  actionHasContext: boolean = false;
  errorCount: number = 0;
  errorHasContext: boolean = false;

  modify(measurement: string, data: Map<string, DataModifierValue>): Map<string, DataModifierValue> {
    const result = new Map<string, DataModifierValue>();

    if (data.get('message') === ORIGINAL_LOG_MESSAGE) {
      result.set('message', MASK);
    }
    if (data.get(Constants.KEY_RUM_ACTION_NAME) === ORIGINAL_ACTION_NAME) {
      result.set(Constants.KEY_RUM_ACTION_NAME, MASK);
    }
    if (measurement === 'action' && (data.get(Constants.KEY_RUM_ACTION_NAME) === ORIGINAL_ACTION_NAME ||
      data.get(Constants.KEY_RUM_ACTION_NAME) === 'modifier_noop_action')) {
      this.actionCount++;
      this.actionHasContext = this.hasPublicContext(data);
    }
    if (measurement === 'error' && data.get(Constants.KEY_RUM_ERROR_MESSAGE) === 'modifier-independent-error') {
      this.errorCount++;
      this.errorHasContext = this.hasPublicContext(data);
      result.set(Constants.KEY_RUM_ERROR_MESSAGE, 'line-masked-error');
      result.set('service', 'modifier-service-masked');
    }
    if (String(data.get(Constants.KEY_RUM_RESOURCE_URL)).includes('/modifier-resource-')) {
      const hasContext = this.hasPublicContext(data);
      if (measurement === 'resource') {
        this.resourceCount++;
        this.resourceHasContext = hasContext;
      } else if (measurement === 'error') {
        this.networkErrorCount++;
        this.networkErrorHasContext = hasContext;
      }
      if (this.maskResources) {
        result.set('service', 'modifier-service-masked');
        if (data.has('line_secret')) {
          result.set('line_secret', 'line-masked');
        }
        if (data.has(Constants.KEY_RUM_ERROR_MESSAGE)) {
          result.set(Constants.KEY_RUM_ERROR_MESSAGE, 'line-masked-error');
        }
      }
    }
    return result;
  }

  private hasPublicContext(data: Map<string, DataModifierValue>): boolean {
    return data.get(Constants.KEY_SDK_NAME) === Constants.SDK_NAME &&
      String(data.get(Constants.KEY_SDK_VERSION) || '').length > 0 &&
      String(data.get(Constants.KEY_SDK_PACKAGE_INFO) || '').length > 0 &&
      data.get('modifier_base') === 'base' && data.get('modifier_rum') === 'rum' &&
      data.has(Constants.KEY_SESSION_SAMPLE_RATE);
  }
}

class ResourceFieldDataModifier implements DataModifier {
  modify(key: string, value: DataModifierValue): DataModifierValue | null {
    if (key === 'field_secret' ||
      (key === Constants.KEY_RUM_ERROR_STACK && value === 'resource-secret-stack')) {
      return `field-masked:${value}`;
    }
    return null;
  }
}

class FailingStopCollector extends MockCollector {
  throwDuringWait: boolean = false;

  protected async waitForUploadStopped(_manager: SyncTaskManager): Promise<boolean> {
    if (this.throwDuringWait) throw new Error('planned upload status failure');
    return false;
  }
}

class AttributeMatrixModifier implements LineDataModifier {
  private mode: string;

  constructor(mode: string) {
    this.mode = mode;
  }

  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> | null {
    if (this.mode === 'null') return null;
    const result = new Map<string, DataModifierValue>();
    if (this.mode === 'mask') result.set('service', 'attribute-masked-service');
    return result;
  }
}

function submitModifierResource(resourceId: string, status: number): void {
  const rum = FTRUMGlobalManager.getInstance();
  const params = new ResourceParams();
  params.url = `https://example.com/${resourceId}`;
  params.resourceMethod = 'GET';
  params.resourceStatus = status;
  params.responseBody = status >= 400 ? 'resource-secret-stack' : '';
  params.property.set('field_secret', new String('original'));
  params.property.set('line_secret', new String('original'));
  const network = new NetStatusBean();
  network.setHoleRequestTime(1000);
  rum.startResource(resourceId);
  rum.stopResource(resourceId);
  rum.addResource(resourceId, params, network);
}

async function assertRumUploaded(collector: MockCollector, record: SyncData | null,
  attributes: RumAttributeExpectation): Promise<void> {
  RumAttributeAssert.record(record, attributes);
  collector.clearRequests();
  FTSDK.flushSyncData();
  const payload = await collector.waitForPayloadContaining([record!.getUuid()], 8000);
  RumAttributeAssert.uploaded(payload, record, attributes);
  expect(await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record!.getUuid(), 5000)).assertTrue();
}

function expectAttributeFailure(check: () => void, message: string): void {
  let rejected = false;
  try {
    check();
  } catch (error) {
    if (!String(error).includes(message)) throw new Error(String(error));
    rejected = true;
  }
  expect(rejected).assertTrue();
}

export default function dataModifierTest() {
  describe('DataModifierTest', () => {
    let collector: MockCollector;
    let modifier: PublicApiLineDataModifier;

    beforeEach(async () => {
      await SdkTestLifecycle.resetRuntimeState();
      collector = new MockCollector(200, '');
      collector.start();
      modifier = new PublicApiLineDataModifier();
      FTSDK.install(FTSDKConfig.builder(TEST_FAKE_URL)
        .setAutoSync(false)
        .setServiceName('modifier-service')
        .addGlobalContext('modifier_base', new String('base'))
        .setDataModifier(new ResourceFieldDataModifier())
        .setLineDataModifier(modifier));
      FTSDK.installLogConfig(new FTLoggerConfig().setEnableCustomLog(true));
      FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID)
        .addGlobalContext('modifier_rum', new String('rum')));
      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      await runTestCleanup([
        async () => { await collector.stop(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await DBAssert.cleanupAll(); }
      ]);
    });

    it('parserHandlesTagQuotesAndMultiline', 0, async () => {
      const viewName = 'customer"detail ,= path';
      const stack = 'first "line"\\path\nsecond line';
      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addAction('quoted-tag-action', 'click');
      const properties: Record<string, object> = {};
      properties['detail"key'] = new String('value "quoted"');
      FTRUMGlobalManager.getInstance().addError(stack, 'quoted-tag-error', 'CustomError', AppState.RUN, properties);
      const action = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['action,', 'action_name=quoted-tag-action'], 5000);
      const error = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['error,', 'error_message="quoted-tag-error"'], 5000);
      const actionExpected: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID, viewName };
      const errorExpected: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, viewName,
        requiredFields: ['error_stack', 'detail"key'] };
      const point = RumAttributeAssert.record(error, errorExpected);
      expect(point.fields.get('error_stack')).assertEqual(stack);
      expect(point.fields.get('detail"key')).assertEqual('value "quoted"');
      RumAttributeAssert.record(action, actionExpected);
      collector.clearRequests();
      FTSDK.flushSyncData();
      const payload = await collector.waitForPayloadContaining([action!.getUuid(), error!.getUuid()], 8000);
      RumAttributeAssert.uploaded(payload, action, actionExpected);
      RumAttributeAssert.uploaded(payload, error, errorExpected);
      // Unclosed string fields must still be rejected, even with quotes in Tags.
      const malformed = error!.getDataString().replace(/ [0-9]+$/, ',bad="unterminated 123');
      expectAttributeFailure(() => RumAttributeAssert.line(malformed, errorExpected), 'incomplete');
      expectAttributeFailure(() => RumAttributeAssert.uploaded(malformed, error, errorExpected), 'incomplete');
    });

    it('cleanupContinuesAfterStopFailure', 0, async () => {
      await collector.stop();
      for (const throwDuringWait of [false, true]) {
        const failing = new FailingStopCollector();
        failing.throwDuringWait = throwDuringWait;
        failing.start();
        expect(HttpBuilder.isTestMode()).assertTrue();
        const steps: string[] = [];
        let message = '';
        try {
          await runTestCleanup([
            async () => { await failing.stop(); },
            () => { steps.push('secondary'); throw new Error('secondary cleanup failure'); },
            async () => { await SdkTestLifecycle.resetRuntimeState(); steps.push('sdk'); },
            async () => { await DBAssert.cleanupAll(); steps.push('db'); }
          ]);
        } catch (error) {
          message = String(error);
        }
        expect(message.includes(throwDuringWait ? 'planned upload status failure' : 'cleanup timed out')).assertTrue();
        expect(steps.join(',')).assertEqual('secondary,sdk,db');
        expect(HttpBuilder.isTestMode()).assertFalse();
        expect(await DBAssert.querySyncCount([DataType.RUM_APP, DataType.LOG])).assertEqual(0);
        // A later collector can install and remove its own runtime normally.
        const next = new MockCollector();
        next.start();
        await next.stop();
        expect(HttpBuilder.isTestMode()).assertFalse();
      }
    });

    it('modifierModesKeepRumAttributes', 0, async () => {
      for (const mode of ['default', 'null', 'empty', 'mask']) {
        await collector.stop();
        await SdkTestLifecycle.resetRuntimeState();
        await DBAssert.resetAll();
        collector.start();
        const config = FTSDKConfig.builder(TEST_FAKE_URL).setAutoSync(false).setEnableDataFilter(false);
        if (mode !== 'default') config.setLineDataModifier(new AttributeMatrixModifier(mode));
        FTSDK.install(config, await DBAssert.getAppContext());
        FTSDK.installRUMConfig(new FTRUMConfig().setRumAppId(TEST_FAKE_RUM_ID));
        const viewName = `attribute-matrix-${mode}`;
        const rum = FTRUMGlobalManager.getInstance();
        await rum.startView(viewName);
        rum.addAction(`attribute-action-${mode}`, 'click');
        rum.addError('attribute-stack', `attribute-error-${mode}`, 'CustomError', AppState.RUN);
        rum.addLongTask(`attribute-longtask-${mode}`, 42000000);
        submitModifierResource(`attribute-resource-${mode}`, 500);
        await rum.stopView();

        const expectations: RumAttributeExpectation[] = [
          { measurement: 'action', appId: TEST_FAKE_RUM_ID, viewName },
          { measurement: 'error', appId: TEST_FAKE_RUM_ID, viewName, requiredFields: ['error_stack'] },
          { measurement: 'long_task', appId: TEST_FAKE_RUM_ID, viewName },
          { measurement: 'resource', appId: TEST_FAKE_RUM_ID, viewName, resourceStatus: 500 },
          { measurement: 'error', appId: TEST_FAKE_RUM_ID, viewName, requiredTags: ['resource_id'] },
          { measurement: 'view', appId: TEST_FAKE_RUM_ID, viewName }
        ];
        const rows: SyncData[] = [];
        for (let i = 0; i < expectations.length; i++) {
          const expected = expectations[i];
          const fragments: string[] = [`${expected.measurement},`, `view_name=${viewName}`];
          if (i === 1) fragments.push('error_type=CustomError');
          if (i === 4) fragments.push('error_source=network');
          const row = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 8000);
          const point = RumAttributeAssert.record(row, expected);
          if (mode === 'mask') expect(point.tags.get('service')).assertEqual('attribute-masked-service');
          rows.push(row!);
        }
        collector.clearRequests();
        FTSDK.flushSyncData();
        for (let i = 0; i < rows.length; i++) {
          const payload = await collector.waitForPayloadContaining([rows[i].getUuid()], 8000);
          RumAttributeAssert.uploaded(payload, rows[i], expectations[i]);
        }
      }
    });

    it('attributesRejectMissingResourceAndFields', 0, async () => {
      submitModifierResource('attribute-negative-control', 500);
      const resource = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource,', 'resource_url_path=/attribute-negative-control'], 5000);
      const error = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['error,', 'resource_url_path=/attribute-negative-control'], 5000);
      const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID, resourceStatus: 500 };
      RumAttributeAssert.record(resource, attributes);
      const original = resource!.getDataString();
      // Mutate copies of a real SDK event. The original case must pass; each
      // missing/invalid attribute and an Error-only upload must be rejected.
      RumAttributeAssert.uploaded(original, resource, attributes);
      expectAttributeFailure(() => RumAttributeAssert.line(original.replace(/,sdk_version=[^, ]*/, ''), attributes), 'sdk_version');
      expectAttributeFailure(() => RumAttributeAssert.line(original.replace(/,sdk_version=[^, ]*/, ',sdk_version='), attributes), 'sdk_version');
      expectAttributeFailure(() => RumAttributeAssert.line(original.replace(/session_sample_rate=[^, ]+/, 'session_sample_rate="1"'), attributes), 'session_sample_rate');
      expectAttributeFailure(() => RumAttributeAssert.uploaded('', resource, attributes), 'found 0');
      expectAttributeFailure(() => RumAttributeAssert.uploaded(error!.getDataString(), resource, attributes), 'found 0');
      expectAttributeFailure(() => RumAttributeAssert.uploaded(original.replace(/,device_uuid=[^, ]*/, ''), resource, attributes), 'device_uuid');
      expectAttributeFailure(() => RumAttributeAssert.uploaded(`${original}\n${original}`, resource, attributes), 'found 2');
    });

    it('noopModifierKeepsResourceContext', 0, async () => {
      submitModifierResource('modifier-resource-noop', 200);
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'resource_url_path=/modifier-resource-noop'
      ], 5000);
      expect(record !== null).assertTrue();
      const line = record?.getDataString() ?? '';
      expect(line.startsWith('resource,')).assertTrue();
      expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
      expect(line.includes('sdk_version=')).assertTrue();
      expect(line.includes('sdk_pkg_info=')).assertTrue();
      expect(line.includes('device_uuid=')).assertTrue();
      expect(line.includes('application_uuid=')).assertTrue();
      expect(line.includes(`resource_id=${record?.getUuid()}`)).assertTrue();
      expect(line.includes('line_secret="original"')).assertTrue();
      expect(modifier.resourceCount).assertEqual(1);
      expect(modifier.resourceHasContext).assertTrue();
      await assertRumUploaded(collector, record, { measurement: 'resource', appId: TEST_FAKE_RUM_ID });
    });

    it('resourceAndErrorApplyModifiersBeforeSave', 0, async () => {
      modifier.maskResources = true;
      submitModifierResource('modifier-resource-error', 500);
      const resource = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'resource_url_path=/modifier-resource-error', 'line_secret="line-masked"'
      ], 5000);
      const error = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'resource_url_path=/modifier-resource-error', 'error_source=network'
      ], 5000);
      expect(resource !== null).assertTrue();
      expect(error !== null).assertTrue();
      const resourceLine = resource?.getDataString() ?? '';
      const errorLine = error?.getDataString() ?? '';
      for (const line of [resourceLine, errorLine]) {
        expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
        expect(line.includes('sdk_version=')).assertTrue();
        expect(line.includes('service=modifier-service-masked')).assertTrue();
        expect(line.includes(`resource_id=${resource?.getUuid()}`)).assertTrue();
      }
      expect(resource?.getUuid() === error?.getUuid()).assertFalse();
      expect(resourceLine.includes('field_secret="field-masked:original"')).assertTrue();
      expect(errorLine.includes('error_stack="field-masked:resource-secret-stack"')).assertTrue();
      expect(errorLine.includes('error_message="line-masked-error"')).assertTrue();
      expect(modifier.resourceCount).assertEqual(1);
      expect(modifier.networkErrorCount).assertEqual(1);
      expect(modifier.resourceHasContext).assertTrue();
      expect(modifier.networkErrorHasContext).assertTrue();
      const resourceAttributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID, resourceStatus: 500 };
      const errorAttributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, requiredFields: ['error_stack'] };
      RumAttributeAssert.record(resource, resourceAttributes);
      RumAttributeAssert.record(error, errorAttributes);
      collector.clearRequests();
      FTSDK.flushSyncData();
      const payload = await collector.waitForPayloadContaining([resource!.getUuid(), error!.getUuid()], 8000);
      RumAttributeAssert.uploaded(payload, resource, resourceAttributes);
      RumAttributeAssert.uploaded(payload, error, errorAttributes);
      expect(await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resource!.getUuid(), 5000)).assertTrue();
      expect(await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, error!.getUuid(), 5000)).assertTrue();
    });

    it('logModifierShouldChangeLineProtocol', 0, async () => {
      FTLogger.logBackground(ORIGINAL_LOG_MESSAGE, Status.INFO);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, ['message="xxx"', 'status=info'], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes(ORIGINAL_LOG_MESSAGE)).assertFalse();
      expect(line.includes(MASK)).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(['message="xxx"', 'status=info'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(uploaded.includes(ORIGINAL_LOG_MESSAGE)).assertFalse();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('rumModifierShouldChangeLineProtocol', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView('modifier_view');
      FTRUMGlobalManager.getInstance().addAction(ORIGINAL_ACTION_NAME, 'click');

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        `${Constants.KEY_RUM_ACTION_NAME}=${MASK}`,
        'action_type=click'
      ], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID, viewName: 'modifier_view' };
      RumAttributeAssert.record(record, attributes);
      expect(line.includes(ORIGINAL_ACTION_NAME)).assertFalse();
      expect(line.includes(MASK)).assertTrue();
      expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
      expect(line.includes('sdk_version=')).assertTrue();
      expect(modifier.actionCount).assertEqual(1);
      expect(modifier.actionHasContext).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        `${Constants.KEY_RUM_ACTION_NAME}=${MASK}`,
        'action_type=click'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, record, attributes);
      expect(uploaded.includes(ORIGINAL_ACTION_NAME)).assertFalse();
      expect(consumed).assertTrue();
    });

    it('noopModifierKeepsActionContext', 0, async () => {
      FTRUMGlobalManager.getInstance().addAction('modifier_noop_action', 'click');
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'action_name=modifier_noop_action', 'action_type=click'
      ], 5000);
      expect(record !== null).assertTrue();
      const line = record?.getDataString() ?? '';
      expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
      expect(line.includes('sdk_version=')).assertTrue();
      expect(line.includes('sdk_pkg_info=')).assertTrue();
      expect(line.includes('device_uuid=')).assertTrue();
      expect(line.includes('application_uuid=')).assertTrue();
      expect(modifier.actionCount).assertEqual(1);
      expect(modifier.actionHasContext).assertTrue();
      await assertRumUploaded(collector, record, { measurement: 'action', appId: TEST_FAKE_RUM_ID });
    });

    it('errorModifierReceivesPublicContext', 0, async () => {
      const properties: Record<string, object> = {};
      properties['field_secret'] = new String('original');
      FTRUMGlobalManager.getInstance().addError(
        'resource-secret-stack', 'modifier-independent-error', 'CustomError', AppState.RUN, properties);
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'error_type=CustomError', 'error_message="line-masked-error"'
      ], 5000);
      expect(record !== null).assertTrue();
      const line = record?.getDataString() ?? '';
      expect(line.includes('sdk_name=df_harmonyos_rum_sdk')).assertTrue();
      expect(line.includes('sdk_version=')).assertTrue();
      expect(line.includes('sdk_pkg_info=')).assertTrue();
      expect(line.includes('service=modifier-service-masked')).assertTrue();
      expect(line.includes('field_secret="field-masked:original"')).assertTrue();
      expect(line.includes('error_stack="field-masked:resource-secret-stack"')).assertTrue();
      expect(modifier.errorCount).assertEqual(1);
      expect(modifier.errorHasContext).assertTrue();
      await assertRumUploaded(collector, record, { measurement: 'error', appId: TEST_FAKE_RUM_ID });
    });
  });
}
