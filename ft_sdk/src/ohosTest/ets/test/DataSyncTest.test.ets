/**
 * Data synchronization test
 * Reference: com.ft.sdk.tests.DataSyncTest (Android SDK)
 */

import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { Context } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { FTSDK } from '../../../main/ets/components/FTSDK';
import { FTSDKConfig, FTLoggerConfig, FTRUMConfig, FTTraceConfig } from '../../../main/ets/components/Configs';
import { Constants } from '../../../main/ets/components/Constants';
import { FTRUMGlobalManager } from '../../../main/ets/components/rum/FTRUMGlobalManager';
import { FTRUMInnerManager } from '../../../main/ets/components/rum/FTRUMInnerManager';
import FTTrackInner from '../../../main/ets/components/FTTrackInner';
import { FTLogger } from '../../../main/ets/components/log/FTLogger';
import { Status } from '../../../main/ets/components/bean/Status';
import { DataType, EnvType, SyncPageSize } from '../../../main/ets/components/enum/Enums';
import { ErrorMonitorType } from '../../../main/ets/components/rum/enum/ErrorMonitorType';
import { ErrorType, AppState, CollectType } from '../../../main/ets/components/rum/enum/RUMEnums';
import { NetStatusBean } from '../../../main/ets/components/rum/bean/NetStatusBean';
import { ResourceParams } from '../../../main/ets/components/rum/bean/ResourceParams';
import { TraceType } from '../../../main/ets/components/trace/TraceType';
import { FTTraceHandler } from '../../../main/ets/components/trace/FTTraceHandler';
import { FTTraceManager } from '../../../main/ets/components/trace/FTTraceManager';
import { SyncTaskManager } from '../../../main/ets/components/SyncTaskManager';
import { FTCrashFreeDurationManager } from '../../../main/ets/components/monitor/FTCrashFreeDurationManager';
import { DbInternalTestAccess } from '../../../main/ets/components/internal/testaccess/DbInternalTestAccess';
import { DBAssert } from './helpers/DBAssert';
import { RumAttributeAssert, RumAttributeExpectation } from './helpers/RumAttributeAssert';
import { MockCollector, runTestCleanup } from './helpers/MockCollector';
import { SdkTestLifecycle } from './helpers/SdkTestLifecycle';
import { WaitUtils } from './helpers/WaitUtils';

const TEST_FAKE_RUM_ID = 'rumId';
const ANY_VIEW = 'test_view';
const TEST_HOST = 'http://127.0.0.1:9529';
const TEST_DATAWAY_TOKEN = 'payload_token';
const ACTION_DURATION_NS = 123456789;
const ON_CREATE_VIEW_LOAD_TIME_NS = 234567890;
const UPDATED_VIEW_LOAD_TIME_NS = 345678901;
const SYNC_PREFERENCES_NAME = 'ft_sdk_sync_task';
const KEY_ERROR_TIMELINE = 'ft.rum.error.timeline';

interface ActionPropertyValue {
  value: string | number | boolean;
}

class NonCrashErrorCase {
  public readonly message: string;
  public readonly errorType: ErrorType;
  public readonly expectedType: string;

  public constructor(
    message: string,
    errorType: ErrorType,
    expectedType: string
  ) {
    this.message = message;
    this.errorType = errorType;
    this.expectedType = expectedType;
  }
}

class CrashErrorCase {
  public readonly message: string;
  public readonly errorType: ErrorType;
  public readonly expectedType: string;
  public readonly state: AppState;

  public constructor(
    message: string,
    errorType: ErrorType,
    expectedType: string,
    state: AppState
  ) {
    this.message = message;
    this.errorType = errorType;
    this.expectedType = expectedType;
    this.state = state;
  }
}

function buildDefaultSdkConfig(): FTSDKConfig {
  return FTSDKConfig.builder(TEST_HOST)
    .setDebug(true)
    .setAutoSync(false)
    .setEnv(EnvType.GRAY);
}

function buildDefaultRumConfig(): FTRUMConfig {
  return new FTRUMConfig()
    .setExtraMonitorTypeWithError(ErrorMonitorType.ALL)
    .setEnableTrackAppCrash(true)
    .setRumAppId(TEST_FAKE_RUM_ID)
    .setEnableTrackAppUIBlock(true)
    .setEnableTraceUserAction(true)
    .setEnableTraceUserView(true)
    .setEnableTraceUserResource(true);
}

function buildDefaultLogConfig(): FTLoggerConfig {
  return new FTLoggerConfig().setEnableCustomLog(true);
}

function buildDefaultTraceConfig(): FTTraceConfig {
  return new FTTraceConfig()
    .setEnableAutoTrace(true)
    .setTraceType(TraceType.DDTRACE);
}

function installTestSdk(
  context: Context,
  sdkConfig: FTSDKConfig = buildDefaultSdkConfig(),
  rumConfig: FTRUMConfig = buildDefaultRumConfig(),
  logConfig: FTLoggerConfig = buildDefaultLogConfig(),
  traceConfig: FTTraceConfig = buildDefaultTraceConfig()
): void {
  FTSDK.install(sdkConfig, context);
  FTSDK.installRUMConfig(rumConfig);
  FTSDK.installLogConfig(logConfig);
  FTSDK.installTraceConfig(traceConfig);
}

function buildActionProperty(key: string, value: string): Record<string, object> {
  const property: Record<string, object> = {};
  const wrappedValue: ActionPropertyValue = { value };
  property[key] = wrappedValue as object;
  return property;
}

function wrapActionProperty(value: string): ActionPropertyValue {
  return { value };
}

function assertContainsAll(value: string, fragments: string[]): void {
  for (const fragment of fragments) {
    expect(value.includes(fragment)).assertTrue();
  }
}

function getLineProtocolTag(line: string, key: string): string {
  const match = line.match(new RegExp(`(?:^|,)${key}=([^,\\s]+)`));
  return match !== null && match.length > 1 ? match[1] : '';
}

function isSdkUuid(value: string): boolean {
  return /^[0-9a-f]{32}$/.test(value);
}

async function flushAndWaitForPayload(
  collector: MockCollector,
  identityFragments: string[]
): Promise<string> {
  FTSDK.flushSyncData();

  let uploaded = await collector.waitForPayloadContaining(identityFragments, 5000);
  if (uploaded.length > 0) {
    return uploaded;
  }

  await SdkTestLifecycle.waitForUploadIdle(2000);
  FTSDK.flushSyncData();
  uploaded = await collector.waitForPayloadContaining(identityFragments, 5000);
  return uploaded;
}

async function assertActionRecordUploaded(
  collector: MockCollector,
  actionName: string,
  fragments: string[]
): Promise<void> {
  const actionIdentityFragments = ['action,', `action_name=${actionName}`];
  const actionRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, actionIdentityFragments, 5000);
  expect(actionRecord !== null).assertTrue();
  assertContainsAll(actionRecord?.getDataString() ?? '', actionIdentityFragments.concat(fragments));
  const expected: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID };
  RumAttributeAssert.record(actionRecord, expected);

  collector.clearRequests();
  const uploadIdentityFragments = ['action,', actionRecord?.getUuid() ?? ''];

  const uploaded = await flushAndWaitForPayload(collector, uploadIdentityFragments);
  RumAttributeAssert.uploaded(uploaded, actionRecord, expected);
  const consumed =
    await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, actionRecord?.getUuid() ?? '', 5000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
}

async function assertRumRecordUploaded(
  collector: MockCollector,
  fragments: string[]
): Promise<void> {
  const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 8000);
  expect(record !== null).assertTrue();
  const expected: RumAttributeExpectation = { measurement: fragments[0].replace(',', ''), appId: TEST_FAKE_RUM_ID };
  RumAttributeAssert.record(record, expected);

  collector.clearRequests();
  const identityFragments = [fragments[0], record?.getUuid() ?? ''];

  const uploaded = await flushAndWaitForPayload(collector, identityFragments);
  RumAttributeAssert.uploaded(uploaded, record, expected);
  const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
}

