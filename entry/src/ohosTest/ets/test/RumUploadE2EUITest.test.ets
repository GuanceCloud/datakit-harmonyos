import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Driver } from '@ohos.UiTest';
import fs from '@ohos.file.fs';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { FTSDK } from '@guancecloud/ft_sdk/Index';
import { SyncTaskManager } from '@guancecloud/ft_sdk/src/main/ets/components/SyncTaskManager';
import { SyncDataHelper } from '@guancecloud/ft_sdk/src/main/ets/components/SyncDataHelper';
import { DefaultSyncTaskManagerRuntime } from '@guancecloud/ft_sdk/src/main/ets/components/internal/runtime/SyncTaskManagerRuntime';
import { SyncInternalTestAccess } from '@guancecloud/ft_sdk/src/main/ets/components/internal/testaccess/SyncInternalTestAccess';
import {
  SDKUploadExecutePageResultDTO, SDKWorkerCommand, SDKWorkerRequest, SDKWorkerResponse
} from '@guancecloud/ft_sdk/src/main/ets/components/thread/SDKWorkerProtocol';
import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import { DataType } from '@guancecloud/ft_sdk/src/main/ets/components/enum/Enums';
import { RumAttributeExpectation } from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/RumAttributeAssert';
import { KEY_RESOURCE_TEST_URL } from '../../../main/ets/entryability/EntryAbility';
import { EntryDBAssert } from './helpers/EntryDBAssert';
import { EntryRumUploadAssert, RumUploadRecord } from './helpers/EntryRumUploadAssert';
import { EntryWaitUtils } from './helpers/EntryWaitUtils';
import { UiTestUtils } from './helpers/UiTestUtils';

interface ResourceUploadCase {
  source: string;
  buttonId: string;
  method: string;
}

const RESOURCE_CASES: ResourceUploadCase[] = [
  { source: 'rcp', buttonId: 'test-get-btn', method: 'GET' },
  // API 22 HttpRequestContext exposes url/header/body, but no method.
  { source: 'network-http', buttonId: 'test-http-get-btn', method: 'UNKNOWN' },
  { source: 'axios-compat', buttonId: 'test-axios-compat-get-btn', method: 'GET' },
  { source: 'axios-chain', buttonId: 'test-axios-chain-get-btn', method: 'GET' }
];

/** Observe complete bodies of real successful requests; never inject HTTP results. */
class UploadObserver extends DefaultSyncTaskManagerRuntime {
  readonly statusCodes: number[] = [];
  private readonly bodies: string[] = [];

  async executeUploadWorkerCommand(request: SDKWorkerRequest): Promise<SDKWorkerResponse> {
    const response = await super.executeUploadWorkerCommand(request);
    if (request.command === SDKWorkerCommand.UPLOAD_EXECUTE_PAGE && response.ok && response.payload) {
      const result = response.payload as Object as SDKUploadExecutePageResultDTO;
      if (result.shouldUpload) {
        this.statusCodes.push(result.httpResult.code);
        if (result.successfulResponse && result.httpResult.code >= 200 && result.httpResult.code < 300) {
          this.bodies.push(result.bodyPreview);
        }
      }
    }
    return response;
  }

  getPayload(): string {
    return this.bodies.join('\n');
  }
}