async function assertLogRecordDroppedAfterUpload(
  collector: MockCollector,
  logContent: string
): Promise<void> {
  FTLogger.logBackground(logContent, Status.ERROR);

  const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=error'], 5000);
  expect(record !== null).assertTrue();

  collector.clearRequests();
  FTSDK.flushSyncData();

  const uploaded = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
  const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.LOG, record?.getUuid() ?? '', 5000);
  await SdkTestLifecycle.waitForUploadIdle(4000);

  expect(uploaded.length > 0).assertTrue();
  expect(consumed).assertTrue();
}

async function waitForRumAggregation(): Promise<void> {
  await WaitUtils.delay(1200);
}

async function runActionInFreshView(
  viewName: string,
  trigger: () => void,
  close: () => Promise<void>
): Promise<void> {
  await FTRUMGlobalManager.getInstance().startView(viewName);
  await WaitUtils.delay(300);
  trigger();
  await WaitUtils.delay(600);
  await close();
  await waitForRumAggregation();
}

async function clearSyncErrorTimeline(context: Context): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: SYNC_PREFERENCES_NAME });
  await store.delete(KEY_ERROR_TIMELINE);
  await store.flush();
}

export default function dataSyncTest() {
  describe('DataSyncTest', () => {
    let collector: MockCollector;
    let context: Context;

    beforeAll(() => {
      console.info('DataSyncTest', 'beforeAll called');
    });

    beforeEach(async () => {
      console.info('DataSyncTest', 'beforeEach called');
      await SdkTestLifecycle.resetRuntimeState();
      context = await DBAssert.getAppContext();
      await clearSyncErrorTimeline(context);
      collector = new MockCollector(200, '');
      collector.start();

      installTestSdk(context);

      await DBAssert.resetAll();
      collector.clearRequests();
    });

    afterEach(async () => {
      await runTestCleanup([
        () => { console.info('DataSyncTest', 'afterEach called'); },
        async () => { await collector.stop(); },
        async () => { await SdkTestLifecycle.resetRuntimeState(); },
        async () => { await DBAssert.cleanupAll(); },
        async () => { await clearSyncErrorTimeline(context); }
      ]);
    });

    afterAll(() => {
      console.info('DataSyncTest', 'afterAll called');
    });

    it('rumViewShouldCreateRow', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      await FTRUMGlobalManager.getInstance().stopView();

      const view = await DBAssert.waitForViewNamed(ANY_VIEW, 5000);
      expect(view !== null).assertTrue();
      expect((view?.getSessionId() ?? '').length > 0).assertTrue();
      // RUM view records are persisted into rum_view first. Upload conversion is
      // covered by sync/upload chain cases where payload capture is stable.
    });

    it('rumViewShouldUploadAndDelete', 0, async () => {
      const onCreateViewName = 'sync_on_create_view';
      FTRUMInnerManager.getInstance().recordViewLoadTimeInternal(onCreateViewName, ON_CREATE_VIEW_LOAD_TIME_NS);
      await FTRUMGlobalManager.getInstance().startView(onCreateViewName);
      await WaitUtils.delay(300);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      await assertRumRecordUploaded(collector, [
        'view,',
        `view_name=${onCreateViewName}`,
        `loading_time=${ON_CREATE_VIEW_LOAD_TIME_NS}`
      ]);

      const updateLoadViewName = 'sync_update_load_view';
      await FTRUMGlobalManager.getInstance().startView(updateLoadViewName);
      await WaitUtils.delay(300);
      FTRUMGlobalManager.getInstance().updateLoadTime(UPDATED_VIEW_LOAD_TIME_NS);
      await WaitUtils.delay(100);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      await assertRumRecordUploaded(collector, [
        'view,',
        `view_name=${updateLoadViewName}`,
        `loading_time=${UPDATED_VIEW_LOAD_TIME_NS}`
      ]);

      const viewName = 'upload_delete_view';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const viewRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(viewRecord !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'view', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(viewRecord, attributes);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'view',
        `view_name=${viewName}`
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, viewRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, viewRecord, attributes);
      expect(consumed).assertTrue();
    });

    it('rumViewPropertiesKeepOriginalFieldNames', 0, async () => {
      const viewName = 'view_property_field_name';
      const property = buildActionProperty('custom_view_property', 'from-start-view');

      await FTRUMGlobalManager.getInstance().startView(viewName, property);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view,',
        `view_name=${viewName}`,
        'custom_view_property',
        'from-start-view'
      ], 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      expect(line.includes('custom_view_property')).assertTrue();
      expect(line.includes('view_property_custom_view_property')).assertFalse();
    });

    it('stopViewMergesPropertiesAndOverridesMatchingKeys', 0, async () => {
      const viewName = 'merged_stop_view_properties';
      const startProperties = buildActionProperty('start_only', 'start-value');
      startProperties['shared_key'] = wrapActionProperty('old-value') as object;
      const stopProperties = buildActionProperty('stop_only', 'stop-value');
      stopProperties['shared_key'] = wrapActionProperty('new-value') as object;

      await FTRUMGlobalManager.getInstance().startView(viewName, startProperties);
      await FTRUMGlobalManager.getInstance().stopView(stopProperties);
      await waitForRumAggregation();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_name=${viewName}`, 'is_active=false', 'start_only', 'stop_only', 'new-value'], 5000);
      expect(record !== null).assertTrue();
      const line = record?.getDataString() ?? '';
      expect(line.includes('start-value')).assertTrue();
      expect(line.includes('stop-value')).assertTrue();
      expect(line.includes('old-value')).assertFalse();
    });

    it('eventsWithoutAnActivePageUseSyntheticViews', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      await FTRUMGlobalManager.getInstance().startView('closed_page_before_fallback');
      const previous = await DBAssert.waitForViewNamed('closed_page_before_fallback', 5000);
      expect(previous !== null).assertTrue();
      await FTRUMGlobalManager.getInstance().stopView();

      const rootTags: Record<string, string> = {};
      manager.attachRUMRelative(rootTags, false);
      expect(rootTags[Constants.KEY_RUM_VIEW_NAME]).assertEqual(Constants.VIEW_NAME_ROOT_FALLBACK);
      expect(rootTags[Constants.KEY_RUM_VIEW_ID] === previous?.getId()).assertFalse();
      const root = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_ROOT_FALLBACK, 5000);
      expect(root?.getId()).assertEqual(rootTags[Constants.KEY_RUM_VIEW_ID]);

      manager.onAppBackground();
      const backgroundTags: Record<string, string> = {};
      manager.attachRUMRelative(backgroundTags, false);
      expect(backgroundTags[Constants.KEY_RUM_VIEW_NAME]).assertEqual(Constants.VIEW_NAME_BACKGROUND);
      expect(backgroundTags[Constants.KEY_RUM_VIEW_ID] === previous?.getId()).assertFalse();
      const background = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_BACKGROUND, 5000);
      expect(background?.getId()).assertEqual(backgroundTags[Constants.KEY_RUM_VIEW_ID]);

      manager.onAppForeground();
      await waitForRumAggregation();
      const noPageForegroundTags: Record<string, string> = {};
      manager.attachRUMRelative(noPageForegroundTags, false);
      expect(noPageForegroundTags[Constants.KEY_RUM_VIEW_NAME]).assertEqual(Constants.VIEW_NAME_ROOT_FALLBACK);
      const backgroundAfterForeground = (await DBAssert.queryViews(100))
        .find(view => view.getId() === background?.getId());
      expect(backgroundAfterForeground?.getIsClose()).assertFalse();
      await FTRUMGlobalManager.getInstance().startView('page_after_fallback');
      expect(await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_id=${background?.getId()}`, 'is_active=false'], 5000) !== null).assertTrue();
      const resumedTags: Record<string, string> = {};
      manager.attachRUMRelative(resumedTags, false);
      expect(resumedTags[Constants.KEY_RUM_VIEW_NAME]).assertEqual('page_after_fallback');
      expect(resumedTags[Constants.KEY_RUM_VIEW_ID] === backgroundTags[Constants.KEY_RUM_VIEW_ID]).assertFalse();
    });

    it('reenteringBackgroundWithoutAPageStartsANewBackgroundView', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      manager.onAppBackground();
      const first = await DBAssert.waitForViewNamed(Constants.VIEW_NAME_BACKGROUND, 5000);
      expect(first !== null).assertTrue();
      manager.onAppBackground();
      const sameBackground = (await DBAssert.queryViews(100))
        .filter(view => view.getViewName() === Constants.VIEW_NAME_BACKGROUND);
      expect(sameBackground.length).assertEqual(1);

      manager.onAppForeground();
      await waitForRumAggregation();
      const stillOpen = (await DBAssert.queryViews(100)).find(view => view.getId() === first?.getId());
      expect(stillOpen?.getIsClose()).assertFalse();

      manager.onAppBackground();
      const secondCreated = await WaitUtils.waitUntil(async () =>
        (await DBAssert.queryViews(100)).some(view =>
          view.getViewName() === Constants.VIEW_NAME_BACKGROUND && view.getId() !== first?.getId() &&
          !view.getIsClose()), 5000);
      expect(secondCreated).assertTrue();
      expect(await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_id=${first?.getId()}`, 'is_active=false'], 5000) !== null).assertTrue();

      manager.onAppForeground();
      const second = (await DBAssert.queryViews(100)).find(view =>
        view.getViewName() === Constants.VIEW_NAME_BACKGROUND && view.getId() !== first?.getId());
      expect(second?.getIsClose()).assertFalse();
      await FTRUMGlobalManager.getInstance().startView('page_after_second_background');
      expect(await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_id=${second?.getId()}`, 'is_active=false'], 5000) !== null).assertTrue();
    });

    it('logUpdateShouldUpload', 0, async () => {
      const logContent = '----logUpdateDataTest----';

      FTLogger.logBackground(logContent, Status.FATAL);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=fatal'], 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const payload = await collector.waitForPayloadContaining([logContent, 'status=fatal'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(payload.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('logShouldUpload', 0, async () => {
      const logContent = '----logUploadTest----';

      FTLogger.logBackground(logContent, Status.FATAL);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('clientErrorUploadShouldDropRows', 0, async () => {
      collector.setResponse(400, 'bad-request');

      await assertLogRecordDroppedAfterUpload(collector, 'real_client_error_drop_log');

      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('clientErrorDropsRowsAndAllowsRecovery', 0, async () => {
      collector.setResponse(403, 'forbidden');
      await assertLogRecordDroppedAfterUpload(collector, 'real_ignored_403_drop_log');

      collector.setResponse(429, 'rate-limit');
      await assertLogRecordDroppedAfterUpload(collector, 'real_ignored_429_drop_log');

      collector.setResponse(200, '');
      await assertLogRecordDroppedAfterUpload(collector, 'real_after_ignored_success_log');

      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('uploadSendRumBeforeLogWhenBothExist', 0, async () => {
      const viewName = 'real_order_rum_first_view';
      const logContent = 'real_order_log_after_rum';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();
      FTLogger.logBackground(logContent, Status.INFO);

      const rumRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      const logRecord = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(rumRecord !== null).assertTrue();
      expect(logRecord !== null).assertTrue();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const rumUploaded = await collector.waitForPayloadContaining([`view_name=${viewName}`], 5000);
      const logUploaded = await collector.waitForPayloadContaining([logContent], 5000);
      const requests = collector.getRequests()
        .filter(request => request.httpConfig.model === 'v1/write/rum' || request.httpConfig.model === 'v1/write/logging');

      expect(rumUploaded.length > 0).assertTrue();
      expect(logUploaded.length > 0).assertTrue();
      expect(requests.length >= 2).assertTrue();
      expect(requests[0].httpConfig.model).assertEqual('v1/write/rum');
      expect(await DBAssert.waitForSyncCount([DataType.RUM_APP, DataType.LOG], 0, 5000)).assertTrue();
    });

    it('rumActionShouldUpload', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView(ANY_VIEW);
      FTRUMGlobalManager.getInstance().addAction('sync_action', 'click');

      const actionRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, ['action', 'sync_action'], 5000);
      expect(actionRecord !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'action', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(actionRecord, attributes);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(['action', 'sync_action'], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, actionRecord?.getUuid() ?? '', 5000);
      await WaitUtils.delay(200);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, actionRecord, attributes);
      expect(consumed).assertTrue();
    });

    it('addActionVariantsShouldUpload', 0, async () => {
      await FTRUMGlobalManager.getInstance().startView('add_action_variants_view');

      FTRUMGlobalManager.getInstance().addAction('add_action_basic', 'click');
      await assertActionRecordUploaded(collector, 'add_action_basic', ['action_type=click']);

      FTRUMGlobalManager.getInstance().addAction('add_action_duration', 'click', ACTION_DURATION_NS);
      await assertActionRecordUploaded(collector, 'add_action_duration', [
        'action_type=click',
        `duration=${ACTION_DURATION_NS}`
      ]);

      FTRUMGlobalManager.getInstance().addAction('add_action_property', 'click',
        buildActionProperty('action_prop_key', 'action_prop_value'));
      await assertActionRecordUploaded(collector, 'add_action_property', [
        'action_type=click',
        'action_prop_key',
        'action_prop_value'
      ]);

      FTRUMGlobalManager.getInstance().addAction('add_action_full', 'click', ACTION_DURATION_NS,
        buildActionProperty('action_full_prop_key', 'action_full_prop_value'));
      await assertActionRecordUploaded(collector, 'add_action_full', [
        'action_type=click',
        `duration=${ACTION_DURATION_NS}`,
        'action_full_prop_key',
        'action_full_prop_value'
      ]);

      await FTRUMGlobalManager.getInstance().stopView();
    });

    it('startActionVariantsShouldUpload', 0, async () => {
      await runActionInFreshView(
        'start_action_basic_view',
        () => FTRUMGlobalManager.getInstance().startAction('start_action_basic', 'click'),
        async () => {
          await WaitUtils.delay(180);
          await FTRUMGlobalManager.getInstance().stopView();
        }
      );
      await assertActionRecordUploaded(collector, 'start_action_basic', ['action_type=click']);

      await runActionInFreshView(
        'start_action_property_view',
        () => FTRUMGlobalManager.getInstance().startAction('start_action_property', 'click',
          buildActionProperty('start_action_prop_key', 'start_action_prop_value')),
        async () => {
          await WaitUtils.delay(180);
          await FTRUMGlobalManager.getInstance().stopView();
        }
      );
      await assertActionRecordUploaded(collector, 'start_action_property', [
        'action_type=click',
        'start_action_prop_key',
        'start_action_prop_value'
      ]);

    });

    it('errorSampledShouldUploadAfterTimeline', 0, async () => {
      const eventTime = Date.now() * 1000000;
      const tags = new Map<string, string>();
      tags.set('session_id', 'sampled-session-id');
      tags.set('view_id', 'sampled-view-id');
      tags.set('view_name', 'sampled-view');
      tags.set('action_id', 'sampled-action-id');
      tags.set('action_name', 'sampled_action');
      tags.set('action_type', 'click');

      const fields = new Map<string, string>();
      fields.set('action_duration', '1');
      fields.set('sampled_marker', 'sampled_value');

      FTTrackInner.getInstance().rum(eventTime, 'action', tags, fields, null, CollectType.SAMPLING);

      const sampledFragments = [
        'action,',
        'session_id=sampled-session-id',
        'action_name=sampled_action',
        'sampled_marker='
      ];
      const sampledRecord =
        await DBAssert.waitForRawSyncRecordContaining('rum_app_error_sampled', sampledFragments, 5000);
      expect(sampledRecord !== null).assertTrue();

      const normalRows = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      let normalMatch = false;
      for (const row of normalRows) {
        if (DBAssert.containsAll(row.getDataString(), sampledFragments)) {
          normalMatch = true;
          break;
        }
      }
      expect(normalMatch).assertFalse();

      collector.clearRequests();
      SyncTaskManager.getInstance().setErrorTimeLine((sampledRecord?.getTime() ?? eventTime) + 1);
      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        sampledRecord?.getUuid() ?? '',
        'sampled_marker='
      ], 5000);
      const consumed = await WaitUtils.waitUntil(async () => {
        const records = await DBAssert.querySyncData([], 100);
        for (const record of records) {
          if (record.getUuid() === sampledRecord?.getUuid()) {
            return false;
          }
        }
        return true;
      }, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('errorSampledSessionShouldStageActionViewAndResourceTogether', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      manager.setSamplingRates(0, 1);
      expect(manager.checkSessionWillCollect(manager.getSessionId())).assertEqual(CollectType.SAMPLING);

      const viewName = 'error_sampled_lifecycle_view';
      const actionName = 'error_sampled_lifecycle_action';
      const aggregatedActionName = 'error_sampled_aggregate_action';
      const resourceId = 'error_sampled_lifecycle_resource';
      const resourceUrl = 'https://example.com/error-sampled-lifecycle';
      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(120000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addAction(actionName, 'click');
      await WaitUtils.delay(300);
      FTRUMGlobalManager.getInstance().startAction(aggregatedActionName, 'click');
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      FTRUMGlobalManager.getInstance().stopResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      const stagedType = 'rum_app_error_sampled';
      const action = await DBAssert.waitForRawSyncRecordContaining(stagedType,
        ['action,', `action_name=${actionName}`], 5000);
      const aggregatedAction = await DBAssert.waitForRawSyncRecordContaining(stagedType,
        ['action,', `action_name=${aggregatedActionName}`], 5000);
      const view = await DBAssert.waitForRawSyncRecordContaining(stagedType,
        ['view,', `view_name=${viewName}`], 5000);
      const resource = await DBAssert.waitForRawSyncRecordContaining(stagedType,
        ['resource,', `resource_url=${resourceUrl}`], 5000);
      expect(action !== null).assertTrue();
      expect(aggregatedAction !== null).assertTrue();
      expect(view !== null).assertTrue();
      expect(resource !== null).assertTrue();

      // Android keeps the View Line Protocol timestamp at its start while
      // staging an error-sampled View at its snapshot time. Resource uses its
      // start time for both the Line Protocol and the staging row.
      const viewLine = view!.getDataString();
      const viewEventTime = Number(viewLine.substring(viewLine.lastIndexOf(' ') + 1));
      expect(view!.getTime() > viewEventTime).assertTrue();
      const resourceLine = resource!.getDataString();
      const resourceEventTime = Number(resourceLine.substring(resourceLine.lastIndexOf(' ') + 1));
      expect(resource!.getTime()).assertEqual(resourceEventTime);

      const normalRows = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      for (const row of normalRows) {
        const line = row.getDataString();
        expect(line.includes(`action_name=${actionName}`)).assertFalse();
        expect(line.includes(`action_name=${aggregatedActionName}`)).assertFalse();
        expect(line.includes(`view_name=${viewName}`)).assertFalse();
        expect(line.includes(`resource_url=${resourceUrl}`)).assertFalse();
      }
    });

    it('actionAndViewKeepCreationSamplingAfterSessionRateChanges', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      manager.setSamplingRates(0, 1);
      const viewName = 'sampling_decision_view';
      const actionName = 'sampling_decision_action';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startAction(actionName, 'click');
      await WaitUtils.delay(300);
      manager.setSamplingRates(1, 0);
      expect(manager.checkSessionWillCollect(manager.getSessionId())).assertEqual(CollectType.ALL);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      const sampledType = 'rum_app_error_sampled';
      expect(await DBAssert.waitForRawSyncRecordContaining(sampledType,
        ['view,', `view_name=${viewName}`], 5000) !== null).assertTrue();
      expect(await DBAssert.waitForRawSyncRecordContaining(sampledType,
        ['action,', `action_name=${actionName}`], 5000) !== null).assertTrue();
      const normalRows = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      for (const row of normalRows) {
        const line = row.getDataString();
        expect(line.includes(`view_name=${viewName}`)).assertFalse();
        expect(line.includes(`action_name=${actionName}`)).assertFalse();
      }
    });

    it('expiredSessionKeepsPredecessorViewInItsOriginalSession', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      const oldViewName = 'expired_sampled_view';
      const newViewName = 'renewed_normal_view';
      manager.setSamplingRates(0, 1);
      await FTRUMGlobalManager.getInstance().startView(oldViewName);
      const oldSessionId = manager.getSessionId();
      const oldViewId = manager.getActiveView()!.getId();

      manager.setSamplingRates(1, 0);
      manager.expireSessionForTest();
      await FTRUMGlobalManager.getInstance().startView(newViewName);
      expect(manager.getSessionId() === oldSessionId).assertFalse();
      expect(manager.getActiveView()!.getSessionId()).assertEqual(manager.getSessionId());
      await waitForRumAggregation();

      const oldRecord = await DBAssert.waitForRawSyncRecordContaining('rum_app_error_sampled',
        ['view,', `view_id=${oldViewId}`, `session_id=${oldSessionId}`, 'is_active=false'], 5000);
      expect(oldRecord !== null).assertTrue();
      const normalRows = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      for (const row of normalRows) {
        expect(row.getDataString().includes(`view_id=${oldViewId}`)).assertFalse();
      }
      await FTRUMGlobalManager.getInstance().stopView();
    });

    it('errorSampledViewUsesLastErrorTimeOnlyForStaging', 0, async () => {
      const viewStartTime = Date.now() * 1000000 - 2000000000;
      const errorTime = viewStartTime + 1000000000;
      const viewName = `sampled_error_view_${Date.now()}`;
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_RUM_SESSION_ID, 'sampled-error-view-session');
      tags.set(Constants.KEY_RUM_VIEW_ID, viewName);
      tags.set(Constants.KEY_RUM_VIEW_NAME, viewName);
      const fields = new Map<string, string>();
      fields.set(Constants.KEY_RUM_VIEW_IS_ACTIVE, 'false');
      fields.set(Constants.KEY_SESSION_ERROR_TIMESTAMP, errorTime.toString());

      FTTrackInner.getInstance().rum(viewStartTime, Constants.FT_MEASUREMENT_RUM_VIEW,
        tags, fields, null, CollectType.SAMPLING);

      const record = await DBAssert.waitForRawSyncRecordContaining('rum_app_error_sampled',
        ['view,', `view_name=${viewName}`], 5000);
      expect(record !== null).assertTrue();
      expect(record!.getTime()).assertEqual(errorTime);
      const line = record!.getDataString();
      expect(Number(line.substring(line.lastIndexOf(' ') + 1))).assertEqual(viewStartTime);
    });

    it('droppedSessionShouldNotStageCompletedAction', 0, async () => {
      const manager = FTRUMInnerManager.getInstance();
      manager.setSamplingRates(0, 0);
      expect(manager.checkSessionWillCollect(manager.getSessionId())).assertEqual(CollectType.DROP);

      const actionName = 'dropped_lifecycle_action';
      FTRUMGlobalManager.getInstance().addAction(actionName, 'click');
      await waitForRumAggregation();

      const normalRows = await DBAssert.querySyncData([DataType.RUM_APP], 100);
      const stagedRows = await DBAssert.queryRawSyncData('rum_app_error_sampled', 100);
      for (const row of normalRows.concat(stagedRows)) {
        expect(row.getDataString().includes(`action_name=${actionName}`)).assertFalse();
      }
    });

    it('jsErrorShouldUploadAndDelete', 0, async () => {
      const errorMessage = 'real_collected_js_error';
      const errorStack = 'Error: real_collected_js_error\n  at DataSyncTest';

      await FTRUMGlobalManager.getInstance().startView('error_sync_view');
      FTRUMGlobalManager.getInstance().addError(
        errorStack,
        errorMessage,
        Date.now() * 1000000,
        ErrorType.JS,
        AppState.RUN
      );

      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'error',
        'error_type=js',
        errorMessage,
        'DataSyncTest'
      ], 5000);
      expect(errorRecord !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, requiredFields: ['error_stack'] };
      RumAttributeAssert.record(errorRecord, attributes);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'error',
        'error_type=js',
        errorMessage,
        'DataSyncTest'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, errorRecord, attributes);
      expect(consumed).assertTrue();
    });

    it('crashFreeDurationWaitsForSuccessfulErrorLocalWrite', 0, async () => {
      const failedMessage = 'crash_free_duration_forced_local_write_failure';
      const persistedMessage = 'crash_free_duration_local_write_recovered';
      const crashFreeManager = FTCrashFreeDurationManager.getInstance();

      // Give the process-level clock a visible interval, then fail the exact
      // write used for the first Crash Error. The DB manager will spool this
      // record but the Error write callback must not acknowledge the timer.
      await WaitUtils.delay(250);
      DbInternalTestAccess.forceNextSyncDataWriteFailure();
      FTRUMGlobalManager.getInstance().addError(
        `Error: ${failedMessage}\n  at DataSyncTest`,
        failedMessage,
        ErrorType.JS_CRASH,
        AppState.RUN
      );
      await WaitUtils.delay(250);
      const failedRowWasNotStored = await DBAssert.waitForNoSyncRecordContaining(DataType.RUM_APP, [
        'error,',
        failedMessage
      ], 100);
      expect(failedRowWasNotStored).assertTrue();
      const afterFailedWrite = await crashFreeManager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(afterFailedWrite !== null).assertTrue();
      if (afterFailedWrite) {
        // A reset at the failed write would leave only the latter ~250 ms.
        // Keeping the pre-failure interval yields at least ~500 ms here.
        expect(afterFailedWrite.foregroundNs > 400000000).assertTrue();
      }

      // A following successful Error row is the first acknowledgement and
      // must start the next crash-free cycle exactly once.
      FTRUMGlobalManager.getInstance().addError(
        `Error: ${persistedMessage}\n  at DataSyncTest`,
        persistedMessage,
        ErrorType.JS_CRASH,
        AppState.RUN
      );
      const persistedRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'error,',
        'error_type=js_crash',
        persistedMessage,
        'foreground_crash_free_duration=',
        'background_crash_free_duration='
      ], 5000);
      expect(persistedRecord !== null).assertTrue();

      await WaitUtils.delay(30);
      const afterSuccessfulWrite = await crashFreeManager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(afterSuccessfulWrite !== null).assertTrue();
      if (afterFailedWrite && afterSuccessfulWrite) {
        expect(afterSuccessfulWrite.foregroundNs < afterFailedWrite.foregroundNs).assertTrue();
      }

      // No second acknowledgement arrives for the prior failed/spooled Error:
      // the new interval grows monotonically instead of being cleared again.
      await WaitUtils.delay(80);
      const afterRecoverySettles = await crashFreeManager.prepareCrashFreeDuration(AppState.RUN, false);
      expect(afterRecoverySettles !== null).assertTrue();
      if (afterSuccessfulWrite && afterRecoverySettles) {
        expect(afterRecoverySettles.foregroundNs > afterSuccessfulWrite.foregroundNs).assertTrue();
      }

      // The forced write was spooled; clean it explicitly so it cannot leak
      // into later device tests.
      await FTSDK.clearAllData();
    });

    it('nonCrashErrorsDoNotWriteCrashFreeDurationFields', 0, async () => {
      const cases: NonCrashErrorCase[] = [
        new NonCrashErrorCase('crash_free_custom_error', ErrorType.CUSTOM, 'custom'),
        new NonCrashErrorCase('crash_free_network_error', ErrorType.NETWORK, 'network_error'),
        new NonCrashErrorCase('crash_free_anr_error', ErrorType.ANR_ERROR, 'anr_error')
      ];

      for (const testCase of cases) {
        FTRUMGlobalManager.getInstance().addError(
          `Error: ${testCase.message}\n  at DataSyncTest`,
          testCase.message,
          testCase.errorType,
          AppState.RUN
        );
        const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
          'error,',
          `error_type=${testCase.expectedType}`,
          testCase.message
        ], 5000);
        const line = record?.getDataString() ?? '';
        expect(record !== null).assertTrue();
        expect(line.includes('foreground_crash_free_duration=')).assertFalse();
        expect(line.includes('background_crash_free_duration=')).assertFalse();
      }
    });

    it('foregroundAndBackgroundJsAndNativeCrashesWriteBothDurationFields', 0, async () => {
      const cases: CrashErrorCase[] = [
        new CrashErrorCase('crash_free_js_foreground', ErrorType.JS_CRASH, 'js_crash', AppState.RUN),
        new CrashErrorCase('crash_free_js_background', ErrorType.JS_CRASH, 'js_crash', AppState.BACKGROUND),
        new CrashErrorCase('crash_free_native_foreground', ErrorType.NATIVE_CRASH, 'native_crash', AppState.RUN),
        new CrashErrorCase('crash_free_native_background', ErrorType.NATIVE_CRASH, 'native_crash', AppState.BACKGROUND)
      ];

      for (const testCase of cases) {
        FTRUMGlobalManager.getInstance().addError(
          `Error: ${testCase.message}\n  at DataSyncTest`,
          testCase.message,
          testCase.errorType,
          testCase.state
        );
        const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
          'error,',
          `error_type=${testCase.expectedType}`,
          `error_situation=${testCase.state.toString()}`,
          testCase.message,
          'foreground_crash_free_duration=',
          'background_crash_free_duration='
        ], 5000);
        const line = record?.getDataString() ?? '';
        expect(record !== null).assertTrue();
        expect(/foreground_crash_free_duration=\d+i/.test(line)).assertTrue();
        expect(/background_crash_free_duration=\d+i/.test(line)).assertTrue();
      }
    });

    it('anrErrorShouldUploadAndDelete', 0, async () => {
      const errorMessage = 'real_collected_anr_error';
      const errorStack = 'ANR: real_collected_anr_error\n  at DataSyncTest';

      const rumConfig = buildDefaultRumConfig()
        .setEnableTrackAppANR(true)
        .setEnableTraceWebView(true)
        .setEnableTraceUserResource(true);
      FTSDK.installRUMConfig(rumConfig);
      const installedRumConfig = FTSDK.getRumConfig();
      expect(installedRumConfig !== null).assertTrue();
      expect(installedRumConfig!.isEnableTrackAppANR()).assertTrue();
      expect(installedRumConfig!.isEnableTraceWebView()).assertTrue();
      expect(installedRumConfig!.isEnableTraceUserResource()).assertTrue();

      await FTRUMGlobalManager.getInstance().startView('anr_error_sync_view');
      FTRUMGlobalManager.getInstance().addError(errorStack, errorMessage, ErrorType.ANR_ERROR, AppState.RUN);

      const fragments = [
        'error',
        'error_type=anr_error',
        errorMessage,
        'DataSyncTest'
      ];
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(errorRecord !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, requiredFields: ['error_stack'] };
      RumAttributeAssert.record(errorRecord, attributes);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, errorRecord, attributes);
      expect(consumed).assertTrue();
    });

    it('customErrorTypeShouldUploadAndDelete', 0, async () => {
      const errorMessage = 'real_collected_custom_error';
      const errorStack = 'Error: real_collected_custom_error\n  at DataSyncTest';
      const fragments = [
        'error',
        'error_type=custom',
        errorMessage,
        'DataSyncTest',
        'custom_error_prop_key',
        'custom_error_prop_value'
      ];

      await FTRUMGlobalManager.getInstance().startView('custom_error_sync_view');
      FTRUMGlobalManager.getInstance().addError(
        errorStack,
        errorMessage,
        ErrorType.CUSTOM,
        AppState.RUN,
        buildActionProperty('custom_error_prop_key', 'custom_error_prop_value')
      );

      await assertRumRecordUploaded(collector, fragments);
    });

    it('resourceHeadersShouldUpload', 0, async () => {
      const viewName = 'manual_resource_sync_view';
      const resourceId = 'manual_resource_sync';
      const resourceUrl = 'https://example.com/manual-resource';
      FTSDK.installTraceConfig(buildDefaultTraceConfig().setEnableLinkRUMData(true));
      const traceHeaders = FTTraceManager.getInstance().getTraceHeader(resourceId, resourceUrl);
      const traceId = traceHeaders[FTTraceHandler.DD_TRACE_TRACE_ID_KEY] || '';
      const spanId = traceHeaders[FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY] || '';
      expect(traceId.length > 0).assertTrue();
      expect(spanId.length > 0).assertTrue();

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`,
        `trace_id=${traceId}`,
        `span_id=${spanId}`,
        'request_header',
        'Accept: application/json, text/plain',
        'X-Sync-Request: map-a, map-b',
        `${FTTraceHandler.DD_TRACE_TRACE_ID_KEY}: ${traceId}`,
        `${FTTraceHandler.DD_TRACE_PARENT_SPAN_ID_KEY}: ${spanId}`,
        `${FTTraceHandler.DD_TRACE_ORIGIN_KEY}: rum`,
        'response_header',
        'content-type: application/json',
        'X-Sync-Response: map-response'
      ];

      const requestHeaderMap = new Map<string, string[]>();
      requestHeaderMap.set('Accept', ['application/json', 'text/plain']);
      requestHeaderMap.set('X-Sync-Request', ['map-a', 'map-b']);
      const traceHeaderKeys = Object.keys(traceHeaders);
      for (let i = 0; i < traceHeaderKeys.length; i++) {
        const key = traceHeaderKeys[i];
        requestHeaderMap.set(key, [traceHeaders[key]]);
      }
      const responseHeaderMap = new Map<string, string[]>();
      responseHeaderMap.set('content-type', ['application/json']);
      responseHeaderMap.set('X-Sync-Response', ['map-response']);

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      params.setResponseContentType('application/json');
      params.setResponseContentLength(16);
      params.setRequestHeaderMap(requestHeaderMap);
      params.setResponseHeaderMap(responseHeaderMap);
      params.setResponseBody('{"ok":true}');

      const netStatus = new NetStatusBean();
      netStatus.setDNSStartTime(10);
      netStatus.setDNSTime(20);
      netStatus.setConnectStartTime(30);
      netStatus.setTcpTime(40);
      netStatus.setFirstByteStartTime(70);
      netStatus.setFirstByteTime(80);
      netStatus.setDownloadTimeStart(150);
      netStatus.setDownloadTime(30);
      netStatus.setHoleRequestTime(180000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      await WaitUtils.delay(20);
      FTRUMGlobalManager.getInstance().stopResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      await assertRumRecordUploaded(collector, fragments);
    });

    it('resourcePropertiesMergeInOrder', 0, async () => {
      const viewName = 'resource_lifecycle_property_view';
      const resourceId = 'resource_lifecycle_property';
      const resourceUrl = 'https://example.com/resource-lifecycle-property';

      const startProperty = buildActionProperty('resource_start_property', 'from-start');
      startProperty['resource_shared_property'] = wrapActionProperty('from-start');
      const stopProperty = buildActionProperty('resource_stop_property', 'from-stop');
      stopProperty['resource_shared_property'] = wrapActionProperty('from-stop');

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      const addProperty = new Map<string, object>();
      addProperty.set('resource_add_property', wrapActionProperty('from-add'));
      addProperty.set('resource_shared_property', wrapActionProperty('from-add'));
      params.setProperty(addProperty);

      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(120000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId, startProperty);
      await WaitUtils.delay(20);
      FTRUMGlobalManager.getInstance().stopResource(resourceId, stopProperty);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      await assertRumRecordUploaded(collector, [
        'resource',
        `resource_url=${resourceUrl}`,
        `view_name=${viewName}`,
        'resource_start_property="from-start"',
        'resource_stop_property="from-stop"',
        'resource_add_property="from-add"',
        'resource_shared_property="from-add"'
      ]);
    });

    it('statusZeroShouldWriteResourceError', 0, async () => {
      const viewName = 'manual_resource_error_view';
      const resourceId = 'manual_resource_error_status_zero';
      const resourceUrl = 'https://example.com/manual-resource-error';
      const errorMessage = 'Manual planned resource failure';
      const errorStack = 'Error: Manual planned resource failure\n  at DataSyncTest';

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(0);
      params.setRequestErrorMsg(errorMessage);
      params.setRequestErrorStack(errorStack);

      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(120000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      await WaitUtils.delay(20);
      FTRUMGlobalManager.getInstance().stopResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      const resourceFragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        `view_name=${viewName}`
      ];
      const errorFragments = [
        'error',
        'error_type=network_error',
        'error_source=network',
        `resource_url=${resourceUrl}`,
        'resource_status=0',
        errorMessage,
        'DataSyncTest'
      ];
      const resourceRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, resourceFragments, 5000);
      const errorRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, errorFragments, 5000);

      expect(resourceRecord !== null).assertTrue();
      expect((resourceRecord?.getDataString() ?? '').includes('resource_status=0')).assertTrue();
      expect(errorRecord !== null).assertTrue();
      const resourceAttributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID, viewName,
        resourceStatus: 0 };
      const errorAttributes: RumAttributeExpectation = { measurement: 'error', appId: TEST_FAKE_RUM_ID, viewName, requiredFields: ['error_stack'] };
      RumAttributeAssert.record(resourceRecord, resourceAttributes);
      RumAttributeAssert.record(errorRecord, errorAttributes);
      const resourceRumId = getLineProtocolTag(resourceRecord?.getDataString() ?? '', 'resource_id');
      const resourceDataId = getLineProtocolTag(resourceRecord?.getDataString() ?? '', 'sdk_data_id');
      const errorRumId = getLineProtocolTag(errorRecord?.getDataString() ?? '', 'resource_id');
      expect(isSdkUuid(resourceRumId)).assertTrue();
      expect(resourceRumId).assertEqual(resourceDataId);
      expect(errorRumId).assertEqual(resourceRumId);
      resourceFragments.push(`resource_id=${resourceRumId}`);
      errorFragments.push(`resource_id=${resourceRumId}`);

      collector.clearRequests();
      FTSDK.flushSyncData();

      const resourceUploaded = await collector.waitForPayloadContaining(resourceFragments, 5000);
      const errorUploaded = await collector.waitForPayloadContaining(errorFragments, 5000);
      const resourceConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, resourceRecord?.getUuid() ?? '', 5000);
      const errorConsumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, errorRecord?.getUuid() ?? '', 5000);

      expect(resourceUploaded.length > 0).assertTrue();
      expect(errorUploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(resourceUploaded, resourceRecord, resourceAttributes);
      RumAttributeAssert.uploaded(errorUploaded, errorRecord, errorAttributes);
      expect(resourceConsumed).assertTrue();
      expect(errorConsumed).assertTrue();
    });

    it('missingResourceFieldsShouldFallback', 0, async () => {
      const viewName = 'manual_resource_fallback_view';
      const resourceId = 'manual_resource_fallback';
      const resourceUrl = 'https://example.com/manual-resource-fallback';

      const params = new ResourceParams();
      params.setUrl(resourceUrl);
      params.setResourceMethod('GET');
      params.setResourceStatus(200);

      const netStatus = new NetStatusBean();
      netStatus.setHoleRequestTime(90000000);

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      await WaitUtils.delay(20);
      FTRUMGlobalManager.getInstance().stopResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, netStatus);

      const fragments = [
        'resource',
        `resource_url=${resourceUrl}`,
        'resource_method=GET',
        'resource_status=200',
        `view_name=${viewName}`
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      const line = record?.getDataString() ?? '';

      expect(record !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(record, attributes);
      expect(line.includes('request_header=')).assertFalse();
      expect(line.includes('response_header=')).assertFalse();
      expect(line.includes('resource_size=')).assertFalse();

      collector.clearRequests();
      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, record, attributes);
      expect(consumed).assertTrue();
    });

    it('longTaskKeepsCallerStackOnly', 0, async () => {
      const longTaskLog = 'real_collected_long_task';

      await FTRUMGlobalManager.getInstance().startView('long_task_sync_view');
      FTRUMGlobalManager.getInstance().addLongTask(longTaskLog, 123456789);

      const longTaskRecord = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'long_task',
        longTaskLog,
        'duration'
      ], 5000);
      expect(longTaskRecord !== null).assertTrue();
      const attributes: RumAttributeExpectation = { measurement: 'long_task', appId: TEST_FAKE_RUM_ID };
      RumAttributeAssert.record(longTaskRecord, attributes);
      const line = longTaskRecord?.getDataString() ?? '';
      expect(line.includes(longTaskLog)).assertTrue();
      expect(line.includes('Stack Trace:')).assertFalse();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'long_task',
        longTaskLog,
        'duration'
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, longTaskRecord?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      RumAttributeAssert.uploaded(uploaded, longTaskRecord, attributes);
      expect(consumed).assertTrue();
    });

    it('viewLongTaskRateIsReportedAndClamped', 0, async () => {
      const viewName = 'long_task_rate_view';
      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addLongTask('long_task_rate_event', 10 * 1000000000);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      const view = await DBAssert.waitForViewNamed(viewName, 5000);
      expect(view?.getLongTaskDuration()).assertEqual(10 * 1000000000);

      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['view,', `view_name=${viewName}`, 'view_long_task_rate=1'], 5000);
      expect(record !== null).assertTrue();
    });

    it('configShouldAffectUpload', 0, async () => {
      const logPrefix = 'config_payload_log';
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST, TEST_DATAWAY_TOKEN)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.PRE)
        .setSyncPageSize(SyncPageSize.MINI)
        .setServiceName('config_payload_service')
        .addGlobalContext('config_payload_tag', new String('config_payload_value'));
      const logConfig = buildDefaultLogConfig();
      logConfig.addGlobalContext('log_payload_tag', 'log_payload_value');
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), logConfig, buildDefaultTraceConfig());

      for (let i = 0; i < 6; i++) {
        FTLogger.logBackground(`${logPrefix}_${i}`, Status.INFO);
      }

      const inserted = await DBAssert.waitForSyncCount([DataType.LOG], 6, 5000);
      expect(inserted).assertTrue();

      const record = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [
        `${logPrefix}_0`,
        'service=config_payload_service',
        'env=pre',
        'config_payload_tag=config_payload_value',
        'log_payload_tag=log_payload_value'
      ], 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        `${logPrefix}_0`,
        'service=config_payload_service',
        'env=pre',
        'config_payload_tag=config_payload_value',
        'log_payload_tag=log_payload_value'
      ], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);
      const logRequests = collector.getRequests().filter(request => request.httpConfig.model === 'v1/write/logging');

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(logRequests.length >= 2).assertTrue();
      expect(logRequests[0].httpConfig.clientToken).assertEqual(TEST_DATAWAY_TOKEN);
      expect(logRequests[0].httpConfig.datawayUrl).assertEqual(TEST_HOST);
      expect(logRequests[0].httpConfig.datakitUrl).assertEqual('');
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('rumConfigShouldAffectPayload', 0, async () => {
      const serviceName = 'config_rum_service';
      const appId = 'config_rum_app_id';
      const viewName = 'config_rum_payload_view';
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.PRE)
        .setServiceName(serviceName);
      const rumConfig = buildDefaultRumConfig()
        .setRumAppId(appId)
        .addGlobalContext('rum_payload_tag', new String('rum_payload_value'));
      installTestSdk(context, sdkConfig, rumConfig, buildDefaultLogConfig(), buildDefaultTraceConfig());

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();

      const fragments = [
        'view',
        `view_name=${viewName}`,
        `service=${serviceName}`,
        'env=pre',
        `app_id=${appId}`,
        'rum_payload_tag=rum_payload_value'
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);
      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('rumPayloadShouldIncludeContexts', 0, async () => {
      const viewName = 'rum_global_context_view';
      const actionName = 'rum_global_context_action';
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkDynamicContext: Map<string, string> = new Map();
      sdkDynamicContext.set('sdk_dynamic_global_tag', 'sdk_dynamic_global_value');
      const rumDynamicContext: Map<string, string> = new Map();
      rumDynamicContext.set('rum_dynamic_global_tag', 'rum_dynamic_global_value');

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false)
        .setEnv(EnvType.GRAY)
        .addGlobalContext('sdk_config_global_tag', new String('sdk_config_global_value'));
      const rumConfig = buildDefaultRumConfig()
        .addGlobalContext('rum_config_global_tag', new String('rum_config_global_value'));
      installTestSdk(context, sdkConfig, rumConfig, buildDefaultLogConfig(), buildDefaultTraceConfig());

      FTSDK.appendGlobalContext(sdkDynamicContext);
      FTSDK.appendGlobalContextKeyValue('sdk_dynamic_single_tag', 'sdk_dynamic_single_value');
      FTSDK.appendRUMGlobalContext(rumDynamicContext);
      FTSDK.appendRUMGlobalContextKeyValue('rum_dynamic_single_tag', 'rum_dynamic_single_value');

      await FTRUMGlobalManager.getInstance().startView(viewName);
      FTRUMGlobalManager.getInstance().addAction(actionName, 'click');

      const fragments = [
        'action,',
        `action_name=${actionName}`,
        `${Constants.KEY_RUM_APP_ID}=${TEST_FAKE_RUM_ID}`,
        'sdk_config_global_tag=sdk_config_global_value',
        'sdk_dynamic_global_tag=sdk_dynamic_global_value',
        'sdk_dynamic_single_tag=sdk_dynamic_single_value',
        'rum_config_global_tag=rum_config_global_value',
        'rum_dynamic_global_tag=rum_dynamic_global_value',
        'rum_dynamic_single_tag=rum_dynamic_single_value'
      ];
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, fragments, 5000);

      expect(record !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining(fragments, 5000);
      const consumed = await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });

    it('datakitUploadTargetUseDatakitWriteUrl', 0, async () => {
      const logContent = 'datakit_target_log';
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(false);
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), buildDefaultLogConfig(), buildDefaultTraceConfig());

      FTLogger.logBackground(logContent, Status.INFO);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent], 5000);
      const logRequests = collector.getRequests().filter(request => request.bodyString.includes(logContent));
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(logRequests.length > 0).assertTrue();
      expect(logRequests[0].httpConfig.model).assertEqual('v1/write/logging');
      expect(logRequests[0].httpConfig.datakitUrl).assertEqual(TEST_HOST);
      expect(logRequests[0].httpConfig.clientToken).assertEqual('');
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('autoSyncShouldUploadMiniBatches', 0, async () => {
      const logPrefix = 'auto_page_log';
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      await DBAssert.resetAll();
      collector.clearRequests();

      const sdkConfig = FTSDKConfig.builder(TEST_HOST)
        .setDebug(true)
        .setAutoSync(true)
        .setSyncPageSize(SyncPageSize.MINI);
      installTestSdk(context, sdkConfig, buildDefaultRumConfig(), buildDefaultLogConfig(), buildDefaultTraceConfig());

      for (let i = 0; i < 6; i++) {
        FTLogger.logBackground(`${logPrefix}_${i}`, Status.INFO);
      }

      const uploadedAll = await WaitUtils.waitUntil(async () => {
        const logRequests = collector.getRequests()
          .filter(request => request.httpConfig.model === 'v1/write/logging' && request.bodyString.includes(logPrefix));
        const payloads = logRequests.map(request => request.bodyString).join('\n');
        return logRequests.length >= 2 &&
          payloads.includes(`${logPrefix}_0`) &&
          payloads.includes(`${logPrefix}_5`);
      }, SyncTaskManager.AUTO_SYNC_DELAY_MS + 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      if (!uploadedAll || !consumed) {
        throw new Error(`Auto upload incomplete: uploaded=${uploadedAll}, consumed=${consumed}, status=${
          JSON.stringify(SyncTaskManager.getInstance().getStatus())}, requests=${JSON.stringify(collector.getRequests())}`);
      }
      expect(uploadedAll).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('resourceUploadKeepAttributesAcrossRetry', 0, async () => {
      await collector.stop();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      collector.start();
      // This case controls the failed attempt and its later retry separately.
      installTestSdk(context, buildDefaultSdkConfig().setDataSyncRetryCount(0));
      const resourceId = 'attribute-retry-resource';
      const params = new ResourceParams();
      params.setUrl('https://example.com/attribute-retry');
      params.setResourceMethod('GET');
      params.setResourceStatus(200);
      params.setResponseContentLength(128);
      const net = new NetStatusBean();
      net.setHoleRequestTime(1000000);
      await FTRUMGlobalManager.getInstance().startView('attribute_retry_view');
      FTRUMGlobalManager.getInstance().startResource(resourceId);
      FTRUMGlobalManager.getInstance().stopResource(resourceId);
      FTRUMGlobalManager.getInstance().addResource(resourceId, params, net);
      const record = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource,', 'resource_url_path=/attribute-retry'], 5000);
      const attributes: RumAttributeExpectation = { measurement: 'resource', appId: TEST_FAKE_RUM_ID,
        viewName: 'attribute_retry_view', resourceStatus: 200, requiredFields: ['resource_size'] };
      RumAttributeAssert.record(record, attributes);

      collector.setResponse(500, 'planned retry');
      collector.clearRequests();
      FTSDK.flushSyncData();
      const first = await collector.waitForPayloadContaining([record!.getUuid()], 5000);
      RumAttributeAssert.uploaded(first, record, attributes);
      // A failed attempt can schedule a retry. Wait for its DB commit, while
      // allowing that delayed retry to remain scheduled for the recovery step.
      expect(await WaitUtils.waitUntil(async () => {
        return !SyncTaskManager.getInstance().getStatus().uploadLaneStatus.isRunning;
      }, 5000)).assertTrue();
      const retained = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP,
        ['resource,', record!.getUuid()], 5000);
      expect(retained !== null).assertTrue();

      collector.setResponse(200, '');
      collector.clearRequests();
      FTSDK.flushSyncData();
      const retried = await collector.waitForPayloadContaining([record!.getUuid()], 5000);
      RumAttributeAssert.uploaded(retried, record, attributes);
      expect(await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, record!.getUuid(), 5000)).assertTrue();
    });

    it('failedLogUploadShouldRecover', 0, async () => {
      const logContent = 'real_retry_log';

      collector.setResponse(500, 'server-error');
      FTLogger.logBackground(logContent, Status.ERROR);

      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=error'], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();

      const failedPayload = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      await WaitUtils.delay(800);

      expect(failedPayload.length > 0).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

      collector.setResponse(200, '');
      collector.clearRequests();
      FTSDK.flushSyncData();

      const recoveredPayload = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(recoveredPayload.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('networkFailureShouldRecoverRows', 0, async () => {
      const logContent = 'real_network_failure_retry_log';

      await collector.stop();
      await SdkTestLifecycle.resetRuntimeState();
      await DBAssert.resetAll();
      installTestSdk(
        context,
        FTSDKConfig.builder('http://127.0.0.1:1')
          .setDebug(true)
          .setAutoSync(false)
          .setEnv(EnvType.GRAY)
          .setDataSyncRetryCount(0),
        buildDefaultRumConfig(),
        buildDefaultLogConfig(),
        buildDefaultTraceConfig()
      );

      FTLogger.logBackground(logContent, Status.ERROR);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent, 'status=error'], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.flushSyncData();
      await SdkTestLifecycle.waitForUploadIdle(8000);
      await WaitUtils.delay(300);

      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

      collector.start();
      collector.setResponse(200, '');
      collector.clearRequests();
      FTSDK.flushSyncData();

      const recoveredPayload = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(recoveredPayload.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('historicalRowsFlushAfterSdkReinstall', 0, async () => {
      const logContent = 'restart_flush_log';

      FTLogger.logBackground(logContent, Status.ERROR);
      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.LOG, [logContent], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.shutDown();
      collector.clearRequests();
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      installTestSdk(context);

      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(1);

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([logContent, 'status=error'], 5000);
      const consumed = await DBAssert.waitForSyncCount([DataType.LOG], 0, 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
      expect(await DBAssert.querySyncCount([DataType.LOG])).assertEqual(0);
    });

    it('historicalRumRowsFlushAfterSdkReinstall', 0, async () => {
      const viewName = 'restart_flush_view';

      await FTRUMGlobalManager.getInstance().startView(viewName);
      await FTRUMGlobalManager.getInstance().stopView();
      await waitForRumAggregation();

      const inserted = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(inserted !== null).assertTrue();

      FTSDK.shutDown();
      collector.clearRequests();
      await SdkTestLifecycle.resetRuntimeState();
      collector.start();
      installTestSdk(context);

      const historical = await DBAssert.waitForSyncRecordContaining(DataType.RUM_APP, [
        'view',
        `view_name=${viewName}`
      ], 5000);
      expect(historical !== null).assertTrue();

      FTSDK.flushSyncData();

      const uploaded = await collector.waitForPayloadContaining([
        'view',
        `view_name=${viewName}`
      ], 5000);
      const consumed =
        await DBAssert.waitForNoSyncRecordWithUuid(DataType.RUM_APP, historical?.getUuid() ?? '', 5000);

      expect(uploaded.length > 0).assertTrue();
      expect(consumed).assertTrue();
    });
  });
}