/** Real UI -> SDK -> Worker/DB -> launch endpoint, with complete uploaded event contracts. */
export default function rumUploadE2EUITest() {
  if (!UiTestUtils.isUploadE2EEnabled()) return;

  describe('RumUploadE2EUITest', () => {
    let driver: Driver;
    let originalResourceUrl: string = '';

    beforeEach(async () => {
      driver = await UiTestUtils.createDriver();
      await UiTestUtils.launchEntryAbility(driver);
      originalResourceUrl = AppStorage.get<string>(KEY_RESOURCE_TEST_URL) ?? '';
      await EntryDBAssert.resetAll();
    });

    afterEach(() => {
      SyncInternalTestAccess.resetRuntime();
      FTSDK.appendRUMGlobalContextKeyValue('ft_e2e_run', '');
      AppStorage.set(KEY_RESOURCE_TEST_URL, originalResourceUrl);
      // Do not clear pending records on failure.
    });

    // Use a 300-second case timeout for UI navigation, four transport timeouts and the 60-second upload wait.
    it('uploadsAllRumEventTypes', 0, async () => {
      const runId = beginRun('success');
      const batch: RumUploadRecord[] = [];

      await UiTestUtils.clickText(driver, 'RUM Unified Test');
      await UiTestUtils.clickId(driver, 'rum-basic-add-long-task');
      await UiTestUtils.clickId(driver, 'rum-basic-add-error');
      await UiTestUtils.ensureHome(driver);
      batch.push(await capture(runId, 'long_task', ['Basic long task test'], 'RUMDataTestPage'));
      batch.push(await capture(runId, 'error', ['error_type=custom', 'Basic error message'], 'RUMDataTestPage',
        ['error_stack']));
      expect(batch[0].point.fields.get('duration')).assertEqual(2000000000);
      expect(batch[0].point.fields.get('long_task_stack')).assertEqual('Basic long task test');
      expect(batch[1].point.fields.get('error_message')).assertEqual('Basic error message');
      expect(batch[1].point.tags.get('error_source')).assertEqual('logger');
      expect(batch[1].point.tags.get('error_situation')).assertEqual('run');

      await UiTestUtils.clickText(driver, 'Button Click Auto-Tracking Test');
      await UiTestUtils.clickText(driver, 'Test Button 1 - Basic Click');
      batch.push(await capture(runId, 'action', ['test-button-1'], 'ButtonClickTestPage'));
      await UiTestUtils.ensureHome(driver);

      await collectResources(driver, runId, batch, 200);
      await includeParents(runId, batch);
      expect(batch.length).assertEqual(16);
      await uploadAndAssert(runId, batch, 0);
    });

    it('uploadsHttpFailureResourcesAndLinkedErrors', 0, async () => {
      const runId = beginRun('http_failure');
      const batch: RumUploadRecord[] = [];
      // The override only changes the real GET target used by existing Demo buttons.
      AppStorage.set(KEY_RESOURCE_TEST_URL, UiTestUtils.getResourceErrorUrl());
      await collectResources(driver, runId, batch, 500);
      await includeParents(runId, batch);
      expect(batch.length).assertEqual(13);
      await uploadAndAssert(runId, batch, 4);
    });

    it('uploadsConnectionFailureResourcesAndLinkedErrors', 0, async () => {
      const runId = beginRun('connection_failure');
      const batch: RumUploadRecord[] = [];
      // No listener: exercise actual transport rejection, independently of DNS or Internet access.
      AppStorage.set(KEY_RESOURCE_TEST_URL, 'http://127.0.0.1:1/resource');
      await collectResources(driver, runId, batch, 0);
      await includeParents(runId, batch);
      expect(batch.length).assertEqual(13);
      await uploadAndAssert(runId, batch, 4);
    });

    it('uploadsClientErrorResourcesAndLinkedErrors', 0, async () => {
      const runId = beginRun('http_client_error');
      const batch: RumUploadRecord[] = [];
      AppStorage.set(KEY_RESOURCE_TEST_URL, UiTestUtils.getResourceErrorUrl(404));
      await collectResources(driver, runId, batch, 404);
      await includeParents(runId, batch);
      expect(batch.length).assertEqual(13);
      await uploadAndAssert(runId, batch, 4);
    });

    it('uploadsTimeoutResourcesAndLinkedErrors', 0, async () => {
      const runId = beginRun('timeout');
      const batch: RumUploadRecord[] = [];
      // The endpoint must accept the connection and delay beyond the Demo request timeout.
      AppStorage.set(KEY_RESOURCE_TEST_URL, UiTestUtils.getResourceTimeoutUrl());
      await collectResources(driver, runId, batch, 0);
      for (const item of batch) {
        if (item.point.measurement === 'resource') {
          expect(Number(item.point.fields.get('duration')) >= 9000000000).assertTrue();
        }
      }
      await includeParents(runId, batch);
      expect(batch.length).assertEqual(13);
      await uploadAndAssert(runId, batch, 4);
    });
  });
}

function beginRun(scenario: string): string {
  const runId = `rum_upload_e2e_${scenario}_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  FTSDK.appendRUMGlobalContextKeyValue('ft_e2e_run', runId);
  return runId;
}

async function collectResources(driver: Driver, runId: string, batch: RumUploadRecord[], status: number): Promise<void> {
  await UiTestUtils.clickText(driver, 'HTTP Interceptor Test');
  for (const transport of RESOURCE_CASES) {
    await UiTestUtils.clickId(driver, transport.buttonId);
    const source = SyncDataHelper.translateTagKeyValue(`ft_source=${transport.source}`);
    const fields = status > 0 ? ['request_header', 'response_header'] : ['request_header'];
    const resource = await capture(runId, 'resource', [source], 'HttpAutoTrackTestPage', fields, status);
    expect(resource.point.tags.get('resource_method')).assertEqual(transport.method);
    expect(resource.point.tags.get('resource_type')).assertEqual('network');
    expect(resource.point.tags.has('trace_id')).assertTrue();
    expect(resource.point.tags.has('span_id')).assertTrue();
    if (status === 0) {
      expect(resource.point.tags.get('resource_status')).assertEqual('0');
      expect(resource.point.tags.has('resource_status_group')).assertFalse();
    }
    batch.push(resource);
    if (status !== 200) {
      const resourceId = EntryRumUploadAssert.tag(resource.point, 'resource_id');
      const error = await capture(runId, 'error', [source, `resource_id=${resourceId}`, 'error_source=network'],
        'HttpAutoTrackTestPage', status === 0 ? ['error_stack'] : []);
      expect(error.point.tags.get('resource_status')).assertEqual(String(status));
      batch.push(error);
    }
  }
  await UiTestUtils.ensureHome(driver);
}

async function capture(runId: string, measurement: string, fragments: string[], viewName: string,
  fields: string[] = [], resourceStatus?: number): Promise<RumUploadRecord> {
  const record = await waitForRunRecord(runId, measurement, fragments);
  const tags = ['ft_e2e_run', 'custom_key'];
  if (measurement !== 'view') tags.push('action_id', 'action_name');
  if (measurement === 'resource') tags.push('trace_id', 'span_id');
  const expected: RumAttributeExpectation = { measurement, viewName, resourceStatus,
    appId: FTSDK.getRumConfig()!.getRumAppId(), requiredTags: tags, requiredFields: fields };
  return EntryRumUploadAssert.capture(record, expected);
}

async function includeParents(runId: string, batch: RumUploadRecord[]): Promise<void> {
  const children = batch.slice();
  for (const child of children) {
    const viewId = EntryRumUploadAssert.tag(child.point, 'view_id');
    const viewName = EntryRumUploadAssert.tag(child.point, 'view_name');
    if (!batch.some((entry) => entry.point.measurement === 'view' && entry.point.tags.get('view_id') === viewId)) {
      let view: RumUploadRecord | null = null;
      // The first closed View may precede the final asynchronous Resource
      // counter flush. Wait for the corresponding uploaded snapshot contract.
      const ready = await EntryWaitUtils.waitUntil(async () => {
        const current = await capture(runId, 'view', [`view_id=${viewId}`, 'is_active=false'], viewName);
        for (const measurement of ['resource', 'error', 'long_task', 'action']) {
          const count = children.filter((item) => item.point.measurement === measurement &&
            item.point.tags.get('view_id') === viewId).length;
          if (Number(current.point.fields.get(`view_${measurement}_count`)) < count) return false;
        }
        view = current;
        return true;
      }, 10000, 150);
      if (!ready || view === null) throw new Error(`Closed View counters did not settle: runId=${runId}, viewId=${viewId}`);
      batch.push(view);
    }
    const actionId = EntryRumUploadAssert.tag(child.point, 'action_id');
    if (!batch.some((entry) => entry.point.measurement === 'action' && entry.point.tags.get('action_id') === actionId)) {
      batch.push(await capture(runId, 'action', [`action_id=${actionId}`], viewName));
    }
  }
}

async function uploadAndAssert(runId: string, batch: RumUploadRecord[], networkErrors: number): Promise<void> {
  EntryRumUploadAssert.relationships(batch.map((entry) => entry.point), runId, networkErrors);
  const uuids = batch.map((entry) => entry.record.getUuid());
  expect(new Set<string>(uuids).size).assertEqual(batch.length);
  expect(await EntryDBAssert.countSyncRecordsWithUuids(uuids)).assertEqual(batch.length);
  const manager = SyncTaskManager.getInstance();
  expect(manager.getStatus().autoSync).assertFalse();
  const observer = new UploadObserver();
  SyncInternalTestAccess.setRuntime(observer);
  FTSDK.flushSyncData();
  const uploaded = await EntryWaitUtils.waitUntil(async () => {
    const status = manager.getStatus();
    const lane = status.uploadLaneStatus;
    return observer.getPayload().length > 0 && !status.running && !lane.isRunning && !lane.isScheduled &&
      !lane.needReschedule && await EntryDBAssert.countSyncRecordsWithUuids(uuids) === 0;
  }, 60000, 250);
  if (!uploaded) {
    const remaining = await EntryDBAssert.countSyncRecordsWithUuids(uuids);
    throw new Error(`RUM upload completion not confirmed within 60s: runId=${runId}, pending=${remaining}/${batch.length}, ` +
      `httpStatusCodes=${observer.statusCodes.join(',') || 'awaiting worker result'}, ` +
      `uploadLane=${JSON.stringify(manager.getStatus().uploadLaneStatus)}. ` +
      'An in-flight request may still finish after this test times out.');
  }
  // Every selected event must occur exactly once in successful HTTP bodies, with
  // all original tags/fields/timestamp intact (apart from the allowed UUID package prefix).
  // Retain the actual successful HTTP body for backend JSON/UI acceptance.
  const path = `${AbilityDelegatorRegistry.getAbilityDelegator().getAppContext().filesDir}/${runId}.lp`;
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, observer.getPayload());
  } finally {
    fs.closeSync(file);
  }
  EntryRumUploadAssert.uploaded(observer.getPayload(), batch, runId, networkErrors);
  console.info(`RUM upload attributes/associations passed: runId=${runId}, events=${batch.length}, networkErrors=${networkErrors}`);
}

async function waitForRunRecord(runId: string, measurement: string, fragments: string[]): Promise<SyncData> {
  let matched: SyncData | null = null;
  const found = await EntryWaitUtils.waitUntil(async () => {
    const records = await EntryDBAssert.querySyncRecords([DataType.RUM_APP], 1000, true);
    for (const record of records) {
      const line = record.getDataString();
      if (line.startsWith(`${measurement},`) && line.includes(`ft_e2e_run=${runId}`) &&
        fragments.every((fragment) => line.includes(fragment))) {
        matched = record;
        return true;
      }
    }
    return false;
  }, 25000, 150);
  if (!found || matched === null) {
    throw new Error(`Missing ${measurement} for runId=${runId}, expected=${fragments.join(', ')}`);
  }
  return matched;
}
